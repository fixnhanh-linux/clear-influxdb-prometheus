#!/usr/bin/env bash
# menu.sh - Menu tuong tac InfluxDB: bang bucket / database theo dung luong, xem chi tiet,
# dat thoi han luu, xoa bucket khong co data, chay cac bao cao. Sua / xoa deu hoi xac nhan.
#
# Cach dung:
#   sudo bash menu.sh
#   sudo INFLUX_TOKEN=xxx bash menu.sh      # tu truyen token (mac dinh tu tim)

export INFLUX_URL="${INFLUX_URL:-http://localhost:8086}"
export INFLUX_DIR="${INFLUX_DIR:-/var/lib/influxdb}"
HERE=$(cd "$(dirname "$0")" && pwd)

command -v python3 >/dev/null || { echo "Can python3 de chay script nay"; exit 1; }
if [ -z "${INFLUX_USER:-}${INFLUX_TOKEN:-}${INFLUX_CRED_DONE:-}" ]; then
  echo "Dang tim token / user InfluxDB ..."
  eval "$(bash "$HERE/find-influx-cred.sh" --env)"
fi
export INFLUX_USER INFLUX_PASS INFLUX_TOKEN
export INFLUX_CRED_DONE=1

exec python3 "$HERE/lib/influx_menu.py"
