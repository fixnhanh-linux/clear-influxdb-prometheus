#!/usr/bin/env bash
# check-no-data.sh - Tim database / bucket InfluxDB khong co data moi trong N ngay (mac dinh 30)
# Chi DOC, khong xoa / sua gi. Lenh xoa chi in ra de tham khao.
#
# Cach dung:
#   bash check-no-data.sh                # 30 ngay
#   bash check-no-data.sh -d 60          # 60 ngay
#   bash check-no-data.sh -m             # them chi tiet measurement nao khong co data (query nang hon)
#   INFLUX_USER=admin INFLUX_PASS=xxx bash check-no-data.sh    # InfluxDB 1.x co auth
#   INFLUX_TOKEN=xxx bash check-no-data.sh                      # InfluxDB 2.x
#
# Cach xac dinh "lan ghi cuoi": thoi gian sua moi nhat cua file TSM / WAL trong thu muc
# cua tung database (nhanh, khong query). Nen chay bang root de doc duoc INFLUX_DIR.
# Neu khong doc duoc thu muc thi dung SHOW SHARDS (1.x) hoac query Flux (2.x).

DAYS=30
DETAIL=0
while getopts "d:mh" o; do
  case "$o" in
    d) DAYS="$OPTARG" ;;
    m) DETAIL=1 ;;
    *) sed -n '2,13p' "$0"; exit 0 ;;
  esac
done
case "$DAYS" in ''|*[!0-9]*) echo "-d phai la so ngay"; exit 1 ;; esac

command -v python3 >/dev/null || { echo "Can python3 de chay script nay"; exit 1; }

export INFLUX_URL="${INFLUX_URL:-http://localhost:8086}"
export INFLUX_DIR="${INFLUX_DIR:-/var/lib/influxdb}"
HERE=$(cd "$(dirname "$0")" && pwd)
# Khong truyen token / user -> tu tim tren server
if [ -z "${INFLUX_USER:-}${INFLUX_TOKEN:-}${INFLUX_CRED_DONE:-}" ] && [ -f "$HERE/find-influx-cred.sh" ]; then
  eval "$(bash "$HERE/find-influx-cred.sh" --env)"
fi
export INFLUX_USER INFLUX_PASS INFLUX_TOKEN

DAYS="$DAYS" DETAIL="$DETAIL" python3 - <<'PY'
import os, csv, io, json, time, base64, urllib.request, urllib.parse
from datetime import datetime, timezone

URL = os.environ["INFLUX_URL"].rstrip("/")
DIR = os.environ["INFLUX_DIR"]
USER = os.environ.get("INFLUX_USER", "")
PASS = os.environ.get("INFLUX_PASS", "")
TOKEN = os.environ.get("INFLUX_TOKEN", "")
DAYS = int(os.environ["DAYS"])
DETAIL = os.environ["DETAIL"] == "1"
NOW = time.time()
CUTOFF = NOW - DAYS * 86400
tty = os.isatty(1)
B, R, G, Y, C, N = ("\033[1m", "\033[31m", "\033[32m", "\033[33m", "\033[36m", "\033[0m") if tty else ("",) * 6

def req(path, headers=None, data=None, timeout=30):
    r = urllib.request.Request(URL + path, headers=headers or {}, data=data)
    with urllib.request.urlopen(r, timeout=timeout) as resp:
        return resp.headers, resp.read()

def scan(paths):
    """(mtime moi nhat, tong dung luong) cua cac file trong paths; mtime=None neu khong doc duoc"""
    newest, size, seen = 0, 0, False
    for p in paths:
        if not os.path.isdir(p):
            continue
        seen = True
        for root, _, files in os.walk(p):
            for f in files:
                try:
                    st = os.stat(os.path.join(root, f))
                except OSError:
                    continue
                size += st.st_size
                newest = max(newest, st.st_mtime)
    return (newest if seen else None), size

def human(n):
    for u in ["B", "K", "M", "G", "T"]:
        if n < 1024:
            return f"{n:.1f}{u}"
        n /= 1024
    return f"{n:.1f}P"

def parse_ts(s):
    return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()

def show_ts(ts):
    if not ts:
        return "-"
    return f"{datetime.fromtimestamp(ts):%Y-%m-%d %H:%M} ({max(0, int((NOW - ts) // 86400))}d)"

print(f"{B}{C}==== INFLUXDB: database / bucket KHONG co data trong {DAYS} ngay ===={N}")
print(f"URL: {URL}   Thu muc: {DIR}   Moc: truoc {datetime.fromtimestamp(CUTOFF):%Y-%m-%d %H:%M}")
try:
    h, _ = req("/ping")
    ver = h.get("X-Influxdb-Version", "?")
except Exception as e:
    print(f"{R}Khong ket noi duoc InfluxDB: {e}{N}")
    raise SystemExit(1)
print(f"Phien ban: {ver}\n")

fmt = "{:<26} {:<14} {:<24} {:>10}  {}"
header = fmt.format("DATABASE", "RETENTION", "GHI LAN CUOI", "DUNG LUONG", "TRANG THAI")
stale, total_stale = [], 0

def status(last, approx):
    if last is None:
        return f"{Y}KHONG RO{N}", False
    if last < CUTOFF:
        return f"{R}KHONG CO DATA {DAYS}d{N}", True
    return f"{G}OK{N}" + (" (~ theo shard)" if approx else ""), False

# ------------------------------------------------------------------ InfluxDB 1.x
if not ver.startswith("2"):
    def q(query, db=None, timeout=30):
        params = {"q": query}
        if db:
            params["db"] = db
        hdr = {}
        if USER:
            hdr["Authorization"] = "Basic " + base64.b64encode(f"{USER}:{PASS}".encode()).decode()
        _, body = req("/query?" + urllib.parse.urlencode(params), hdr, timeout=timeout)
        res = json.loads(body)["results"][0]
        if "error" in res:
            raise RuntimeError(res["error"])
        out = []
        for s in res.get("series", []):
            for v in s.get("values", []):
                out.append((s.get("name"), dict(zip(s["columns"], v))))
        return out

    try:
        dbs = [r["name"] for _, r in q("SHOW DATABASES")]
    except Exception as e:
        print(f"{R}Loi query: {e}{N}\nNeu co auth: INFLUX_USER=... INFLUX_PASS=... bash check-no-data.sh")
        raise SystemExit(1)
    shard_end = {}
    try:
        for _, r in q("SHOW SHARDS"):
            k = (r["database"], r["retention_policy"])
            # shard group chi duoc tao khi co point ghi vao -> end_time la moc tren cua data
            shard_end[k] = max(shard_end.get(k, 0), parse_ts(r["end_time"]))
    except Exception as e:
        print(f"{Y}SHOW SHARDS loi: {e}{N}")

    # in theo dung luong cao -> thap
    dbs.sort(key=lambda d: -scan([os.path.join(DIR, "data", d), os.path.join(DIR, "wal", d)])[1])
    print(header)
    print("-" * 100)
    for db in dbs:
        try:
            rps = [r for _, r in q(f'SHOW RETENTION POLICIES ON "{db}"')]
        except Exception as e:
            print(f"{db:<26} {R}loi: {e}{N}")
            continue
        rps.sort(key=lambda r: -scan([os.path.join(DIR, "data", db, r["name"])])[1])
        db_rows = []
        for rp in rps:
            name = rp["name"]
            last, size = scan([os.path.join(DIR, "data", db, name), os.path.join(DIR, "wal", db, name)])
            approx = False
            if last is None and (db, name) in shard_end:
                last, approx = min(shard_end[(db, name)], NOW), True
            elif last is None:
                last = 0 if shard_end else None   # khong co shard nao = chua tung co data
            st, is_stale = status(last, approx)
            db_rows.append((name, rp.get("default"), is_stale, size))
            line = fmt.format(db[:26], name[:14], ("~" if approx else "") + show_ts(last), human(size), st)
            print(line)
            if is_stale and db != "_internal":
                total_stale += size

        if DETAIL and db != "_internal" and not all(s for _, _, s, _ in db_rows):
            try:
                allm = {r["name"] for _, r in q("SHOW MEASUREMENTS", db)}
                live = set()
                for name, _, is_stale, _ in db_rows:
                    if is_stale:
                        continue
                    for m, _ in q(f'SELECT * FROM "{name}"./.*/ WHERE time > now() - {DAYS}d LIMIT 1', db, timeout=300):
                        live.add(m)
                dead = sorted(allm - live)
                if dead:
                    print(f"{'':<26} {Y}measurement khong co data {DAYS}d ({len(dead)}/{len(allm)}): {', '.join(dead[:15])}"
                          f"{' ...' if len(dead) > 15 else ''}{N}")
            except Exception as e:
                print(f"{'':<26} {Y}khong lay duoc chi tiet measurement: {e}{N}")

        if db == "_internal":
            continue
        if db_rows and all(s for _, _, s, _ in db_rows):
            stale.append(("db", db, None, sum(x[3] for x in db_rows)))
        else:
            for name, default, is_stale, size in db_rows:
                if is_stale:
                    stale.append(("rp", db, name, size, default))
    print("-" * 100)

    if stale:
        print(f"\n{R}{B}Co {len(stale)} muc khong co data trong {DAYS} ngay, tong {human(total_stale)}:{N}")
        print("Lenh tham khao (CHUA chay - kiem tra Grafana / nguoi dung truoc khi xoa):")
        for it in stale:
            if it[0] == "db":
                print(f"  influx -execute 'DROP DATABASE \"{it[1]}\"'        # {human(it[3])}")
            else:
                note = "   # LA POLICY MAC DINH - doi default truoc" if it[4] else ""
                print(f"  influx -execute 'DROP RETENTION POLICY \"{it[2]}\" ON \"{it[1]}\"'   # {human(it[3])}{note}")
    else:
        print(f"\n{G}Tat ca database deu co data trong {DAYS} ngay.{N}")

# ------------------------------------------------------------------ InfluxDB 2.x
else:
    if not TOKEN:
        print(f"{Y}InfluxDB 2.x can token: INFLUX_TOKEN=... bash check-no-data.sh{N}")
        raise SystemExit(1)
    auth = {"Authorization": "Token " + TOKEN}

    def flux(org_id, script, timeout=60):
        _, body = req("/api/v2/query?" + urllib.parse.urlencode({"orgID": org_id}),
                      dict(auth, **{"Content-Type": "application/vnd.flux", "Accept": "application/csv"}),
                      script.encode(), timeout)
        out, idx = [], None
        for row in csv.reader(io.StringIO(body.decode())):
            if not row:
                continue
            if "_measurement" in row:
                idx = row.index("_measurement")
            elif idx is not None and len(row) > idx:
                out.append(row[idx])
        return set(out)

    _, body = req("/api/v2/buckets?limit=100", auth)
    fmt = "{:<30} {:<18} {:<24} {:>10}  {}"
    print(fmt.format("BUCKET", "ID", "GHI LAN CUOI", "DUNG LUONG", "TRANG THAI"))
    print("-" * 104)
    buckets = json.loads(body).get("buckets", [])
    buckets.sort(key=lambda b: -scan([os.path.join(DIR, "engine", "data", b["id"])])[1])
    for b in buckets:
        bid, name = b["id"], b["name"]
        last, size = scan([os.path.join(DIR, "engine", "data", bid), os.path.join(DIR, "engine", "wal", bid)])
        live = None
        if last is None or DETAIL:
            try:
                live = flux(b["orgID"], f'from(bucket: "{name}") |> range(start: -{DAYS}d) |> limit(n: 1)'
                                        f' |> keep(columns: ["_measurement"]) |> group() |> distinct(column: "_measurement")', 300)
            except Exception as e:
                print(f"{name:<30} {Y}query loi: {e}{N}")
        if last is None and live is not None:
            st, is_stale = (f"{G}OK{N} (theo query)", False) if live else (f"{R}KHONG CO DATA {DAYS}d{N} (theo query)", True)
        else:
            st, is_stale = status(last, False)
        print(fmt.format(name[:30], bid, show_ts(last), human(size), st))
        if DETAIL and live is not None and not is_stale:
            try:
                allm = flux(b["orgID"], f'import "influxdata/influxdb/schema"\n'
                                        f'schema.measurements(bucket: "{name}", start: 1970-01-01T00:00:00Z)'
                                        f' |> rename(columns: {{_value: "_measurement"}})', 300)
                dead = sorted(allm - live)
                if dead:
                    print(f"{'':<30} {Y}measurement khong co data {DAYS}d ({len(dead)}/{len(allm)}): {', '.join(dead[:15])}{N}")
            except Exception as e:
                print(f"{'':<30} {Y}khong lay duoc chi tiet measurement: {e}{N}")
        if is_stale and not name.startswith("_"):
            stale.append((name, bid, size))
            total_stale += size
    print("-" * 104)
    if stale:
        print(f"\n{R}{B}Co {len(stale)} bucket khong co data trong {DAYS} ngay, tong {human(total_stale)}:{N}")
        print("Lenh tham khao (CHUA chay - kiem tra truoc khi xoa):")
        for name, bid, size in stale:
            print(f"  influx bucket delete --id {bid}     # {name}, {human(size)}")
    else:
        print(f"\n{G}Tat ca bucket deu co data trong {DAYS} ngay.{N}")
PY
