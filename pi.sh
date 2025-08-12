#!/bin/bash
set -euo pipefail

# Config - Change your Mac IP and token here ONLY
MAC_HOSTPORT="192.168.1.75:8000"    # Your Mac IP:port for QR upload
MAC_TOKEN="s3cr3tTOKEN123"
HOSTNAME_PREFIX="dingdong"
QR_FILE="/home/pi/hostname_qr.png"
PROV_DIR="/opt/wifi-provision"
UPLOAD_SCRIPT="/usr/local/bin/upload_qr.sh"
UPLOAD_SERVICE="/etc/systemd/system/upload_qr.service"
PROV_APP="${PROV_DIR}/provision.py"
PROV_SERVICE="/etc/systemd/system/wifi_provision.service"
CAM_APP="${PROV_DIR}/camera_stream.py"
CAM_SERVICE="/etc/systemd/system/camera_stream.service"
NM_LAUNCHER="/usr/local/bin/nm_hotspot_launcher.sh"
NM_LAUNCHER_SERVICE="/etc/systemd/system/nm_hotspot_launcher.service"

if [ "$(id -u)" -ne 0 ]; then
  echo "Please run with sudo"
  exit 1
fi

echo "=== Installing dependencies ==="
apt-get update
apt-get install -y network-manager python3 python3-pip qrencode cups
pip3 install flask opencv-python-headless || true

echo "=== Disabling dhcpcd to avoid conflicts ==="
if systemctl is-enabled --quiet dhcpcd 2>/dev/null; then
  systemctl disable --now dhcpcd || true
fi
systemctl enable --now NetworkManager

mkdir -p "${PROV_DIR}"
chmod 755 "${PROV_DIR}"

echo "=== Hostname & QR code generation (only once) ==="
CURRENT_HOSTNAME="$(hostname)"
if [[ "$CURRENT_HOSTNAME" == ${HOSTNAME_PREFIX}-* ]]; then
  echo "Hostname already set to $CURRENT_HOSTNAME, skipping change and QR generation"
  NEW_HOSTNAME="$CURRENT_HOSTNAME"
else
  echo "Generating new unique hostname"
  serial="$(awk '/Serial/ {print $3}' /proc/cpuinfo 2>/dev/null || echo '')"
  if [ -z "$serial" ] || [ "${#serial}" -lt 4 ]; then
    suffix="$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c4)"
  else
    suffix="${serial: -4}"
  fi
  NEW_HOSTNAME="${HOSTNAME_PREFIX}-${suffix}"
  echo "$NEW_HOSTNAME" >/etc/hostname
  hostnamectl set-hostname "$NEW_HOSTNAME"

  if grep -q "127.0.1.1" /etc/hosts; then
    sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t${NEW_HOSTNAME}.local ${NEW_HOSTNAME}/" /etc/hosts
  else
    echo -e "127.0.1.1\t${NEW_HOSTNAME}.local ${NEW_HOSTNAME}" >> /etc/hosts
  fi

  # Generate QR code for hostname.local
  qrencode -o "${QR_FILE}" "${NEW_HOSTNAME}.local"
  chown pi:pi "${QR_FILE}"

  # Try printing QR if printer found
  DEFAULT_PRINTER="$(lpstat -d 2>/dev/null | sed -n 's/^system default destination: //p' || true)"
  if [ -z "$DEFAULT_PRINTER" ]; then
    DEFAULT_PRINTER="$(lpstat -p 2>/dev/null | awk '/printer/ {print $2; exit}' || true)"
  fi
  if [ -n "$DEFAULT_PRINTER" ]; then
    echo "Printing QR code on printer $DEFAULT_PRINTER"
    lp -d "${DEFAULT_PRINTER}" "${QR_FILE}" || echo "Failed to print QR"
  else
    echo "No printer found, skipping printing."
  fi
fi

echo "=== Upload script to send QR to Mac ==="
cat > "${UPLOAD_SCRIPT}" <<EOF
#!/bin/bash
MAC_URL="${MAC_HOSTPORT}"
TOKEN="${MAC_TOKEN}"
QR_PATH="${QR_FILE}"

if [ ! -f "\$QR_PATH" ]; then
  echo "QR file missing: \$QR_PATH"
  exit 1
fi

# Ping Mac to check reachability
ping -c1 -W1 \$(echo \$MAC_URL | cut -d: -f1) >/dev/null 2>&1 || { echo "Mac not reachable"; exit 2; }

curl -s -F "file=@\$QR_PATH" -H "X-AUTH-TOKEN: \$TOKEN" "http://\$MAC_URL/upload"
EOF
chmod +x "${UPLOAD_SCRIPT}"

cat > "${UPLOAD_SERVICE}" <<EOF
[Unit]
Description=Upload QR to Mac
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${UPLOAD_SCRIPT}
User=root

[Install]
WantedBy=network-online.target
EOF

systemctl daemon-reload
systemctl enable upload_qr.service

echo "=== Flask Wi-Fi Provisioning App ==="
cat > "${PROV_APP}" <<'PYTHON'
#!/usr/bin/env python3
from flask import Flask, request, jsonify
import subprocess, time

app = Flask(__name__)

def run_cmd(cmd):
    p = subprocess.run(cmd, capture_output=True, text=True)
    return p.returncode, p.stdout.strip(), p.stderr.strip()

@app.route('/wifi', methods=['POST'])
def wifi():
    ssid = request.form.get('ssid') or (request.json and request.json.get('ssid'))
    psk = request.form.get('psk') or (request.json and request.json.get('psk'))
    if not ssid:
        return "Missing SSID", 400

    subprocess.run(["sudo", "nmcli", "connection", "delete", ssid], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    if psk:
        cmd = ["sudo", "nmcli", "device", "wifi", "connect", ssid, "password", psk]
    else:
        cmd = ["sudo", "nmcli", "device", "wifi", "connect", ssid]

    rc, out, err = run_cmd(cmd)
    if rc != 0:
        return f"Failed to connect: {err or out}", 500

    # Wait for IP address on wlan0 up to 15 seconds
    for _ in range(15):
        ips = subprocess.getoutput("ip -4 -o addr show dev wlan0 | awk '{print $4}'")
        if ips and not ips.startswith("192.168.4.") and not ips.startswith("169.254."):
            break
        time.sleep(1)

    ip_now = subprocess.getoutput("ip -4 -o addr show dev wlan0 | awk '{print $4}'")
    if ip_now:
        subprocess.run(["sudo", "systemctl", "start", "camera_stream.service"], check=False)
        return jsonify({"ok": True, "message": "Connected and camera started"}), 200
    else:
        subprocess.run(["sudo", "systemctl", "start", "nm_hotspot_launcher.service"], check=False)
        return jsonify({"ok": False, "error": "No IP after connect"}), 500

@app.route('/health')
def health():
    return "ok"

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000)
PYTHON

chmod +x "${PROV_APP}"

cat > "${PROV_SERVICE}" <<EOF
[Unit]
Description=Wi-Fi provisioning Flask service
After=network.target
Wants=network-online.target

[Service]
ExecStart=/usr/bin/python3 ${PROV_APP}
Restart=on-failure
User=root
WorkingDirectory=${PROV_DIR}

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable wifi_provision.service

echo "=== Camera streaming Flask app ==="
cat > "${CAM_APP}" <<'PYTHON'
#!/usr/bin/env python3
from flask import Flask, Response, render_template_string
import cv2, time

app = Flask(__name__)
cap = cv2.VideoCapture(0)

def gen_frames():
    while True:
        success, frame = cap.read()
        if not success:
            time.sleep(0.1)
            continue
        ret, buf = cv2.imencode('.jpg', frame)
        if not ret:
            continue
        frame_bytes = buf.tobytes()
        yield (b'--frame\r\n'
               b'Content-Type: image/jpeg\r\n\r\n' + frame_bytes + b'\r\n')

@app.route('/stream')
def stream():
    return Response(gen_frames(), mimetype='multipart/x-mixed-replace; boundary=frame')

@app.route('/')
def index():
    return render_template_string('<h3>Camera Stream</h3><img src="/stream" />')

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8000, threaded=True)
PYTHON

chmod +x "${CAM_APP}"

cat > "${CAM_SERVICE}" <<EOF
[Unit]
Description=Camera streaming service
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/bin/python3 ${CAM_APP}
Restart=on-failure
User=root
WorkingDirectory=${PROV_DIR}

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable camera_stream.service

echo "=== Hotspot launcher script ==="
cat > "${NM_LAUNCHER}" <<'BASH'
#!/bin/bash
HOTSPOT_SSID="Dingdong-Setup"
HOTSPOT_CONN="dingdong-hotspot"

ETH0_IP=$(ip -4 -o addr show dev eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 || true)
WLAN_IP=$(ip -4 -o addr show dev wlan0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 || true)

if [[ -n "$WLAN_IP" ]]; then
  echo "Wi-Fi connected ($WLAN_IP) - starting camera"
  systemctl start camera_stream.service
  exit 0
fi

if [[ -n "$ETH0_IP" ]]; then
  echo "eth0 connected ($ETH0_IP), Wi-Fi NOT connected"
  echo "Starting Wi-Fi provisioning Flask service"
  systemctl start wifi_provision.service
  exit 0
fi

echo "No eth0 or Wi-Fi connected - starting hotspot and provisioning service"

nmcli connection delete "$HOTSPOT_CONN" >/dev/null 2>&1 || true

nmcli connection add type wifi ifname wlan0 con-name "$HOTSPOT_CONN" autoconnect no ssid "$HOTSPOT_SSID"
nmcli connection modify "$HOTSPOT_CONN" 802-11-wireless.mode ap 802-11-wireless.band bg ipv4.method shared
nmcli connection modify "$HOTSPOT_CONN" 802-11-wireless-security.key-mgmt none

nmcli connection up "$HOTSPOT_CONN" || true

systemctl start wifi_provision.service
BASH

chmod +x "${NM_LAUNCHER}"

cat > "${NM_LAUNCHER_SERVICE}" <<EOF
[Unit]
Description=Start hotspot or provisioning based on eth0/wifi state
After=NetworkManager.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${NM_LAUNCHER}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable nm_hotspot_launcher.service
systemctl start nm_hotspot_launcher.service

echo "=== Setup complete ==="
echo "Hostname set to: $NEW_HOSTNAME.local"
echo "QR code generated at: $QR_FILE"
echo "If eth0 connected and Wi-Fi NOT connected: provisioning server runs on port 5000"
echo "If Wi-Fi connected: camera streaming runs on port 8000"
echo "If neither eth0 nor Wi-Fi connected: hotspot + provisioning server start"
