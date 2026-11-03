# clear-influxdb-prometheus

Read-only scripts that show how long InfluxDB and Prometheus keep data, and which InfluxDB databases / buckets have stopped receiving data — so you know what to clean before the disk fills up.

| Script | What it reports |
| --- | --- |
| [`check-retention.sh`](check-retention.sh) | Retention of every InfluxDB database / retention policy (1.x) or bucket (2.x), oldest data, size on disk; Prometheus retention time / size, oldest sample, TSDB size |
| [`check-no-data.sh`](check-no-data.sh) | InfluxDB databases / retention policies / buckets with no new data in the last N days (default 30), optionally down to measurement level |

Both scripts only read. Any `DROP` / `ALTER` / `delete` command they print is a suggestion and is never executed.

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
sudo bash check-retention.sh
sudo bash check-no-data.sh
```

## check-retention.sh

```bash
sudo bash check-retention.sh
INFLUX_USER=admin INFLUX_PASS=xxx sudo -E bash check-retention.sh    # InfluxDB 1.x with auth
INFLUX_TOKEN=xxx sudo -E bash check-retention.sh                      # InfluxDB 2.x
PROM_URLS=http://10.0.0.5:9090 sudo -E bash check-retention.sh        # Prometheus not on localhost / not in docker
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

## Environment variables

| Variable | Default | Used by |
| --- | --- | --- |
| `INFLUX_URL` | `http://localhost:8086` | both |
| `INFLUX_DIR` | `/var/lib/influxdb` | both |
| `INFLUX_USER` / `INFLUX_PASS` | – | both (InfluxDB 1.x auth) |
| `INFLUX_TOKEN` | – | both (InfluxDB 2.x) |
| `PROM_URLS` | auto-detected docker containers, else `http://localhost:9090` | check-retention.sh |
| `SCAN_DIR` | `/opt/monitor-grafana-vcenter-total-cluster-prometheus` | check-retention.sh |

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
sudo bash check-retention.sh
sudo bash check-no-data.sh
```

## check-retention.sh - bao cao thoi han luu

```bash
sudo bash check-retention.sh
INFLUX_USER=admin INFLUX_PASS=xxx sudo -E bash check-retention.sh    # InfluxDB 1.x co auth
INFLUX_TOKEN=xxx sudo -E bash check-retention.sh                      # InfluxDB 2.x
PROM_URLS=http://10.0.0.5:9090 sudo -E bash check-retention.sh        # Prometheus khong o localhost / khong chay docker
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

## Bien moi truong

| Bien | Mac dinh | Script |
| --- | --- | --- |
| `INFLUX_URL` | `http://localhost:8086` | ca hai |
| `INFLUX_DIR` | `/var/lib/influxdb` | ca hai |
| `INFLUX_USER` / `INFLUX_PASS` | – | ca hai (auth InfluxDB 1.x) |
| `INFLUX_TOKEN` | – | ca hai (InfluxDB 2.x) |
| `PROM_URLS` | tu tim container docker, neu khong co thi `http://localhost:9090` | check-retention.sh |
| `SCAN_DIR` | `/opt/monitor-grafana-vcenter-total-cluster-prometheus` | check-retention.sh |

</details>
