#!/usr/bin/env bash
# check-all.sh - Chay tat ca: thoi han luu, database khong co data, dung luong cao -> thap.
# Luu bao cao ra file (khong mau) de gui / so sanh. Chi DOC, khong xoa / sua gi.
#
# Cach dung:
#   sudo bash check-all.sh                     # bao cao luu o ./report-<host>-<ngay gio>.txt
#   sudo bash check-all.sh -d 60               # moc "khong co data" 60 ngay (mac dinh 30)
#   sudo bash check-all.sh -q                  # nhanh: bo qua dung luong tung measurement
#   sudo bash check-all.sh -o /tmp/report.txt  # chon file bao cao

DAYS=30
QUICK=
OUT=
while getopts "d:qo:h" o; do
  case "$o" in
    d) DAYS="$OPTARG" ;;
    q) QUICK=-q ;;
    o) OUT="$OPTARG" ;;
    *) sed -n '2,10p' "$0"; exit 0 ;;
  esac
done
HERE=$(cd "$(dirname "$0")" && pwd)
OUT="${OUT:-$PWD/report-$(hostname)-$(date +%Y%m%d-%H%M).txt}"

# Tim token / user 1 lan, 3 script con dung lai
if [ -z "${INFLUX_USER:-}${INFLUX_TOKEN:-}${INFLUX_CRED_DONE:-}" ]; then
  eval "$(bash "$HERE/find-influx-cred.sh" --env)"
fi
export INFLUX_USER INFLUX_PASS INFLUX_TOKEN
export INFLUX_CRED_DONE=1   # script con khong tim lai

run() {
  echo
  echo "################################################################ $*"
  bash "$HERE/$@"
}

{
  echo "BAO CAO INFLUXDB / PROMETHEUS - $(hostname) - $(date '+%Y-%m-%d %H:%M')"
  run check-size.sh $QUICK
  run check-retention.sh
  run check-no-data.sh -d "$DAYS"
} 2>&1 | tee "$OUT"

echo
echo "Bao cao da luu: $OUT"
