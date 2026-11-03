# clear-influxdb-prometheus

Read-only scripts that show how long InfluxDB and Prometheus keep data, and which InfluxDB databases / buckets have stopped receiving data — so you know what to clean before the disk fills up.

| Script | What it reports |
| --- | --- |
| [`menu.sh`](menu.sh) | Interactive menu: aligned table of buckets / databases by size, details per bucket (size per month, what each retention would free), set retention, delete buckets with no data, run the reports. Every change is previewed and needs confirmation |
| [`check-all.sh`](check-all.sh) | Runs the three checks below in one go and saves the report to a text file |
| [`check-size.sh`](check-size.sh) | Everything sorted by size, largest first: directories on the server, InfluxDB databases / retention policies / measurements, Prometheus metrics and labels by series count, and how much would be freed by keeping only 30 / 90 / 180 / 365 days |
| [`check-retention.sh`](check-retention.sh) | Retention of every InfluxDB database / retention policy (1.x) or bucket (2.x), oldest data, size on disk; Prometheus retention time / size, oldest sample, TSDB size |
| [`check-no-data.sh`](check-no-data.sh) | InfluxDB databases / retention policies / buckets with no new data in the last N days (default 30), optionally down to measurement level |
| [`find-influx-cred.sh`](find-influx-cred.sh) | Finds the InfluxDB token (2.x) or user / password (1.x) already stored on the server, tests each one and picks the one that works. The other two scripts call it automatically when no credentials are passed |

All scripts except `menu.sh` only read. Any `DROP` / `ALTER` / `delete` command they print is a suggestion and is never executed.

<details>
<summary><b>English</b></summary>

## Requirements

- Bash, `python3` (standard library only), `du`, `df`
- Run as `root` so the scripts can read `/var/lib/influxdb`
- `docker` (optional) to auto-detect Prometheus containers

## Quick start

```bash
git clone https://github.com/fixnhanh-linux/clear-influxdb-prometheus.git
cd clear-influxdb-prometheus
sudo bash check-all.sh          # full report, also saved to report-<host>-<date>.txt
sudo bash menu.sh               # interactive menu
```

## menu.sh

```bash
sudo bash menu.sh
```

- Header: disk usage of the InfluxDB directory, number of buckets, how many have no data / infinite retention.
- Table sorted by size (or last write / name), filter all / no data in N days / infinite retention.
- **1** details: size per month, data freed by keeping 7 / 30 / 90 / 180 / 365 days.
- **2** set retention: pick rows (`1,3,5-7`, `v` = all infinite, `s` = all with no data, `a` = all), enter `30d` / `12w` / `1y` / `0` (infinite), preview how much will be deleted, type `yes`. 2.x uses `PATCH /api/v2/buckets/<id>`, 1.x `ALTER RETENTION POLICY` (shard group shortened when needed).
- **3** delete: pick rows, preview, type `XOA`. 2.x deletes the bucket; 1.x drops the whole database when all its retention policies are selected, otherwise `DROP RETENTION POLICY` (the default policy is skipped). System buckets (`_monitoring`, `_tasks`, `_internal`) are never changed.
- **7 / 8 / 9 / t** run `check-all.sh`, `check-size.sh`, `check-retention.sh`, `find-influx-cred.sh`.

## check-all.sh

```bash
sudo bash check-all.sh                     # report saved to ./report-<host>-<date time>.txt
sudo bash check-all.sh -d 60               # "no data" threshold 60 days (default 30)
sudo bash check-all.sh -q                  # quick: skip per-measurement sizes
sudo bash check-all.sh -o /tmp/report.txt  # choose the report file
```

## check-size.sh

```bash
sudo bash check-size.sh          # full (runs influx_inspect report-disk, can take minutes on large data)
sudo bash check-size.sh -q       # quick: skip per-measurement sizes
sudo bash check-size.sh -n 30    # number of top rows (default 15)
```

- Top directories under `/var/lib`, `/var/log`, `/opt`, `/home`, plus `docker system df` and the largest docker volumes.
- InfluxDB size per database and per retention policy with percentage bar, shard count and retention (infinite ones in red).
- **If retention were set**: for every retention policy, how much data is older than 30 / 90 / 180 / 365 days, based on shard end times (1.x) or shard file times (2.x).
- Top measurements by disk size via `influx_inspect report-disk -detailed` (InfluxDB 1.8+, timeout `INSPECT_TIMEOUT`, default 1200 s).
- Prometheus: top metrics and `label=value` pairs by series count, and labels with the most values (`/api/v1/status/tsdb`).

## check-retention.sh

```bash
sudo bash check-retention.sh                                          # token / user found automatically
sudo INFLUX_USER=admin INFLUX_PASS=xxx bash check-retention.sh        # InfluxDB 1.x, give credentials yourself
sudo INFLUX_TOKEN=xxx bash check-retention.sh                         # InfluxDB 2.x, give the token yourself
sudo PROM_URLS=http://10.0.0.5:9090 bash check-retention.sh           # Prometheus not on localhost / not in docker
```

- Retention policies with duration `0s` are shown as **VO HAN** (infinite) in red, with the oldest shard date and the size they use.
- Prometheus: `retention.time`, `retention.size`, effective retention, oldest sample, blocks / WAL size, head series, and the host data directory of docker containers.
- Greps `retention` / `tsdb` settings in docker-compose files under `SCAN_DIR` and the `[retention]` section of `/etc/influxdb/influxdb.conf`.

## check-no-data.sh

```bash
sudo bash check-no-data.sh           # 30 days
sudo bash check-no-data.sh -d 60     # 60 days
sudo bash check-no-data.sh -m        # also list measurements with no data (heavier query)
```

- **Last write** = newest modification time of the TSM / WAL files of each database (fast, no query). If the directory cannot be read it falls back to `SHOW SHARDS` (1.x, marked `~`, accurate to one shard group) or a Flux query (2.x).
- When a whole database is stale it suggests `DROP DATABASE`; when only one retention policy is stale, `DROP RETENTION POLICY` (with a warning if it is the default policy). For 2.x, `influx bucket delete --id`.
- `-m` queries the last N days of every live retention policy, so it can be slow on large databases.

## find-influx-cred.sh - forgot the token / password?

```bash
sudo bash find-influx-cred.sh          # list what was found, values partly hidden
sudo bash find-influx-cred.sh --show   # show full token / password
```

Looks in: `~/.influxdbv2/configs` and `/etc/influxdb2/influx-configs` (influx CLI), `[[outputs.influxdb]]` / `[[outputs.influxdb_v2]]` in telegraf config (with `${VAR}` from `/etc/default/telegraf`), Grafana datasource provisioning of type `influxdb`, `INFLUX*` variables in `.env` / docker-compose files under `SCAN_DIR` and `/opt`, environment and influx CLI config of docker containers. Credentials of other telegraf plugins (vSphere, SNMP...) are ignored.

Each candidate is tested against `INFLUX_URL`: 1.x prefers an admin user (needed for `SHOW SHARDS`), 2.x prefers the token that sees the most buckets. On 2.x, if no working token is found it reads a **copy** of `influxd.bolt` with `influxd recovery auth list` (the running database file is not touched).

## Environment variables

| Variable | Default | Used by |
| --- | --- | --- |
| `INFLUX_URL` | `http://localhost:8086` | all |
| `INFLUX_DIR` | `/var/lib/influxdb` | all |
| `INFLUX_USER` / `INFLUX_PASS` | found automatically | all (InfluxDB 1.x auth) |
| `INFLUX_TOKEN` | found automatically | all (InfluxDB 2.x) |
| `PROM_URLS` | auto-detected docker containers, else `http://localhost:9090` | check-retention.sh, check-size.sh |
| `SCAN_DIR` | `/opt/monitor-grafana-vcenter-total-cluster-prometheus` | check-retention.sh, find-influx-cred.sh |
| `INSPECT_TIMEOUT` | `1200` | check-size.sh |

</details>

<details>
<summary><b>Tieng Viet</b></summary>

## Yeu cau

- Bash, `python3` (chi dung thu vien chuan), `du`, `df`
- Chay bang `root` de doc duoc `/var/lib/influxdb`
- `docker` (khong bat buoc) de tu tim container Prometheus

## Chay nhanh

```bash
git clone https://github.com/fixnhanh-linux/clear-influxdb-prometheus.git
cd clear-influxdb-prometheus
sudo bash check-all.sh          # bao cao day du, luu ra report-<host>-<ngay>.txt
sudo bash menu.sh               # menu tuong tac
```

## menu.sh - menu tuong tac

```bash
sudo bash menu.sh
```

- Dau trang: dung luong o dia cua thu muc InfluxDB, so bucket, bao nhieu bucket khong co data / thoi han VO HAN.
- Bang sap xep theo dung luong (hoac ghi lan cuoi / ten), loc tat ca / khong co data N ngay / VO HAN.
- **1** chi tiet: dung luong theo thang, giai phong bao nhieu neu giu 7 / 30 / 90 / 180 / 365 ngay.
- **2** dat thoi han luu: chon dong (`1,3,5-7`, `v` = tat ca VO HAN, `s` = tat ca khong co data, `a` = tat ca), nhap `30d` / `12w` / `1y` / `0` (vo han), xem truoc se xoa bao nhieu, go `yes`. 2.x dung `PATCH /api/v2/buckets/<id>`, 1.x dung `ALTER RETENTION POLICY` (tu rut shard group khi can).
- **3** xoa: chon dong, xem truoc, go `XOA`. 2.x xoa bucket; 1.x xoa ca database neu chon het retention policy cua no, neu khong thi `DROP RETENTION POLICY` (bo qua policy mac dinh). Bucket he thong (`_monitoring`, `_tasks`, `_internal`) khong bao gio bi sua / xoa.
- **7 / 8 / 9 / t** chay `check-all.sh`, `check-size.sh`, `check-retention.sh`, `find-influx-cred.sh`.

## check-all.sh - chay tat ca

```bash
sudo bash check-all.sh                     # bao cao luu o ./report-<host>-<ngay gio>.txt
sudo bash check-all.sh -d 60               # moc "khong co data" 60 ngay (mac dinh 30)
sudo bash check-all.sh -q                  # nhanh: bo qua dung luong tung measurement
sudo bash check-all.sh -o /tmp/report.txt  # chon file bao cao
```

## check-size.sh - dung luong cao -> thap

```bash
sudo bash check-size.sh          # day du (chay influx_inspect report-disk, data lon co the vai phut)
sudo bash check-size.sh -q       # nhanh: bo qua dung luong tung measurement
sudo bash check-size.sh -n 30    # so dong top (mac dinh 15)
```

- Top thu muc trong `/var/lib`, `/var/log`, `/opt`, `/home`, kem `docker system df` va volume docker lon nhat.
- Dung luong InfluxDB theo database va retention policy: %, thanh ty le, so shard, thoi han (VO HAN to do).
- **Neu dat thoi han luu**: moi retention policy co bao nhieu data cu hon 30 / 90 / 180 / 365 ngay, tinh theo end time cua shard (1.x) hoac thoi gian file cua shard (2.x).
- Top measurement theo dung luong qua `influx_inspect report-disk -detailed` (InfluxDB 1.8+, gioi han `INSPECT_TIMEOUT`, mac dinh 1200 giay).
- Prometheus: top metric va cap `label=value` theo so series, label co nhieu gia tri nhat (`/api/v1/status/tsdb`).

## check-retention.sh - bao cao thoi han luu

```bash
sudo bash check-retention.sh                                          # tu tim token / user
sudo INFLUX_USER=admin INFLUX_PASS=xxx bash check-retention.sh        # InfluxDB 1.x, tu truyen user
sudo INFLUX_TOKEN=xxx bash check-retention.sh                         # InfluxDB 2.x, tu truyen token
sudo PROM_URLS=http://10.0.0.5:9090 bash check-retention.sh           # Prometheus khong o localhost / khong chay docker
```

- Retention policy co thoi han `0s` hien **VO HAN** mau do, kem ngay cua data cu nhat va dung luong dang chiem.
- Prometheus: `retention.time`, `retention.size`, thoi han thuc te, data cu nhat, dung luong blocks / WAL, so series, thu muc data tren host cua container docker.
- Tim cau hinh `retention` / `tsdb` trong file docker-compose o `SCAN_DIR` va muc `[retention]` trong `/etc/influxdb/influxdb.conf`.

## check-no-data.sh - tim database / bucket khong co data

```bash
sudo bash check-no-data.sh           # 30 ngay
sudo bash check-no-data.sh -d 60     # 60 ngay
sudo bash check-no-data.sh -m        # them chi tiet measurement khong co data (query nang hon)
```

- **Ghi lan cuoi** = thoi gian sua moi nhat cua file TSM / WAL cua tung database (nhanh, khong query). Neu khong doc duoc thu muc thi dung `SHOW SHARDS` (1.x, co dau `~`, chinh xac den 1 shard group) hoac query Flux (2.x).
- Ca database khong co data thi goi y `DROP DATABASE`; chi mot retention policy thi goi y `DROP RETENTION POLICY` (canh bao neu la policy mac dinh). InfluxDB 2.x goi y `influx bucket delete --id`.
- `-m` query data N ngay gan nhat cua moi retention policy con song, database lon se cham.

## find-influx-cred.sh - quen token / mat khau cu

```bash
sudo bash find-influx-cred.sh          # liet ke token / user tim thay (an bot ky tu)
sudo bash find-influx-cred.sh --show   # hien day du token / password
```

Tim o: `~/.influxdbv2/configs` va `/etc/influxdb2/influx-configs` (influx CLI), `[[outputs.influxdb]]` / `[[outputs.influxdb_v2]]` trong config telegraf (resolve `${VAR}` tu `/etc/default/telegraf`), datasource Grafana provisioning loai `influxdb`, bien `INFLUX*` trong `.env` / docker-compose o `SCAN_DIR` va `/opt`, bien moi truong va config influx CLI cua container docker. Bo qua user / password cua plugin telegraf khac (vSphere, SNMP...).

Moi cai tim duoc deu thu voi `INFLUX_URL`: 1.x uu tien user admin (can cho `SHOW SHARDS`), 2.x uu tien token thay nhieu bucket nhat. InfluxDB 2.x neu khong co token nao dung duoc thi doc **ban sao** cua `influxd.bolt` bang `influxd recovery auth list` (khong dung toi file dang chay).

## Bien moi truong

| Bien | Mac dinh | Script |
| --- | --- | --- |
| `INFLUX_URL` | `http://localhost:8086` | tat ca |
| `INFLUX_DIR` | `/var/lib/influxdb` | tat ca |
| `INFLUX_USER` / `INFLUX_PASS` | tu tim | tat ca (auth InfluxDB 1.x) |
| `INFLUX_TOKEN` | tu tim | tat ca (InfluxDB 2.x) |
| `PROM_URLS` | tu tim container docker, neu khong co thi `http://localhost:9090` | check-retention.sh, check-size.sh |
| `SCAN_DIR` | `/opt/monitor-grafana-vcenter-total-cluster-prometheus` | check-retention.sh, find-influx-cred.sh |
| `INSPECT_TIMEOUT` | `1200` | check-size.sh |

</details>
