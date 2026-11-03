#!/usr/bin/env bash
# check-size.sh - Liet ke dung luong tu CAO xuong THAP: thu muc tren may, database / retention policy,
# measurement (InfluxDB), metric (Prometheus), va tinh truoc dat thoi han 30/90/180/365 ngay
# thi giai phong duoc bao nhieu. Chi DOC, khong xoa / sua gi.
#
# Cach dung:
#   sudo bash check-size.sh          # day du (co chay influx_inspect report-disk, co the vai phut)
#   sudo bash check-size.sh -q       # nhanh: bo qua dung luong tung measurement
#   sudo bash check-size.sh -n 30    # so dong top (mac dinh 15)
#
# Bien moi truong giong check-retention.sh: INFLUX_URL, INFLUX_DIR, INFLUX_USER / INFLUX_PASS,
# INFLUX_TOKEN, PROM_URLS, INSPECT_TIMEOUT (giay, mac dinh 1200)

QUICK=0
TOP=15
while getopts "qn:h" o; do
  case "$o" in
    q) QUICK=1 ;;
    n) TOP="$OPTARG" ;;
    *) sed -n '2,13p' "$0"; exit 0 ;;
  esac
done
case "$TOP" in ''|*[!0-9]*) echo "-n phai la so"; exit 1 ;; esac

export INFLUX_URL="${INFLUX_URL:-http://localhost:8086}"
export INFLUX_DIR="${INFLUX_DIR:-/var/lib/influxdb}"
HERE=$(cd "$(dirname "$0")" && pwd)
if [ -z "${INFLUX_USER:-}${INFLUX_TOKEN:-}${INFLUX_CRED_DONE:-}" ] && [ -f "$HERE/find-influx-cred.sh" ]; then
  eval "$(bash "$HERE/find-influx-cred.sh" --env)"
fi
export INFLUX_USER INFLUX_PASS INFLUX_TOKEN QUICK TOP

if [ -t 1 ]; then
  B=$'\e[1m'; C=$'\e[36m'; N=$'\e[0m'
else
  B=; C=; N=
fi
title() { echo; echo "${B}${C}==== $* ====${N}"; }

command -v python3 >/dev/null || { echo "Can python3 de chay script nay"; exit 1; }

# ---------------------------------------------------------------- Thu muc
title "TOP THU MUC (cao -> thap)"
df -h / 2>/dev/null
echo
du -xsh /var/lib/* /var/log /opt/* /home/* /root /tmp 2>/dev/null | sort -rh | head -n "$TOP"

if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  title "DOCKER"
  docker system df 2>/dev/null
  if [ -d /var/lib/docker/volumes ]; then
    echo
    echo "Top volume:"
    du -sh /var/lib/docker/volumes/*/ 2>/dev/null | sort -rh | head -n 10
  fi
fi

# ---------------------------------------------------------------- InfluxDB
title "INFLUXDB ($INFLUX_URL)"
python3 - <<'PY'
import os, json, time, base64, subprocess, urllib.request, urllib.parse
from datetime import datetime

URL = os.environ["INFLUX_URL"].rstrip("/")
DIR = os.environ["INFLUX_DIR"]
USER = os.environ.get("INFLUX_USER", "")
PASS = os.environ.get("INFLUX_PASS", "")
TOKEN = os.environ.get("INFLUX_TOKEN", "")
QUICK = os.environ["QUICK"] == "1"
TOP = int(os.environ["TOP"])
NOW = time.time()
KEEP = [30, 90, 180, 365]
tty = os.isatty(1)
B, R, G, Y, N = ("\033[1m", "\033[31m", "\033[32m", "\033[33m", "\033[0m") if tty else ("",) * 5

def req(path, headers=None, timeout=30):
    r = urllib.request.Request(URL + path, headers=headers or {})
    with urllib.request.urlopen(r, timeout=timeout) as resp:
        return resp.headers, resp.read()

def scan(path):
    """(tong dung luong, mtime moi nhat) cua thu muc"""
    size, newest = 0, 0
    for root, _, files in os.walk(path):
        for f in files:
            try:
                st = os.stat(os.path.join(root, f))
            except OSError:
                continue
            size += st.st_size
            newest = max(newest, st.st_mtime)
    return size, newest

def human(n):
    for u in ["B", "K", "M", "G", "T"]:
        if abs(n) < 1024:
            return f"{n:.1f}{u}"
        n /= 1024
    return f"{n:.1f}P"

def bar(part, total, width=20):
    n = int(round(width * part / total)) if total else 0
    return "#" * n + "." * (width - n)

def ts(s):
    return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()

def dur_days(d):
    """'2160h0m0s' -> 90.0, '0s' -> 0"""
    total, num = 0.0, ""
    for ch in d:
        if ch.isdigit() or ch == ".":
            num += ch
        else:
            total += float(num or 0) * {"h": 3600, "m": 60, "s": 1, "d": 86400, "w": 604800}.get(ch, 0)
            num = ""
    return total / 86400

try:
    h, _ = req("/ping")
    ver = h.get("X-Influxdb-Version", "?")
except Exception as e:
    print(f"{R}Khong ket noi duoc InfluxDB: {e}{N}")
    ver = None

# shards: list dict(db, rp, id, end, size)   rps: (db, rp) -> retention (ngay, 0 = vo han)
shards, rps = [], {}
if ver and not ver.startswith("2"):
    hdr = {"Authorization": "Basic " + base64.b64encode(f"{USER}:{PASS}".encode()).decode()} if USER else {}
    def q(query):
        _, body = req("/query?" + urllib.parse.urlencode({"q": query}), hdr)
        res = json.loads(body)["results"][0]
        if "error" in res:
            raise RuntimeError(res["error"])
        return [dict(zip(s["columns"], v)) for s in res.get("series", []) for v in s.get("values", [])]
    try:
        for d in q("SHOW DATABASES"):
            for rp in q(f'SHOW RETENTION POLICIES ON "{d["name"]}"'):
                rps[(d["name"], rp["name"])] = dur_days(rp["duration"])
        ends = {str(r["id"]): ts(r["end_time"]) for r in q("SHOW SHARDS")}
    except Exception as e:
        print(f"{Y}Query loi ({e}) -> chi dung thu muc tren dia{N}")
        ends = {}
    base = os.path.join(DIR, "data")
    for db in sorted(os.listdir(base)) if os.path.isdir(base) else []:
        for rp in sorted(os.listdir(os.path.join(base, db))):
            p = os.path.join(base, db, rp)
            if not os.path.isdir(p):
                continue
            rps.setdefault((db, rp), None)
            for sid in os.listdir(p):
                sp = os.path.join(p, sid)
                if not os.path.isdir(sp):
                    continue
                size, newest = scan(sp)
                wsize, wnew = scan(os.path.join(DIR, "wal", db, rp, sid))
                shards.append({"db": db, "rp": rp, "id": sid, "size": size + wsize,
                               "end": ends.get(sid) or max(newest, wnew)})
elif ver:
    if TOKEN:
        try:
            _, body = req("/api/v2/buckets?limit=100", {"Authorization": "Token " + TOKEN})
            names = {}
            for b in json.loads(body).get("buckets", []):
                secs = next((r.get("everySeconds", 0) for r in b.get("retentionRules", []) if r.get("type") == "expire"), 0)
                names[b["id"]] = b["name"]
                rps[(b["name"], "-")] = secs / 86400
        except Exception as e:
            print(f"{Y}Khong lay duoc bucket: {e}{N}")
            names = {}
    else:
        print(f"{Y}InfluxDB 2.x chua co token -> ten bucket hien bang ID{N}")
        names = {}
    base = os.path.join(DIR, "engine", "data")
    for bid in sorted(os.listdir(base)) if os.path.isdir(base) else []:
        name = names.get(bid, bid)
        rps.setdefault((name, "-"), None)
        for rp in os.listdir(os.path.join(base, bid)):
            p = os.path.join(base, bid, rp)
            for sid in os.listdir(p) if os.path.isdir(p) else []:
                size, newest = scan(os.path.join(p, sid))
                wsize, wnew = scan(os.path.join(DIR, "engine", "wal", bid, rp, sid))
                # 2.x khong co SHOW SHARDS -> lay thoi gian sua file moi nhat lam moc cuoi cua shard
                shards.append({"db": name, "rp": "-", "id": sid, "size": size + wsize, "end": max(newest, wnew)})

if ver and shards:
    total = sum(s["size"] for s in shards)
    by_db, by_rp = {}, {}
    for s in shards:
        by_db[s["db"]] = by_db.get(s["db"], 0) + s["size"]
        by_rp[(s["db"], s["rp"])] = by_rp.get((s["db"], s["rp"]), 0) + s["size"]

    print(f"\n{B}Dung luong theo database (cao -> thap){N}   tong {human(total)}")
    fmt = "{:>3} {:<28} {:>10} {:>6}  {:<20} {:>6}  {}"
    print(fmt.format("#", "DATABASE / BUCKET", "DUNG LUONG", "%", "", "SHARDS", "THOI HAN"))
    print("-" * 96)
    for i, (db, size) in enumerate(sorted(by_db.items(), key=lambda x: -x[1]), 1):
        n = sum(1 for s in shards if s["db"] == db)
        ret = []
        for (d, rp), days in rps.items():
            if d == db and by_rp.get((d, rp)):
                r = "?" if days is None else ("VO HAN" if days == 0 else f"{days:g}d")
                ret.append(r if rp == "-" else f"{rp}={r}")
        line = fmt.format(i, db[:28], human(size), f"{100 * size / total:.1f}", bar(size, total), n, ", ".join(ret))
        print(R + line + N if "VO HAN" in line else line)

    if len(by_rp) > len(by_db):
        print(f"\n{B}Dung luong theo retention policy (cao -> thap){N}")
        for i, ((db, rp), size) in enumerate(sorted(by_rp.items(), key=lambda x: -x[1])[:TOP], 1):
            print(f"{i:>3} {db[:28]:<28} {rp[:16]:<16} {human(size):>10} {100 * size / total:>6.1f}%")

    print(f"\n{B}Neu dat thoi han luu thi giai phong duoc (uoc tinh theo shard){N}")
    fmt = "{:<28} {:<16} {:>10} {:>9}" + " {:>10}" * len(KEEP)
    print(fmt.format("DATABASE / BUCKET", "RETENTION", "HIEN TAI", "THOI HAN", *[f"giu {k}d" for k in KEEP]))
    print("-" * (66 + 11 * len(KEEP)))
    sums = [0] * len(KEEP)
    for (db, rp), size in sorted(by_rp.items(), key=lambda x: -x[1]):
        days = rps.get((db, rp))
        cells = []
        for i, k in enumerate(KEEP):
            freed = sum(s["size"] for s in shards if s["db"] == db and s["rp"] == rp and s["end"] < NOW - k * 86400)
            sums[i] += freed
            cells.append(f"-{human(freed)}" if freed else "0")
        cur = "?" if days is None else ("VO HAN" if days == 0 else f"{days:g}d")
        print(fmt.format(db[:28], rp[:16], human(size), cur, *cells))
    print("-" * (66 + 11 * len(KEEP)))
    print(fmt.format("TONG", "", human(total), "", *[f"-{human(x)}" for x in sums]))
    print(f"{Y}So lieu la data cu hon moc; InfluxDB xoa ca shard nen thuc te giai phong tre hon toi 1 shard group.{N}")

    # ---- dung luong tung measurement (InfluxDB 1.8+)
    if not QUICK and not ver.startswith("2"):
        import shutil
        tool = shutil.which("influx_inspect")
        if not tool:
            print(f"\n{Y}Khong co influx_inspect -> bo qua dung luong tung measurement{N}")
        else:
            print(f"\n{B}Top measurement theo dung luong{N} (influx_inspect report-disk, co the mat vai phut...)", flush=True)
            try:
                out = subprocess.run([tool, "report-disk", "-dir", os.path.join(DIR, "data"), "-detailed"],
                                     capture_output=True, text=True, timeout=int(os.environ.get("INSPECT_TIMEOUT", "1200"))).stdout
                data = json.loads(out[out.index("{"):])
                meas = {}
                for m in data.get("Measurement", []):
                    size = next((v for k, v in m.items() if "size" in k.lower()), 0)
                    key = (m.get("db", "?"), m.get("measurement", "?"))
                    meas[key] = meas.get(key, 0) + int(size)
                mtotal = sum(meas.values()) or 1
                fmt = "{:>3} {:<24} {:<36} {:>10} {:>6}  {}"
                print(fmt.format("#", "DATABASE", "MEASUREMENT", "DUNG LUONG", "%", ""))
                print("-" * 104)
                for i, ((db, m), size) in enumerate(sorted(meas.items(), key=lambda x: -x[1])[:TOP], 1):
                    print(fmt.format(i, db[:24], m[:36], human(size), f"{100 * size / mtotal:.1f}", bar(size, mtotal)))
                if len(meas) > TOP:
                    print(f"... con {len(meas) - TOP} measurement nho hon (xem them: -n {len(meas)})")
            except subprocess.TimeoutExpired:
                print(f"{Y}report-disk qua INSPECT_TIMEOUT -> bo qua{N}")
            except Exception as e:
                print(f"{Y}report-disk loi: {e}{N}")
elif ver:
    print(f"{Y}Khong tim thay shard nao trong {DIR}{N}")
PY

# ---------------------------------------------------------------- Prometheus
title "PROMETHEUS - top metric theo so series"
URLS=()
IFS=',' read -ra _u <<<"${PROM_URLS:-}"
for u in "${_u[@]}"; do [ -n "$u" ] && URLS+=("$u"); done
if [ ${#URLS[@]} -eq 0 ] && command -v docker >/dev/null 2>&1; then
  while read -r cid image; do
    case "$image" in *prometheus*) ;; *) continue ;; esac
    case "$image" in *exporter*|*pushgateway*|*alertmanager*) continue ;; esac
    port=$(docker port "$cid" 9090/tcp 2>/dev/null | head -1 | awk -F: '{print $NF}')
    [ -n "$port" ] && URLS+=("http://localhost:$port")
  done < <(docker ps --format '{{.ID}} {{.Image}}' 2>/dev/null)
fi
[ ${#URLS[@]} -eq 0 ] && URLS+=("http://localhost:9090")

for url in "${URLS[@]}"; do
  echo "${B}-> $url${N}"
  PROM_URL="$url" python3 - <<'PY'
import os, json, urllib.request
URL = os.environ["PROM_URL"].rstrip("/")
TOP = int(os.environ["TOP"])
tty = os.isatty(1)
Y, N = ("\033[33m", "\033[0m") if tty else ("", "")
try:
    with urllib.request.urlopen(URL + f"/api/v1/status/tsdb?limit={TOP}", timeout=30) as r:
        d = json.loads(r.read())["data"]
except Exception as e:
    print(f"  {Y}Khong ket noi duoc: {e}{N}")
    raise SystemExit
total = d.get("headStats", {}).get("numSeries", 0)
print(f"  Tong series: {total:,}")
for key, label in [("seriesCountByMetricName", "METRIC"), ("seriesCountByLabelValuePair", "LABEL=VALUE"),
                   ("labelValueCountByLabelName", "LABEL (so gia tri)")]:
    rows = sorted(d.get(key, []), key=lambda x: -x["value"])[:TOP]
    if not rows:
        continue
    print(f"\n  {'#':>3} {label:<56} {'SERIES':>10} {'%':>6}")
    for i, r in enumerate(rows, 1):
        pct = f"{100 * r['value'] / total:.1f}" if total and key != "labelValueCountByLabelName" else ""
        print(f"  {i:>3} {r['name'][:56]:<56} {r['value']:>10,} {pct:>6}")
PY
done
echo
