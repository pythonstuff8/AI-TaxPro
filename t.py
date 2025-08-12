from flask import Flask, request
import subprocess

app = Flask(__name__)

@app.route('/connect_wifi', methods=['POST'])
def wifi():
    ssid = request.form.get('ssid')
    psk = request.form.get('psk')
    if not ssid:
        return "Missing SSID", 400

    # Delete existing connection with this SSID, if any
    subprocess.run(["nmcli", "connection", "delete", ssid], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    # Build nmcli command depending on whether PSK is given (open or WPA2)
    if psk:
        # WPA2 protected network
        cmd = ["nmcli", "device", "wifi", "connect", ssid, "password", psk]
    else:
        # Open network
        cmd = ["nmcli", "device", "wifi", "connect", ssid]

    # Run the connection command
    result = subprocess.run(cmd, capture_output=True, text=True)

    if result.returncode != 0:
        return f"Failed to connect: {result.stderr}", 500

    # Optional: disable hotspot services after connecting
    subprocess.run(["systemctl", "stop", "hostapd", "dnsmasq"])

    return "OK", 200

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000)
