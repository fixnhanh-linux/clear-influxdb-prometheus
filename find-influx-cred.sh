#!/usr/bin/env bash
# find-influx-cred.sh - Tu tim token (InfluxDB 2.x) hoac user/password (1.x) tren chinh server,
# thu tung cai voi InfluxDB va chon cai dung duoc. Chi DOC, khong tao / sua token.
#
# Cach dung:
#   sudo bash find-influx-cred.sh            # liet ke cac token / user tim thay (an bot ky tu)
#   sudo bash find-influx-cred.sh --show     # hien day du token / password
#   bash find-influx-cred.sh --env           # in INFLUX_TOKEN=... / INFLUX_USER=... de eval (2 script kia dung)
#
# Tim o:
#   ~/.influxdbv2/configs, /etc/influxdb2/influx-configs   (config cua lenh influx CLI)
#   /etc/telegraf/telegraf.conf, telegraf.d/*.conf, /etc/default/telegraf   ([[outputs.influxdb*]])
#   /etc/grafana/provisioning/datasources/*.yaml           (datasource type influxdb)
#   .env / docker-compose / *.conf trong SCAN_DIR va /opt  (bien co chu INFLUX)
#   bien moi truong va /etc/influxdb2/influx-configs cua container docker
#   InfluxDB 2.x: neu van chua co token dung duoc -> doc ban sao cua influxd.bolt
#                 bang "influxd recovery auth list" (khong dung toi file dang chay)

MODE=list
for a in "$@"; do
  case "$a" in
    --env) MODE=env ;;
    --show) MODE=show ;;
    *) sed -n '2,19p' "$0"; exit 0 ;;
  esac
done
command -v python3 >/dev/null || { echo "Can python3" >&2; exit 1; }

MODE="$MODE" \
INFLUX_URL="${INFLUX_URL:-http://localhost:8086}" \
INFLUX_DIR="${INFLUX_DIR:-/var/lib/influxdb}" \
SCAN_DIR="${SCAN_DIR:-/opt/monitor-grafana-vcenter-total-cluster-prometheus}" \
CRED_ROOT="${CRED_ROOT:-}" python3 - <<'PY'
import os, re, sys, glob, json, shlex, base64, shutil, tempfile, subprocess, urllib.request, urllib.parse

MODE = os.environ["MODE"]
URL = os.environ["INFLUX_URL"].rstrip("/")
DIR = os.environ["INFLUX_DIR"]
SCAN_DIR = os.environ["SCAN_DIR"]
ROOT = os.environ["CRED_ROOT"]          # tien to duong dan, chi dung khi test
tty = os.isatty(1) and MODE != "env"
B, R, G, Y, N = ("\033[1m", "\033[31m", "\033[32m", "\033[33m", "\033[0m") if tty else ("",) * 5

def log(msg):
    print(msg, file=sys.stderr if MODE == "env" else sys.stdout)

def P(p):
    return ROOT + p

def read(path, limit=2 * 1024 * 1024):
    try:
        if os.path.getsize(path) > limit:
            return ""
        with open(path, errors="ignore") as f:
            return f.read()
    except OSError:
        return ""

def run(cmd, timeout=30):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout).stdout
    except Exception:
        return ""

cands, seen = [], set()
envvars = dict(os.environ)

def resolve(v):
    m = re.fullmatch(r"\$\{?(\w+)\}?", v)
    return envvars.get(m.group(1)) if m else v

def add(kind, src, a, b=None):
    a = resolve(a) if a else a
    b = resolve(b) if b else b
    if not a or (kind == "user" and not b):
        return
    key = (kind, a, b)
    if key not in seen:
        seen.add(key)
        cands.append({"kind": kind, "src": src, "a": a, "b": b})

V = r"""\s*[:=]\s*["']?([^"'\s#,]+)"""

def parse(text, src, style):
    """style: influxcfg | toml | grafana | env"""
    if style == "env":
        for k, v in re.findall(r'(?m)^\s*(?:-\s*)?(?:export\s+)?["\']?(\w+)["\']?' + V, text):
            envvars.setdefault(k, v)
        users = re.findall(r'(?im)^\s*(?:-\s*)?["\']?\w*INFLUX\w*_(?:USER|USERNAME)["\']?' + V, text)
        pws = re.findall(r'(?im)^\s*(?:-\s*)?["\']?\w*INFLUX\w*_PASSWORD["\']?' + V, text)
        for t in re.findall(r'(?im)^\s*(?:-\s*)?["\']?\w*INFLUX\w*TOKEN["\']?' + V, text):
            add("token", src, t)
        for u, p in zip(users, pws):
            add("user", src, u, p)
        return
    split = r"(?m)^\s*-\s+name:" if style == "grafana" else r"(?m)^\s*\["
    starts = [m.start() for m in re.finditer(split, text)] or [0]
    for i, s in enumerate(starts):
        chunk = text[s:starts[i + 1] if i + 1 < len(starts) else len(text)]
        head = chunk.splitlines()[0] if chunk.strip() else ""
        if style == "toml" and "outputs.influxdb" not in head:
            continue
        if style == "grafana" and not re.search(r"(?im)^\s*type:\s*['\"]?influxdb", chunk):
            continue
        for t in re.findall(r"(?im)^\s*[\"']?token[\"']?" + V, chunk):
            add("token", src, t)
        users = re.findall(r"(?im)^\s*[\"']?(?:username|user)[\"']?" + V, chunk)
        pws = re.findall(r"(?im)^\s*[\"']?password[\"']?" + V, chunk)
        for u, p in zip(users, pws):
            add("user", src, u, p)

# ---- file env truoc de resolve ${VAR}
for f in [P("/etc/default/telegraf"), P("/etc/default/influxdb"), P("/etc/default/influxdb2")]:
    parse(read(f), f, "env")

# ---- influx CLI configs
for pat in ["/root/.influxdbv2/configs", "/home/*/.influxdbv2/configs",
            "/etc/influxdb2/influx-configs", "/etc/influxdb2/configs", "/var/lib/influxdb2/configs"]:
    for f in glob.glob(P(pat)):
        parse(read(f), f, "influxcfg")

# ---- telegraf
for pat in ["/etc/telegraf/telegraf.conf", "/etc/telegraf/telegraf.d/*.conf"]:
    for f in sorted(glob.glob(P(pat))):
        parse(read(f), f, "toml")

# ---- grafana provisioning
for f in sorted(glob.glob(P("/etc/grafana/provisioning/datasources/*.y*ml"))):
    parse(read(f), f, "grafana")

# ---- .env / compose / conf trong SCAN_DIR va /opt (sau toi da 3 cap)
SKIP = {".git", "node_modules", "data", "influxdb", "influxdb2", "prometheus", "grafana", "wal", "engine"}
for base in dict.fromkeys([P(SCAN_DIR), P("/opt")]):
    if not os.path.isdir(base):
        continue
    depth0 = base.rstrip("/").count("/")
    for root, dirs, files in os.walk(base):
        if root.count("/") - depth0 >= 3:
            dirs[:] = []
        dirs[:] = [d for d in dirs if d not in SKIP]
        for fn in files:
            f = os.path.join(root, fn)
            low = fn.lower()
            if low == ".env" or low.endswith(".env"):
                parse(read(f), f, "env")
            elif low.endswith((".yml", ".yaml")):
                t = read(f)
                parse(t, f, "env")
                parse(t, f, "grafana")
            elif low.endswith((".conf", ".toml")) and "influx" in read(f, 512 * 1024).lower():
                parse(read(f), f, "toml")

# ---- docker
if shutil.which("docker"):
    for cid in run(["docker", "ps", "-q"]).split():
        try:
            info = json.loads(run(["docker", "inspect", cid]))[0]
        except Exception:
            continue
        name = info.get("Name", cid).lstrip("/")
        parse("\n".join(info.get("Config", {}).get("Env") or []), f"docker:{name} (env)", "env")
        if "influx" in info.get("Config", {}).get("Image", ""):
            for cf in ["/etc/influxdb2/influx-configs", "/root/.influxdbv2/configs"]:
                parse(run(["docker", "exec", cid, "cat", cf]), f"docker:{name}:{cf}", "influxcfg")

# ---- kiem tra voi InfluxDB
def req(path, headers=None, timeout=10):
    r = urllib.request.Request(URL + path, headers=headers or {})
    with urllib.request.urlopen(r, timeout=timeout) as resp:
        return resp.headers, resp.read()

try:
    h, _ = req("/ping")
    ver = h.get("X-Influxdb-Version", "?")
except Exception as e:
    log(f"{R}Khong ket noi duoc InfluxDB {URL}: {e}{N}")
    ver = None

def check_token(tok):
    try:
        _, body = req("/api/v2/buckets?limit=100", {"Authorization": "Token " + tok})
        return True, f"{len(json.loads(body).get('buckets', []))} bucket"
    except urllib.error.HTTPError as e:
        return False, f"HTTP {e.code}"
    except Exception as e:
        return False, str(e)[:40]

def q1(query, user=None, pw=None):
    hdr = {}
    if user is not None:
        hdr["Authorization"] = "Basic " + base64.b64encode(f"{user}:{pw}".encode()).decode()
    _, body = req("/query?" + urllib.parse.urlencode({"q": query}), hdr)
    res = json.loads(body)["results"][0]
    if "error" in res:
        raise RuntimeError(res["error"])

def check_user(u, p):
    try:
        q1("SHOW DATABASES", u, p)
    except urllib.error.HTTPError as e:
        return False, f"HTTP {e.code}"
    except Exception as e:
        return False, str(e)[:40]
    try:
        q1("SHOW USERS", u, p)
        return True, "admin"
    except Exception:
        return True, "khong phai admin"

v2 = bool(ver and ver.startswith("2"))
noauth = False
if ver and not v2:
    try:
        q1("SHOW DATABASES")
        noauth = True
    except Exception:
        pass

def validate():
    for c in cands:
        if "ok" in c or not ver:
            continue
        if c["kind"] == "token":
            c["ok"], c["note"] = check_token(c["a"]) if v2 else (False, "token cua 2.x")
        else:
            c["ok"], c["note"] = check_user(c["a"], c["b"]) if not v2 else (False, "user/pass cua 1.x")

validate()

# ---- 2.x: van chua co token -> doc ban sao influxd.bolt
if v2 and not any(c.get("ok") for c in cands):
    tokre = re.compile(r"\b([A-Za-z0-9_\-]{60,}==)")
    bolts = [P("/var/lib/influxdb2/influxd.bolt"), os.path.join(DIR, "influxd.bolt"), P("/root/.influxdbv2/influxd.bolt")]
    bolt = next((b for b in bolts if os.path.isfile(b)), None)
    if bolt and shutil.which("influxd"):
        tmp = tempfile.mkdtemp()
        try:
            os.chmod(tmp, 0o700)
            shutil.copy2(bolt, os.path.join(tmp, "influxd.bolt"))
            out = run(["influxd", "recovery", "auth", "list", "--bolt-path", os.path.join(tmp, "influxd.bolt")], 60)
            for t in tokre.findall(out):
                add("token", f"influxd recovery ({bolt})", t)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
    elif shutil.which("docker"):
        for cid in run(["docker", "ps", "-q", "--filter", "ancestor=influxdb"]).split() + \
                   run(["docker", "ps", "-q", "--filter", "name=influx"]).split():
            out = run(["docker", "exec", cid, "sh", "-c",
                       "cp /var/lib/influxdb2/influxd.bolt /tmp/.cred.bolt && "
                       "influxd recovery auth list --bolt-path /tmp/.cred.bolt; rm -f /tmp/.cred.bolt"], 60)
            for t in tokre.findall(out):
                add("token", f"docker:{cid} influxd recovery", t)
    validate()

def mask(v):
    if MODE == "show":
        return v
    return v[:4] + "..." + v[-4:] if len(v) > 12 else v[:1] + "***"

def score(c):
    n = re.match(r"(\d+)", c.get("note", ""))
    return (c.get("ok", False), c.get("note") == "admin", int(n.group(1)) if n else 0)

best = max(cands, key=score) if cands else None
best = best if best and best.get("ok") else None

if MODE == "env":
    if noauth:
        sys.exit(0)
    if best and best["kind"] == "token":
        print(f"INFLUX_TOKEN={shlex.quote(best['a'])}")
    elif best:
        print(f"INFLUX_USER={shlex.quote(best['a'])} INFLUX_PASS={shlex.quote(best['b'])}")
    if best:
        log(f"Tu tim thay {'token' if best['kind'] == 'token' else 'user ' + best['a']} tu {best['src']} ({best['note']})")
    elif ver:
        log("Khong tu tim duoc token / user InfluxDB. Chay: sudo bash find-influx-cred.sh")
    sys.exit(0)

print(f"{B}==== TIM TOKEN / USER INFLUXDB ===={N}")
print(f"InfluxDB: {URL}  phien ban {ver or '?'}")
if noauth:
    print(f"{G}InfluxDB 1.x KHONG bat auth -> khong can user / password.{N}")
print()
if not cands:
    print(f"{Y}Khong tim thay token / user nao.{N}")
else:
    fmt = "{:<5} {:<34} {:<40} {}"
    print(fmt.format("LOAI", "GIA TRI", "NGUON", "KET QUA"))
    print("-" * 100)
    for c in sorted(cands, key=score, reverse=True):
        val = mask(c["a"]) if c["kind"] == "token" else f"{c['a']} / {mask(c['b'])}"
        res = (G + "OK " + c["note"] + N) if c.get("ok") else (R + c.get("note", "chua kiem tra") + N)
        src = c["src"] if len(c["src"]) <= 40 else "..." + c["src"][-37:]
        print(fmt.format(c["kind"], val, src, res))
    print("-" * 100)

if best:
    print(f"\n{B}Dung:{N} {best['src']}")
    if best["kind"] == "token":
        print(f"  INFLUX_TOKEN='{mask(best['a'])}'")
    else:
        print(f"  INFLUX_USER='{best['a']}' INFLUX_PASS='{mask(best['b'])}'")
    print("check-retention.sh / check-no-data.sh tu dung cai nay, khong can truyen.")
    if MODE != "show":
        print("Xem day du: sudo bash find-influx-cred.sh --show")
elif v2:
    print(f"\n{Y}Khong co token dung duoc. Tao token operator moi (InfluxDB 2.1+, can dung influxd hoac lam tren ban sao):{N}")
    print("  influxd recovery auth create-operator --org <org> --username <user>")
PY
