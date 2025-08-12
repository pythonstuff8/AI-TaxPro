#!/bin/bash
# pi_send_qr_http.sh
# Usage: sudo ./pi_send_qr_http.sh
# This script is pre-configured to upload to http://192.168.1.75:8000/upload with token s3cr3tTOKEN123

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Run with sudo."
  exit 1
fi

# ==== Config (already set to your Mac) ====
MAC_HOSTPORT="192.168.1.75:8000"
TOKEN="s3cr3tTOKEN123"
QR_FILE="/home/pi/hostname_qr.png"
HOSTNAME_PREFIX="dingdong"
# ========================================

# 1) Create unique hostname (dingdong-<last4 of serial> or random)
serial="$(awk '/Serial/ {print $3}' /proc/cpuinfo 2>/dev/null || echo '')"
if [ -z "$serial" ] || [ "${#serial}" -lt 4 ]; then
  suffix="$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c4)"
else
  suffix="${serial: -4}"
fi
NEW_HOSTNAME="${HOSTNAME_PREFIX}-${suffix}"
echo "Setting hostname to ${NEW_HOSTNAME}"
echo "${NEW_HOSTNAME}" >/etc/hostname
hostnamectl set-hostname "${NEW_HOSTNAME}"

# ensure /etc/hosts maps 127.0.1.1 to hostname + .local
if grep -q "127.0.1.1" /etc/hosts; then
  sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t${NEW_HOSTNAME}.local ${NEW_HOSTNAME}/" /etc/hosts
else
  echo -e "127.0.1.1\t${NEW_HOSTNAME}.local ${NEW_HOSTNAME}" >> /etc/hosts
fi

# 2) Ensure qrencode installed
if ! command -v qrencode >/dev/null 2>&1; then
  apt-get update
  apt-get install -y qrencode
fi

# 3) Generate QR
QR_TEXT="${NEW_HOSTNAME}.local"
qrencode -o "$QR_FILE" "$QR_TEXT"
chown pi:pi "$QR_FILE"
echo "QR generated at $QR_FILE (contains: $QR_TEXT)"

# 4) Try printing if printer present
DEFAULT_PRINTER="$(lpstat -d 2>/dev/null | sed -n 's/^system default destination: //p' || true)"
if [ -z "$DEFAULT_PRINTER" ]; then
  DEFAULT_PRINTER="$(lpstat -p 2>/dev/null | awk '/printer/ {print $2; exit}' || true)"
fi
if [ -n "$DEFAULT_PRINTER" ]; then
  echo "Printing QR to $DEFAULT_PRINTER..."
  lp -d "$DEFAULT_PRINTER" "$QR_FILE" || echo "lp returned non-zero"
else
  echo "No default printer detected; skipping printing."
fi

# 5) Upload via HTTP to Mac Flask receiver
UPLOAD_URL="http://${MAC_HOSTPORT}/upload"
echo "Uploading $QR_FILE to $UPLOAD_URL with token"
HTTP_STATUS=$(curl -s -w "%{http_code}" -o /tmp/upload_resp.txt -F "file=@${QR_FILE}" -H "X-AUTH-TOKEN: ${TOKEN}" "${UPLOAD_URL}" || true)
RESP_BODY=$(cat /tmp/upload_resp.txt 2>/dev/null || echo "")
if [ "$HTTP_STATUS" = "200" ]; then
  echo "Upload succeeded. Server response:"
  echo "$RESP_BODY"
else
  echo "Upload failed. HTTP status: $HTTP_STATUS"
  echo "Server body: $RESP_BODY"
  echo "Make sure the Mac server is running at http://${MAC_HOSTPORT}, firewall allows the port, and both devices are on same network."
fi

echo "Done. Hostname: ${NEW_HOSTNAME}.local  QR: ${QR_FILE}"
