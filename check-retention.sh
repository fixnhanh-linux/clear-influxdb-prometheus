#!/usr/bin/env bash
# check-retention.sh - Bao cao thoi han luu (retention) cua InfluxDB va Prometheus
# Chi DOC, khong xoa / sua gi.
#
# Cach dung:
#   bash check-retention.sh
#   INFLUX_USER=admin INFLUX_PASS=xxx bash check-retention.sh       # InfluxDB 1.x co auth
#   INFLUX_TOKEN=xxx bash check-retention.sh                         # InfluxDB 2.x
#   PROM_URLS=http://10.0.0.5:9090,http://localhost:9091 bash check-retention.sh
#
# Bien moi truong:
#   INFLUX_URL   (mac dinh http://localhost:8086)
#   INFLUX_DIR   (mac dinh /var/lib/influxdb)
#   INFLUX_USER / INFLUX_PASS  - InfluxDB 1.x
#   INFLUX_TOKEN               - InfluxDB 2.x
#   PROM_URLS    - danh sach URL Prometheus, cach nhau dau phay (tu do them container docker)
#   SCAN_DIR     - thu muc chua docker-compose de tim cau hinh retention
#                  (mac dinh /opt/monitor-grafana-vcenter-total-cluster-prometheus)

INFLUX_URL="${INFLUX_URL:-http://localhost:8086}"
INFLUX_DIR="${INFLUX_DIR:-/var/lib/influxdb}"
SCAN_DIR="${SCAN_DIR:-/opt/monitor-grafana-vcenter-total-cluster-prometheus}"
HERE=$(cd "$(dirname "$0")" && pwd)
# Khong truyen token / user -> tu tim tren server
if [ -z "${INFLUX_USER:-}${INFLUX_TOKEN:-}" ] && [ -f "$HERE/find-influx-cred.sh" ]; then
  eval "$(INFLUX_URL="$INFLUX_URL" INFLUX_DIR="$INFLUX_DIR" SCAN_DIR="$SCAN_DIR" bash "$HERE/find-influx-cred.sh" --env)"
fi
export INFLUX_URL INFLUX_DIR INFLUX_USER INFLUX_PASS INFLUX_TOKEN

if [ -t 1 ]; then
  B=$'\e[1m'; R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; C=$'\e[36m'; N=$'\e[0m'
else
  B=; R=; G=; Y=; C=; N=
fi
title() { echo; echo "${B}${C}==== $* ====${N}"; }

command -v python3 >/dev/null || { echo "${R}Can python3 de chay script nay${N}"; exit 1; }

# ---------------------------------------------------------------- Disk
title "DUNG LUONG O DIA"
df -h / /var/lib 2>/dev/null | awk 'NR==1 || !seen[$0]++'
for d in "$INFLUX_DIR" /var/lib/docker /var/lib/prometheus; do
  [ -d "$d" ] && du -sh "$d" 2>/dev/null
done

# ---------------------------------------------------------------- InfluxDB
title "INFLUXDB ($INFLUX_URL)"
python3 - <<'PY'
import os, json, base64, subprocess, urllib.request, urllib.parse
from datetime import datetime, timezone

URL = os.environ["INFLUX_URL"].rstrip("/")
DIR = os.environ["INFLUX_DIR"]
USER = os.environ.get("INFLUX_USER", "")
PASS = os.environ.get("INFLUX_PASS", "")
TOKEN = os.environ.get("INFLUX_TOKEN", "")
tty = os.isatty(1)
R, G, Y, N = ("\033[31m", "\033[32m", "\033[33m", "\033[0m") if tty else ("", "", "", "")

def req(path, headers=None):
    r = urllib.request.Request(URL + path, headers=headers or {})
    with urllib.request.urlopen(r, timeout=15) as resp:
        return resp.headers, resp.read()

def du(path):
    if not os.path.exists(path):
        return 0
    try:
        out = subprocess.run(["du", "-sb", path], capture_output=True, text=True).stdout
        return int(out.split()[0])
    except Exception:
        return 0

def human(n):
    for u in ["B", "K", "M", "G", "T"]:
        if n < 1024:
            return f"{n:.1f}{u}"
        n /= 1024
    return f"{n:.1f}P"

def age(ts):
    try:
        t = datetime.fromisoformat(ts.replace("Z", "+00:00"))
        days = (datetime.now(timezone.utc) - t).days
        return t.strftime("%Y-%m-%d"), days
    except Exception:
        return ts, None

# Phat hien version
try:
    h, _ = req("/ping")
    ver = h.get("X-Influxdb-Version", "?")
except Exception as e:
    print(f"{R}Khong ket noi duoc InfluxDB: {e}{N}")
    print("Chi bao cao dung luong thu muc:")
    for sub in ["data", "wal", "engine/data", "engine/wal"]:
        p = os.path.join(DIR, sub)
        if os.path.isdir(p):
            for name in sorted(os.listdir(p)):
                print(f"  {sub}/{name:<40} {human(du(os.path.join(p, name)))}")
    raise SystemExit

print(f"Phien ban: {ver}")

def influx_v1(q):
    params = {"q": q}
    hdr = {}
    if USER:
        hdr["Authorization"] = "Basic " + base64.b64encode(f"{USER}:{PASS}".encode()).decode()
    _, body = req("/query?" + urllib.parse.urlencode(params), hdr)
    data = json.loads(body)
    res = data["results"][0]
    if "error" in res:
        raise RuntimeError(res["error"])
    return res.get("series", [])

def rows(series):
    for s in series:
        cols = s["columns"]
        for v in s.get("values", []):
            yield s.get("name"), dict(zip(cols, v))

warn = []
if ver.startswith("1") or ver == "?":
    try:
        dbs = [r["name"] for _, r in rows(influx_v1("SHOW DATABASES"))]
    except Exception as e:
        print(f"{R}Loi query: {e}{N}")
        print("Neu co auth: INFLUX_USER=... INFLUX_PASS=... bash check-retention.sh")
        raise SystemExit
    shards = {}
    try:
        for _, r in rows(influx_v1("SHOW SHARDS")):
            k = (r["database"], r["retention_policy"])
            s = shards.setdefault(k, {"n": 0, "min": None, "max": None})
            s["n"] += 1
            if s["min"] is None or r["start_time"] < s["min"]:
                s["min"] = r["start_time"]
            if s["max"] is None or r["end_time"] > s["max"]:
                s["max"] = r["end_time"]
    except Exception as e:
        print(f"{Y}SHOW SHARDS loi (can quyen admin): {e}{N}")

    fmt = "{:<28} {:<16} {:>10} {:>10} {:>4} {:>7} {:>12} {:>9}"
    print()
    print(fmt.format("DATABASE", "RETENTION POLICY", "THOI HAN", "SHARD GRP", "DEF", "SHARDS", "DATA CU NHAT", "DUNG LUONG"))
    print("-" * 104)
    total = 0
    for db in dbs:
        try:
            rps = list(rows(influx_v1(f'SHOW RETENTION POLICIES ON "{db}"')))
        except Exception as e:
            print(f"{db:<28} {R}loi: {e}{N}")
            continue
        for _, rp in rps:
            name = rp["name"]
            dur = rp["duration"]
            size = du(os.path.join(DIR, "data", db, name))
            total += size
            sh = shards.get((db, name), {})
            oldest, days = age(sh["min"]) if sh.get("min") else ("-", None)
            oldest_s = f"{oldest} ({days}d)" if days is not None else oldest
            infinite = dur in ("0s", "0", "")
            dur_s = "VO HAN" if infinite else dur
            line = fmt.format(db[:28], name[:16], dur_s, rp.get("shardGroupDuration", "-"),
                              "*" if rp.get("default") else "", sh.get("n", "-"), oldest, human(size))
            if infinite:
                line = R + line + N
                warn.append(f'{db}.{name}: retention VO HAN, dang chiem {human(size)}, data tu {oldest_s}')
            print(line)
        wal = du(os.path.join(DIR, "wal", db))
        if wal > 1024 ** 3:
            print(f"{'':<28} {Y}WAL: {human(wal)}{N}")
    print("-" * 104)
    print(f"Tong data: {human(total)}   (thu muc {DIR}: {human(du(DIR))})")
else:
    if not TOKEN:
        print(f"{Y}InfluxDB 2.x can token: INFLUX_TOKEN=... bash check-retention.sh{N}")
        raise SystemExit
    _, body = req("/api/v2/buckets?limit=100", {"Authorization": "Token " + TOKEN})
    fmt = "{:<32} {:<18} {:>12} {:>10}"
    print()
    print(fmt.format("BUCKET", "ID", "THOI HAN", "DUNG LUONG"))
    print("-" * 76)
    for b in json.loads(body).get("buckets", []):
        secs = next((r.get("everySeconds", 0) for r in b.get("retentionRules", []) if r.get("type") == "expire"), 0)
        size = du(os.path.join(DIR, "engine", "data", b["id"]))
        dur = "VO HAN" if not secs else (f"{secs // 86400}d" if secs % 86400 == 0 else f"{secs // 3600}h")
        line = fmt.format(b["name"][:32], b["id"], dur, human(size))
        if not secs and not b["name"].startswith("_"):
            line = R + line + N
            warn.append(f'bucket {b["name"]}: retention VO HAN, dang chiem {human(size)}')
        print(line)

if warn:
    print(f"\n{R}CANH BAO:{N}")
    for w in warn:
        print(f"  {R}- {w}{N}")
    if ver.startswith("1"):
        print("\nVi du dat thoi han 90 ngay (xoa shard cu hon 90d o lan check ke tiep, ~30 phut):")
        print('  influx -execute \'ALTER RETENTION POLICY "autogen" ON "<db>" DURATION 90d SHARD DURATION 1d DEFAULT\'')
else:
    print(f"\n{G}Tat ca database deu co thoi han luu.{N}")
PY

# ---------------------------------------------------------------- Prometheus
title "PROMETHEUS"
declare -A PROM_DATA   # url -> thu muc data tren host
URLS=()
IFS=',' read -ra _u <<<"${PROM_URLS:-}"
for u in "${_u[@]}"; do [ -n "$u" ] && URLS+=("$u"); done

if command -v docker >/dev/null 2>&1; then
  while read -r cid name image; do
    [ -z "$cid" ] && continue
    case "$image" in *prometheus*) ;; *) continue ;; esac
    case "$image" in *exporter*|*pushgateway*|*alertmanager*) continue ;; esac
    port=$(docker port "$cid" 9090/tcp 2>/dev/null | head -1 | awk -F: '{print $NF}')
    args=$(docker inspect -f '{{join .Args " "}}' "$cid" 2>/dev/null)
    path=$(grep -o 'storage.tsdb.path=[^ ]*' <<<"$args" | cut -d= -f2)
    path=${path:-/prometheus}
    src=$(docker inspect -f "{{range .Mounts}}{{if eq .Destination \"$path\"}}{{.Source}}{{end}}{{end}}" "$cid" 2>/dev/null)
    echo "Container: ${B}$name${N} ($image)"
    echo "  Args    : $(grep -o -- '--storage[^ ]*' <<<"$args" | tr '\n' ' ')"
    [ -n "$src" ] && echo "  Data    : $src -> $path ($(du -sh "$src" 2>/dev/null | cut -f1))"
    if [ -n "$port" ]; then
      URLS+=("http://localhost:$port"); PROM_DATA["http://localhost:$port"]="$src"
    else
      ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "$cid" | awk '{print $1}')
      [ -n "$ip" ] && URLS+=("http://$ip:9090") && PROM_DATA["http://$ip:9090"]="$src"
    fi
  done < <(docker ps --format '{{.ID}} {{.Names}} {{.Image}}' 2>/dev/null)
fi

# Prometheus chay bang systemd / binary
pgrep -a prometheus 2>/dev/null | grep -v -- '-exporter' | grep -v docker | while read -r line; do
  echo "Process : $line" | cut -c1-200
done
[ ${#URLS[@]} -eq 0 ] && URLS+=("http://localhost:9090")

# bo trung
mapfile -t URLS < <(printf '%s\n' "${URLS[@]}" | awk '!seen[$0]++')

for url in "${URLS[@]}"; do
  echo
  echo "${B}-> $url${N}"
  PROM_URL="$url" PROM_HOSTDIR="${PROM_DATA[$url]:-}" python3 - <<'PY'
import os, json, subprocess, urllib.request, urllib.parse
from datetime import datetime

URL = os.environ["PROM_URL"].rstrip("/")
tty = os.isatty(1)
R, G, Y, N = ("\033[31m", "\033[32m", "\033[33m", "\033[0m") if tty else ("", "", "", "")

def api(path):
    with urllib.request.urlopen(URL + path, timeout=15) as r:
        return json.loads(r.read())["data"]

def q(expr):
    try:
        res = api("/api/v1/query?" + urllib.parse.urlencode({"query": expr}))["result"]
        return float(res[0]["value"][1]) if res else None
    except Exception:
        return None

def human(n):
    for u in ["B", "K", "M", "G", "T"]:
        if n < 1024:
            return f"{n:.1f}{u}"
        n /= 1024
    return f"{n:.1f}P"

try:
    flags = api("/api/v1/status/flags")
except Exception as e:
    print(f"  {R}Khong ket noi duoc: {e}{N}")
    raise SystemExit

rt = flags.get("storage.tsdb.retention.time", "")
rs = flags.get("storage.tsdb.retention.size", "")
old = flags.get("storage.tsdb.retention", "")
path = flags.get("storage.tsdb.path", "")
try:
    runtime = api("/api/v1/status/runtimeinfo").get("storageRetention", "")
except Exception:
    runtime = ""
try:
    ver = api("/api/v1/status/buildinfo").get("version", "?")
except Exception:
    ver = "?"

print(f"  Phien ban          : {ver}")
print(f"  retention.time     : {rt or '-'}" + ("  (khong dat -> mac dinh 15d)" if rt in ("", "0s") and rs in ("", "0B") and old in ("", "0s") else ""))
print(f"  retention.size     : {rs or '-'}" + ("  (khong gioi han)" if rs in ("", "0B") else ""))
if old not in ("", "0s"):
    print(f"  retention (cu)     : {old}")
print(f"  Thoi han thuc te   : {G}{runtime or '?'}{N}")
print(f"  tsdb.path          : {path}")

lowest = q("prometheus_tsdb_lowest_timestamp_seconds")
if lowest is None:
    v = q("prometheus_tsdb_lowest_timestamp")
    lowest = v / 1000 if v else None
if lowest:
    t = datetime.fromtimestamp(lowest)
    days = (datetime.now() - t).total_seconds() / 86400
    print(f"  Data cu nhat       : {t:%Y-%m-%d %H:%M} ({days:.1f} ngay)")

blocks = q("prometheus_tsdb_storage_blocks_bytes")
wal = q("prometheus_tsdb_wal_storage_size_bytes")
if blocks is not None:
    print(f"  Blocks size        : {human(blocks)}" + (f"   WAL: {human(wal)}" if wal else ""))
series = q("prometheus_tsdb_head_series")
if series is not None:
    print(f"  Head series        : {int(series):,}")

hostdir = os.environ.get("PROM_HOSTDIR") or (path if os.path.isdir(path) else "")
if hostdir and os.path.isdir(hostdir):
    out = subprocess.run(["du", "-sh", hostdir], capture_output=True, text=True).stdout.split()
    if out:
        print(f"  Thu muc tren host  : {hostdir} = {out[0]}")
PY
done

# ---------------------------------------------------------------- Config files
if [ -d "$SCAN_DIR" ]; then
  title "CAU HINH RETENTION TRONG $SCAN_DIR"
  grep -rnE --include='*.yml' --include='*.yaml' --include='*.env' --include='*.conf' --include='*.toml' \
    'retention|tsdb|INFLUXDB_.*RETENTION|DOCKER_INFLUXDB_INIT_RETENTION' "$SCAN_DIR" 2>/dev/null \
    | grep -v '/node_modules/' | head -40 || echo "Khong tim thay"
fi
if [ -f /etc/influxdb/influxdb.conf ]; then
  title "/etc/influxdb/influxdb.conf (retention)"
  sed -n '/^\[retention\]/,/^\[/p' /etc/influxdb/influxdb.conf | grep -vE '^\s*$'
fi
echo
