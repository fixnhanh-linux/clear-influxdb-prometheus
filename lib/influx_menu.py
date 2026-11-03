#!/usr/bin/env python3
# influx_menu.py - Menu tuong tac cho InfluxDB 1.x / 2.x (chay qua menu.sh).
# Xem bucket / database theo dung luong, dat thoi han luu, xoa bucket khong co data.
# Moi thao tac sua / xoa deu xem truoc va hoi xac nhan.
import os, re, sys, json, time, base64, shutil, subprocess, urllib.request, urllib.parse, urllib.error
from datetime import datetime

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
URL = os.environ.get("INFLUX_URL", "http://localhost:8086").rstrip("/")
DIR = os.environ.get("INFLUX_DIR", "/var/lib/influxdb")
USER = os.environ.get("INFLUX_USER", "")
PASS = os.environ.get("INFLUX_PASS", "")
TOKEN = os.environ.get("INFLUX_TOKEN", "")
SYSTEM = {"_monitoring", "_tasks", "_internal"}
KEEP = [7, 30, 90, 180, 365]

tty = sys.stdout.isatty()
B, D, R, G, Y, C, N = ("\033[1m", "\033[2m", "\033[31m", "\033[32m", "\033[33m", "\033[36m", "\033[0m") if tty else ("",) * 7

state = {"days": 30, "sort": "size", "filter": "all", "items": [], "view": [], "ver": "?", "v2": False, "loaded": 0}


# ------------------------------------------------------------------ tien ich
def col(text, width, align="<", color=""):
    s = f"{str(text)[:width]:{align}{width}}"
    return color + s + N if color else s

def human(n):
    for u in ["B", "K", "M", "G", "T"]:
        if abs(n) < 1024:
            return f"{n:.1f}{u}"
        n /= 1024
    return f"{n:.1f}P"

def bar(part, total, width=12):
    n = int(round(width * part / total)) if total else 0
    return "#" * n + "." * (width - n)

def fmt_days(d):
    if d is None:
        return "?"
    if d == 0:
        return "VO HAN"
    if d < 1:
        return f"{d * 24:g}h"
    return f"{d:g}d"

def fmt_ts(ts):
    if not ts:
        return "-"
    return f"{datetime.fromtimestamp(ts):%Y-%m-%d} ({max(0, int((time.time() - ts) // 86400))}d)"

def parse_days(s):
    """'90d' '12w' '1y' '48h' '90' -> so ngay; '0' / 'inf' -> 0; sai -> None"""
    s = s.strip().lower()
    if s in ("0", "inf", "vohan", "vo han"):
        return 0
    m = re.fullmatch(r"(\d+)\s*([hdwy]?)", s)
    if not m:
        return None
    return int(m.group(1)) * {"h": 1 / 24, "d": 1, "w": 7, "y": 365, "": 1}[m.group(2)]

def parse_dur(s):
    """'2160h0m0s' -> 90.0"""
    total, num = 0.0, ""
    for ch in s:
        if ch.isdigit() or ch == ".":
            num += ch
        else:
            total += float(num or 0) * {"h": 3600, "m": 60, "s": 1, "d": 86400, "w": 604800}.get(ch, 0)
            num = ""
    return total / 86400

def ask(prompt):
    try:
        return input(f"{B}{prompt}{N}").strip()
    except EOFError:
        print()
        sys.exit(0)

def pause():
    ask("\nEnter de quay lai menu...")

def clear():
    if tty:
        print("\033[2J\033[H", end="")


# ------------------------------------------------------------------ HTTP
def http(method, path, body=None, ctype="application/json", timeout=60, auth=True):
    hdr = {}
    if auth and TOKEN:
        hdr["Authorization"] = "Token " + TOKEN
    elif auth and USER:
        hdr["Authorization"] = "Basic " + base64.b64encode(f"{USER}:{PASS}".encode()).decode()
    data = None
    if body is not None:
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        hdr["Content-Type"] = ctype
    r = urllib.request.Request(URL + path, data=data, headers=hdr, method=method)
    with urllib.request.urlopen(r, timeout=timeout) as resp:
        return resp.headers, resp.read()

def err_text(e):
    if isinstance(e, urllib.error.HTTPError):
        try:
            body = json.loads(e.read())
            return f"HTTP {e.code}: {body.get('message') or body.get('error') or body}"
        except Exception:
            return f"HTTP {e.code}"
    return str(e)

def q1(query, write=False, db=None):
    """InfluxQL 1.x; write=True dung POST (ALTER / DROP)"""
    params = {"q": query}
    if db:
        params["db"] = db
    if write:
        _, body = http("POST", "/query", urllib.parse.urlencode(params).encode(), "application/x-www-form-urlencoded")
    else:
        _, body = http("GET", "/query?" + urllib.parse.urlencode(params))
    res = json.loads(body)["results"][0]
    if "error" in res:
        raise RuntimeError(res["error"])
    return [dict(zip(s["columns"], v)) for s in res.get("series", []) for v in s.get("values", [])]


# ------------------------------------------------------------------ doc du lieu
def shard_dirs(data_rp, wal_rp):
    """Moi shard: id, size (data + wal), mtime (file moi nhat)"""
    out = []
    if not os.path.isdir(data_rp):
        return out
    for sid in os.listdir(data_rp):
        size, newest = 0, 0
        for p in (os.path.join(data_rp, sid), os.path.join(wal_rp, sid)):
            for root, _, files in os.walk(p):
                for f in files:
                    try:
                        st = os.stat(os.path.join(root, f))
                    except OSError:
                        continue
                    size += st.st_size
                    newest = max(newest, st.st_mtime)
        out.append({"id": sid, "size": size, "mtime": newest, "end": newest})
    return out

def load():
    print(f"{D}Dang doc InfluxDB va thu muc {DIR} ...{N}", flush=True)
    try:
        h, _ = http("GET", "/ping", auth=False)
        state["ver"] = h.get("X-Influxdb-Version", "?").lstrip("vV")
    except Exception as e:
        print(f"{R}Khong ket noi duoc InfluxDB {URL}: {e}{N}")
        sys.exit(1)
    state["v2"] = state["ver"].startswith("2")
    items = []
    if state["v2"]:
        if not TOKEN:
            print(f"{R}InfluxDB 2.x chua co token. Chay: sudo bash find-influx-cred.sh{N}")
            sys.exit(1)
        buckets, offset = [], 0
        while True:
            try:
                _, body = http("GET", f"/api/v2/buckets?limit=100&offset={offset}")
            except Exception as e:
                print(f"{R}Khong lay duoc bucket ({err_text(e)}). Token sai / het quyen? Chay: sudo bash find-influx-cred.sh{N}")
                sys.exit(1)
            page = json.loads(body).get("buckets", [])
            buckets += page
            if len(page) < 100:
                break
            offset += 100
        try:
            _, body = http("GET", "/api/v2/orgs?limit=100")
            orgs = {o["id"]: o["name"] for o in json.loads(body).get("orgs", [])}
        except Exception:
            orgs = {}
        multi_org = len({b.get("orgID") for b in buckets}) > 1
        for b in buckets:
            rule = next((r for r in b.get("retentionRules", []) if r.get("type") == "expire"), {})
            base, wal = os.path.join(DIR, "engine", "data", b["id"]), os.path.join(DIR, "engine", "wal", b["id"])
            shards = []
            for rp in os.listdir(base) if os.path.isdir(base) else []:
                shards += shard_dirs(os.path.join(base, rp), os.path.join(wal, rp))
            items.append({"name": b["name"], "rp": None, "id": b["id"], "org": b.get("orgID"),
                          "orgname": orgs.get(b.get("orgID"), b.get("orgID")) if multi_org else None,
                          "ret": rule.get("everySeconds", 0) / 86400,
                          "sg": rule.get("shardGroupDurationSeconds", 0) / 86400, "default": False, "shards": shards})
    else:
        try:
            dbs = [r["name"] for r in q1("SHOW DATABASES")]
        except Exception as e:
            print(f"{R}Loi query ({err_text(e)}). Chay: sudo bash find-influx-cred.sh{N}")
            sys.exit(1)
        try:
            ends = {str(r["id"]): datetime.fromisoformat(r["end_time"].replace("Z", "+00:00")).timestamp()
                    for r in q1("SHOW SHARDS")}
        except Exception:
            ends = {}
        for db in dbs:
            for rp in q1(f'SHOW RETENTION POLICIES ON "{db}"'):
                shards = shard_dirs(os.path.join(DIR, "data", db, rp["name"]), os.path.join(DIR, "wal", db, rp["name"]))
                for s in shards:
                    s["end"] = ends.get(s["id"], s["mtime"])
                items.append({"name": db, "rp": rp["name"], "id": None, "org": None,
                              "ret": parse_dur(rp["duration"]), "sg": parse_dur(rp.get("shardGroupDuration", "0s")),
                              "default": bool(rp.get("default")), "shards": shards})
    for it in items:
        it["size"] = sum(s["size"] for s in it["shards"])
        it["last"] = max((s["mtime"] for s in it["shards"]), default=0)
        if it["rp"] is not None:
            it["label"] = f"{it['name']} / {it['rp']}"
        else:
            it["label"] = f"{it['name']} [{it['orgname']}]" if it.get("orgname") else it["name"]
        it["system"] = it["name"] in SYSTEM
    state["items"] = items
    state["loaded"] = time.time()

def stale(it):
    return it["last"] < time.time() - state["days"] * 86400

def older_than(it, days):
    """dung luong shard het han neu giu `days` ngay"""
    cut = time.time() - days * 86400
    return sum(s["size"] for s in it["shards"] if s["end"] < cut)


# ------------------------------------------------------------------ hien thi
def header():
    try:
        du = shutil.disk_usage(DIR if os.path.isdir(DIR) else "/")
        pct = 100 * du.used / du.total
        color = R if pct >= 90 else Y if pct >= 75 else G
        disk = f"{color}{bar(du.used, du.total, 20)} {pct:.0f}%{N}  dung {human(du.used)} / {human(du.total)}, con {human(du.free)}"
    except OSError:
        disk = "?"
    total = sum(i["size"] for i in state["items"])
    kind = "bucket" if state["v2"] else "retention policy"
    print(f"{B}{C}=== INFLUXDB MENU ==={N}  {URL}  phien ban {state['ver']}  "
          f"({'token' if TOKEN else 'user ' + USER if USER else 'khong auth'})")
    print(f"O dia {DIR}: {disk}")
    print(f"{len(state['items'])} {kind}, tong {human(total)}   "
          f"khong co data {state['days']}d: {sum(1 for i in state['items'] if stale(i))}   "
          f"VO HAN: {sum(1 for i in state['items'] if i['ret'] == 0 and not i['system'])}")

def table():
    items = state["items"]
    if state["filter"] == "stale":
        items = [i for i in items if stale(i)]
    elif state["filter"] == "inf":
        items = [i for i in items if i["ret"] == 0]
    key = {"size": lambda i: (i["system"], -i["size"]), "last": lambda i: i["last"], "name": lambda i: i["label"]}[state["sort"]]
    items = sorted(items, key=key)
    state["view"] = items
    total = sum(i["size"] for i in state["items"]) or 1
    w = max([len(i["label"]) for i in items] + [10])
    w = min(w, 40)
    head = (col("#", 4, ">") + "  " + col("BUCKET" if state["v2"] else "DATABASE / RP", w) + "  " + col("DUNG LUONG", 10, ">")
            + "  " + col("%", 5, ">") + "  " + col("", 12) + "  " + col("THOI HAN", 9, ">") + "  "
            + col("GHI LAN CUOI", 18) + "  TRANG THAI")
    print("\n" + B + head + N)
    print("-" * (len(head) + 4))
    for n, it in enumerate(items, 1):
        if it["system"]:
            st, sc = "he thong", D
        elif not it["size"]:
            st, sc = "TRONG (0B)", Y
        elif stale(it):
            st, sc = f"KHONG CO DATA {state['days']}d", R
        else:
            st, sc = "dang ghi", G
        ret = fmt_days(it["ret"]) + ("*" if it["default"] else "")
        print(col(n, 4, ">") + "  " + col(it["label"], w) + "  " + col(human(it["size"]), 10, ">") + "  "
              + col(f"{100 * it['size'] / total:.1f}", 5, ">") + "  " + bar(it["size"], total) + "  "
              + col(ret, 9, ">", R if it["ret"] == 0 and not it["system"] else "") + "  "
              + col(fmt_ts(it["last"]), 18) + "  " + sc + st + N)
    if not items:
        print(f"{D}(khong co dong nao){N}")
    if not state["v2"]:
        print(f"{D}* = retention policy mac dinh{N}")


def pick(prompt, allow_system=False):
    """'1,3,5-7' | 'v' = tat ca VO HAN | 's' = tat ca khong co data | 'a' = tat ca"""
    s = ask(prompt).lower().replace(" ", "")
    view = state["view"]
    if not s:
        return []
    if s == "a":
        sel = list(view)
    elif s == "v":
        sel = [i for i in view if i["ret"] == 0]
    elif s == "s":
        sel = [i for i in view if stale(i)]
    else:
        sel = []
        for part in s.split(","):
            m = re.fullmatch(r"(\d+)(?:-(\d+))?", part)
            if not m:
                print(f"{R}Khong hieu '{part}'{N}")
                return []
            a, b = int(m.group(1)), int(m.group(2) or m.group(1))
            for k in range(a, b + 1):
                if 1 <= k <= len(view):
                    sel.append(view[k - 1])
                else:
                    print(f"{Y}Bo qua so {k} (ngoai danh sach){N}")
    if not allow_system:
        skipped = [i["label"] for i in sel if i["system"]]
        if skipped:
            print(f"{Y}Bo qua bucket he thong: {', '.join(skipped)}{N}")
        sel = [i for i in sel if not i["system"]]
    return list({id(i): i for i in sel}.values())


# ------------------------------------------------------------------ chuc nang
def detail():
    sel = pick("So thu tu can xem: ", allow_system=True)
    for it in sel[:1]:
        print(f"\n{B}{it['label']}{N}" + (f"   id {it['id']}" if it["id"] else ""))
        print(f"  Dung luong   : {human(it['size'])}  ({len(it['shards'])} shard)")
        print(f"  Thoi han     : {fmt_days(it['ret'])}   shard group: {fmt_days(it['sg']) if it['sg'] else '-'}"
              + ("   (policy mac dinh)" if it["default"] else ""))
        print(f"  Ghi lan cuoi : {fmt_ts(it['last'])}")
        if not it["shards"]:
            continue
        months = {}
        for s in it["shards"]:
            k = datetime.fromtimestamp(s["end"]).strftime("%Y-%m")
            months[k] = months.get(k, 0) + s["size"]
        mx = max(months.values()) or 1
        print(f"\n  {B}Dung luong theo thang (theo moc cuoi cua shard){N}")
        for k in sorted(months):
            print(f"  {k}  {human(months[k]):>10}  {bar(months[k], mx, 30)}")
        print(f"\n  {B}Neu dat thoi han luu{N}")
        for d in KEEP:
            freed = older_than(it, d)
            print(f"  giu {d:>3}d  -> xoa {human(freed):>10}, con {human(it['size'] - freed):>10}")
    if sel:
        pause()

def set_retention():
    print(f"\nChon: so thu tu (vd {C}1,3,5-7{N}) | {C}v{N} = tat ca VO HAN | {C}s{N} = khong co data {state['days']}d | {C}a{N} = tat ca")
    sel = pick(("Bucket" if state["v2"] else "Database / RP") + " can dat thoi han: ")
    if not sel:
        return
    days = parse_days(ask("Thoi han moi (vd 30d, 90d, 12w, 1y, 0 = vo han): "))
    if days is None:
        print(f"{R}Thoi han khong hop le{N}")
        return pause()
    if 0 < days < 1:
        print(f"{R}Toi thieu 1 ngay{N}")
        return pause()
    print(f"\n{B}Xem truoc:{N}")
    w = min(max(len(i["label"]) for i in sel), 40)
    total = 0
    for it in sel:
        freed = older_than(it, days) if days else 0
        total += freed
        print(f"  {col(it['label'], w)}  {fmt_days(it['ret']):>8} -> {fmt_days(days):<8}  "
              f"{'xoa ' + human(freed) if freed else 'khong xoa gi':>16}  (hien {human(it['size'])})")
    print(f"  {B}Tong se giai phong (uoc tinh): {human(total)}{N}")
    if total:
        print(f"  {Y}Data cu hon {fmt_days(days)} se bi XOA VINH VIEN o lan kiem tra retention ke tiep (~30 phut).{N}")
    if ask("\nGo 'yes' de ap dung: ") != "yes":
        print("Huy.")
        return pause()
    for it in sel:
        try:
            if state["v2"]:
                secs = int(days * 86400)
                rules = []
                if secs:
                    rule = {"type": "expire", "everySeconds": secs}
                    if it["sg"] and it["sg"] > days:
                        rule["shardGroupDurationSeconds"] = 86400 if days >= 2 else 3600
                    rules.append(rule)
                http("PATCH", f"/api/v2/buckets/{it['id']}", {"retentionRules": rules})
            else:
                dur = f"{int(days)}d" if days else "INF"
                extra = " SHARD DURATION 1d" if days and it["sg"] > days else ""
                q1(f'ALTER RETENTION POLICY "{it["rp"]}" ON "{it["name"]}" DURATION {dur}{extra}', write=True)
            print(f"  {G}OK{N}   {it['label']} -> {fmt_days(days)}")
        except Exception as e:
            print(f"  {R}LOI{N}  {it['label']}: {err_text(e)}")
    load_quiet()
    pause()

def delete():
    print(f"\n{R}{B}XOA VINH VIEN - khong khoi phuc duoc.{N} Kiem tra Grafana / nguoi dung truoc.")
    print(f"Chon: so thu tu (vd {C}1,3,5-7{N}) | {C}s{N} = tat ca khong co data {state['days']}d")
    sel = pick(("Bucket" if state["v2"] else "Database / RP") + " can xoa: ")
    if not sel:
        return
    active = [i for i in sel if not stale(i)]
    actions = []   # (mo ta, ham)
    if state["v2"]:
        for it in sel:
            actions.append((it, f"xoa bucket {it['name']} ({it['id']})",
                            lambda it=it: http("DELETE", f"/api/v2/buckets/{it['id']}")))
    else:
        by_db = {}
        for it in sel:
            by_db.setdefault(it["name"], []).append(it)
        for db, its in by_db.items():
            all_rps = [i for i in state["items"] if i["name"] == db]
            if len(its) == len(all_rps):
                actions.append((its[0], f"DROP DATABASE \"{db}\" ({len(its)} retention policy)",
                                lambda db=db: q1(f'DROP DATABASE "{db}"', write=True)))
                for extra in its[1:]:
                    actions.append((extra, None, None))
                continue
            for it in its:
                if it["default"]:
                    print(f"{Y}Bo qua {it['label']}: la policy mac dinh, doi mac dinh truoc hoac xoa ca database{N}")
                    continue
                actions.append((it, f"DROP RETENTION POLICY \"{it['rp']}\" ON \"{db}\"",
                                lambda it=it: q1(f'DROP RETENTION POLICY "{it["rp"]}" ON "{it["name"]}"', write=True)))
    actions_run = [a for a in actions if a[1]]
    if not actions_run:
        return pause()
    total = sum(a[0]["size"] for a in actions)
    print(f"\n{B}Se thuc hien:{N}")
    for it, desc, _ in actions_run:
        flag = f"  {R}<- VAN DANG GHI DATA{N}" if it in active else ""
        print(f"  - {desc}   {human(it['size'])}{flag}")
    print(f"  {B}Tong: {human(total)}{N}")
    if active:
        print(f"{R}Co {len(active)} muc van dang ghi data trong {state['days']} ngay!{N}")
    if ask(f"\nGo 'XOA' (chu hoa) de xoa {len(actions_run)} muc: ") != "XOA":
        print("Huy.")
        return pause()
    for it, desc, fn in actions_run:
        try:
            fn()
            print(f"  {G}OK{N}   {desc}")
        except Exception as e:
            print(f"  {R}LOI{N}  {desc}: {err_text(e)}")
    load_quiet()
    pause()

def run_script(name, *args):
    env = dict(os.environ, INFLUX_CRED_DONE="1")
    print()
    subprocess.call(["bash", os.path.join(HERE, name), *args], env=env)
    pause()

def load_quiet():
    try:
        load()
    except SystemExit:
        pass


# ------------------------------------------------------------------ menu
def main():
    load()
    while True:
        clear()
        header()
        table()
        flt = {"all": "tat ca", "stale": f"khong co data {state['days']}d", "inf": "VO HAN"}[state["filter"]]
        srt = {"size": "dung luong", "last": "ghi lan cuoi", "name": "ten"}[state["sort"]]
        print(f"""
{B}  1{N}  Xem chi tiet (dung luong theo thang, uoc tinh giai phong)
{B}  2{N}  Dat thoi han luu (retention)
{B}  3{N}  Xoa bucket / database
{B}  4{N}  Loc: {C}{flt}{N}  (doi: tat ca -> khong co data -> VO HAN)
{B}  5{N}  Sap xep: {C}{srt}{N}  (doi: dung luong -> ghi lan cuoi -> ten)
{B}  6{N}  Doi so ngay "khong co data" (dang {state['days']})
{B}  7{N}  Bao cao day du (check-all.sh, luu file)
{B}  8{N}  Dung luong chi tiet + top measurement (check-size.sh)
{B}  9{N}  Thoi han luu InfluxDB + Prometheus (check-retention.sh)
{B}  t{N}  Tim token / user (find-influx-cred.sh)
{B}  r{N}  Tai lai          {B}0{N}  Thoat""")
        c = ask("\nChon: ").lower()
        if c == "1":
            detail()
        elif c == "2":
            set_retention()
        elif c == "3":
            delete()
        elif c == "4":
            state["filter"] = {"all": "stale", "stale": "inf", "inf": "all"}[state["filter"]]
        elif c == "5":
            state["sort"] = {"size": "last", "last": "name", "name": "size"}[state["sort"]]
        elif c == "6":
            d = parse_days(ask("So ngay: "))
            if d:
                state["days"] = d
        elif c == "7":
            run_script("check-all.sh", "-d", str(int(state["days"])))
        elif c == "8":
            run_script("check-size.sh")
        elif c == "9":
            run_script("check-retention.sh")
        elif c == "t":
            run_script("find-influx-cred.sh")
        elif c == "r":
            load()
        elif c in ("0", "q", "exit"):
            break

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print()
