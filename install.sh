#!/bin/bash

# Exit immediately on error
set -e

GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${CYAN}=== MinimalPanel (Bare-Metal Shared Stack & Agent Installer) ===${NC}"

# 1. Prompt for Control Panel Domain Name (Explicitly read from /dev/tty for pipe compatibility)
read -p "Enter MinimalPanel domain name (e.g., hosting.stevencrocker.com): " PANEL_DOMAIN </dev/tty
if [ -z "$PANEL_DOMAIN" ]; then
    echo -e "${RED}Error: Domain name cannot be empty.${NC}"
    exit 1
fi

# 2. Detect Operating System
DISTRO_ID=$(. /etc/os-release && echo "$ID")
VERSION_CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME")

echo -e "${CYAN}Detected OS:${NC} ${DISTRO_ID} (${VERSION_CODENAME})"

if [[ "$DISTRO_ID" != "debian" && "$DISTRO_ID" != "ubuntu" ]]; then
    echo -e "${RED}Error: MinimalPanel only supports Debian or Ubuntu systems.${NC}"
    exit 1
fi

# 3. System Upgrades, Dependencies & Scheduled Security Updates
echo -e "${CYAN}[1/11] Performing System Upgrade & Installing Dependencies...${NC}"
export DEBIAN_FRONTEND=noninteractive
sudo apt update -y && sudo apt upgrade -y
sudo apt install -y python3 python3-pip python3-venv mariadb-server mariadb-client curl openssl unattended-upgrades cron ca-certificates gpg certbot dnsutils git jq inotify-tools

cat << PERIODIC_EOF | sudo tee /etc/apt/apt.conf.d/20auto-upgrades > /dev/null
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
PERIODIC_EOF

# 4. Configure MariaDB Systemd Auto-Restart on OOM/Crash
echo -e "${CYAN}[2/11] Hardening MariaDB Recovery Settings...${NC}"
sudo mkdir -p /etc/systemd/system/mariadb.service.d/
cat << MARIADB_OVERRIDE_EOF | sudo tee /etc/systemd/system/mariadb.service.d/override.conf > /dev/null
[Service]
Restart=always
RestartSec=3s
MARIADB_OVERRIDE_EOF
sudo systemctl daemon-reload
sudo systemctl restart mariadb

# 5. OpenLiteSpeed & PHP Runtimes (7.4 through 8.5)
echo -e "${CYAN}[3/11] Installing OpenLiteSpeed & PHP Runtimes...${NC}"
wget -O - https://repo.litespeed.sh | sudo bash
sudo apt update -y
sudo apt install -y openlitespeed \
  lsphp82 lsphp82-mysql lsphp82-common \
  lsphp83 lsphp83-mysql lsphp83-common \
  lsphp84 lsphp84-mysql lsphp84-common \
  lsphp85 lsphp85-mysql lsphp85-common || true
sudo apt install -y lsphp74 lsphp74-mysql lsphp74-common || echo "Notice: PHP 7.4 skipped (unavailable on this OS)."

# 6. Docker Engine (For Custom Docker Compose Sites)
if ! command -v docker &> /dev/null; then
    echo -e "${CYAN}[4/11] Installing Docker Engine...${NC}"
    sudo install -m 0755 -d /etc/apt/keyrings
    DOCKER_CODENAME="$VERSION_CODENAME"
    if [ "$DOCKER_CODENAME" = "trixie" ]; then DOCKER_CODENAME="bookworm"; fi

    curl -fsSL "https://download.docker.com/linux/${DISTRO_ID}/gpg" | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg --yes
    sudo chmod a+r /etc/apt/keyrings/docker.gpg

    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${DISTRO_ID} \
      ${DOCKER_CODENAME} stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    sudo apt update -y
    sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    sudo systemctl enable --now docker
fi

# 7. Pre-flight Cleanup & MariaDB Root Initialization (Fully Idempotent)
echo -e "${CYAN}[5/11] Cleaning Orphaned Processes & Resetting Database State...${NC}"
sudo groupadd -f sftp-users

# Stop and wipe out old agent/watcher instances to prevent port or process locks
sudo systemctl stop minimalpanel minimalpanel-htaccess 2>/dev/null || true
sudo rm -rf /opt/minimalpanel

# Clean up any orphaned OpenLiteSpeed processes locking ports 80/443/7080
sudo /usr/local/lsws/bin/lswsctrl stop 2>/dev/null || true
sudo killall -9 litespeed lshttpd 2>/dev/null || true

MYSQL_ROOT_PASS=$(openssl rand -hex 16)
# Reset root password safely regardless of existing auth state
sudo mariadb -e "ALTER USER 'root'@'localhost' IDENTIFIED VIA mysql_native_password USING PASSWORD('${MYSQL_ROOT_PASS}'); FLUSH PRIVILEGES;" 2>/dev/null || \
sudo mariadb -e "SET PASSWORD FOR 'root'@'localhost' = PASSWORD('${MYSQL_ROOT_PASS}'); FLUSH PRIVILEGES;" 2>/dev/null || true

sudo mkdir -p /opt/minimalpanel
sudo mkdir -p /var/www/vhosts

if ! grep -q "Match Group sftp-users" /etc/ssh/sshd_config; then
cat << SSHD_EOF | sudo tee -a /etc/ssh/sshd_config > /dev/null

# MinimalPanel SFTP Chroot Enforcement
Match Group sftp-users
    ChrootDirectory /var/www/vhosts/%u
    ForceCommand internal-sftp
    AllowTcpForwarding no
    X11Forwarding no
SSHD_EOF
sudo systemctl restart ssh
fi

# 8. Write Python Agent & MinimalPanel Dashboard
echo -e "${CYAN}[6/11] Setting Up MinimalPanel Agent (/opt/minimalpanel)...${NC}"
cd /opt/minimalpanel
python3 -m venv venv
./venv/bin/pip install --upgrade pip
./venv/bin/pip install "fastapi[standard]" "uvicorn[standard]" pydantic pyotp qrcode

cat << 'PYTHON_EOF' > /opt/minimalpanel/main.py
from fastapi import FastAPI, HTTPException, Depends, Header
from fastapi.responses import HTMLResponse, JSONResponse
from pydantic import BaseModel
import subprocess
import secrets
import string
import os
import json
import pyotp
import qrcode
import io
import base64

app = FastAPI(title="MinimalPanel")

CONFIG_FILE = "/opt/minimalpanel/config.json"
MYSQL_ROOT_PASS = "${MYSQL_ROOT_PASS}"

def load_config():
    if os.path.exists(CONFIG_FILE):
        with open(CONFIG_FILE, "r") as f:
            return json.load(f)
    return {}

def save_config(data):
    with open(CONFIG_FILE, "w") as f:
        json.dump(data, f, indent=2)

def generate_pass(length=32):
    alphabet = string.ascii_letters + string.digits
    return ''.join(secrets.choice(alphabet) for _ in range(length))

class InitPayload(BaseModel):
    username: str

class Verify2FAPayload(BaseModel):
    code: str

class LoginPayload(BaseModel):
    username: str
    password: str
    totp_code: str

class CreateSitePayload(BaseModel):
    token: str
    client_id: str
    website_id: str
    domain: str
    site_type: str  # 'php', 'wordpress', 'docker'
    php_version: str = "lsphp85"
    docker_compose_content: str = None

class ComposePayload(BaseModel):
    token: str
    client_id: str
    website_id: str
    yaml_content: str = None

@app.get("/", response_class=HTMLResponse)
def serve_dashboard():
    return HTML_UI

@app.get("/api/status")
def get_status():
    cfg = load_config()
    if not cfg:
        return {"step": "INITIAL_SETUP"}
    if not cfg.get("2fa_enabled"):
        return {"step": "SETUP_2FA", "username": cfg.get("username"), "qr": cfg.get("qr_code")}
    return {"step": "LOGIN_REQUIRED"}

@app.post("/api/init-admin")
def init_admin(payload: InitPayload):
    cfg = load_config()
    if cfg:
        raise HTTPException(status_code=400, detail="Already initialized")

    init_password = generate_pass(16)
    totp_secret = pyotp.random_base32()
    totp = pyotp.TOTP(totp_secret)
    provisioning_uri = totp.provisioning_uri(name=payload.username, issuer_name="MinimalPanel")

    img = qrcode.make(provisioning_uri)
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    qr_b64 = "data:image/png;base64," + base64.b64encode(buf.getvalue()).decode()

    session_token = generate_pass(32)

    data = {
        "username": payload.username,
        "password": init_password,
        "totp_secret": totp_secret,
        "2fa_enabled": False,
        "session_token": session_token,
        "qr_code": qr_b64
    }
    save_config(data)

    return {
        "username": payload.username,
        "initial_password": init_password,
        "qr_code": qr_b64
    }

@app.post("/api/verify-2fa")
def verify_2fa(payload: Verify2FAPayload):
    cfg = load_config()
    totp = pyotp.TOTP(cfg["totp_secret"])
    if totp.verify(payload.code):
        cfg["2fa_enabled"] = True
        save_config(cfg)
        return {"status": "success", "session_token": cfg["session_token"]}
    raise HTTPException(status_code=400, detail="Invalid 2FA code")

@app.post("/api/login")
def login(payload: LoginPayload):
    cfg = load_config()
    if payload.username == cfg["username"] and payload.password == cfg["password"]:
        totp = pyotp.TOTP(cfg["totp_secret"])
        if totp.verify(payload.totp_code):
            return {"status": "success", "session_token": cfg["session_token"]}
        raise HTTPException(status_code=401, detail="Invalid 2FA code")
    raise HTTPException(status_code=401, detail="Invalid credentials")

@app.post("/api/create-site")
def create_site(payload: CreateSitePayload):
    cfg = load_config()
    if payload.token != cfg.get("session_token"):
        raise HTTPException(status_code=401, detail="Unauthorized")

    site_path_user = f"{payload.client_id}_{payload.website_id}"
    base_path = f"/var/www/vhosts/{site_path_user}"
    www_path = f"{base_path}/www"
    logs_path = f"{base_path}/logs"

    db_user = payload.website_id[:16]
    db_pass = generate_pass(32)
    db_name = payload.website_id[:16]
    sftp_user = site_path_user
    sftp_pass = generate_pass(32)

    try:
        subprocess.run(["useradd", "-g", "sftp-users", "-d", f"/{site_path_user}", "-s", "/usr/sbin/nologin", sftp_user], check=False)
        subprocess.run(["sh", "-c", f"echo '{sftp_user}:{sftp_pass}' | chpasswd"], check=True)

        os.makedirs(base_path, exist_ok=True)
        subprocess.run(["chown", "root:root", base_path], check=True)
        subprocess.run(["chmod", "755", base_path], check=True)

        os.makedirs(www_path, exist_ok=True)
        os.makedirs(logs_path, exist_ok=True)
        subprocess.run(["chown", "-R", f"{sftp_user}:sftp-users", www_path], check=True)
        subprocess.run(["chown", "-R", f"{sftp_user}:sftp-users", logs_path], check=True)
        subprocess.run(["chmod", "750", www_path], check=True)

        db_sql = f"CREATE DATABASE IF NOT EXISTS \`{db_name}\`; CREATE USER IF NOT EXISTS '{db_user}'@'localhost' IDENTIFIED BY '{db_pass}'; GRANT ALL PRIVILEGES ON \`{db_name}\`.* TO '{db_user}'@'localhost'; FLUSH PRIVILEGES;"
        subprocess.run(["mariadb", "-u", "root", f"-p{MYSQL_ROOT_PASS}", "-e", db_sql], check=True)

        if payload.site_type == "docker" and payload.docker_compose_content:
            compose_file = f"{base_path}/docker-compose.yml"
            with open(compose_file, "w") as f:
                f.write(payload.docker_compose_content)
            subprocess.run(["docker", "compose", "-f", compose_file, "up", "-d"], check=True)

        return {
            "status": "success",
            "paths": {"base": base_path, "www": www_path, "logs": logs_path},
            "sftp": {"user": sftp_user, "pass": sftp_pass},
            "db": {"name": db_name, "user": db_user, "pass": db_pass}
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/api/docker/get-config")
def get_docker_config(payload: ComposePayload):
    cfg = load_config()
    if payload.token != cfg.get("session_token"):
        raise HTTPException(status_code=401, detail="Unauthorized")

    compose_file = f"/var/www/vhosts/{payload.client_id}_{payload.website_id}/docker-compose.yml"
    if not os.path.exists(compose_file):
        return {"yaml": ""}
    
    with open(compose_file, "r") as f:
        return {"yaml": f.read()}

@app.post("/api/docker/redeploy")
def redeploy_docker(payload: ComposePayload):
    cfg = load_config()
    if payload.token != cfg.get("session_token"):
        raise HTTPException(status_code=401, detail="Unauthorized")

    base_path = f"/var/www/vhosts/{payload.client_id}_{payload.website_id}"
    compose_file = f"{base_path}/docker-compose.yml"

    try:
        if payload.yaml_content:
            with open(compose_file, "w") as f:
                f.write(payload.yaml_content)

        res = subprocess.run(["docker", "compose", "-f", compose_file, "up", "-d", "--force-recreate"], capture_output=True, text=True, check=True)
        return {"status": "success", "message": "Containers updated and redeployed successfully!", "output": res.stdout}
    except subprocess.CalledProcessError as e:
        raise HTTPException(status_code=500, detail=f"Docker Error: {e.stderr}")
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

HTML_UI = """
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>MinimalPanel</title>
  <style>
    * { box-sizing: border-box; margin: 0; padding: 0; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; }
    body { display: flex; height: 100vh; background: #222d32; color: #fff; overflow: hidden; }
    .col-clients { width: 220px; background: #1a2226; display: flex; flex-direction: column; border-right: 1px solid #2c3b41; }
    .col-websites { width: 260px; background: #222d32; display: flex; flex-direction: column; border-right: 1px solid #2c3b41; }
    .col-config { flex: 1; background: #d2d6de; color: #333; padding: 30px; overflow-y: auto; }
    .col-header { padding: 15px; font-weight: bold; text-transform: uppercase; font-size: 13px; color: #b8c7ce; letter-spacing: 0.5px; }
    .list { flex: 1; overflow-y: auto; }
    .item { padding: 12px 15px; cursor: pointer; border-bottom: 1px solid #222d32; font-size: 14px; color: #8aa4af; }
    .item:hover, .item.active { background: #1e282c; color: #fff; border-left: 3px solid #3c8dbc; }
    .col-footer { padding: 15px; border-top: 1px solid #2c3b41; }
    .btn { display: inline-block; width: 100%; padding: 10px; border: none; border-radius: 3px; font-weight: bold; cursor: pointer; text-align: center; }
    .btn-primary { background: #3c8dbc; color: white; }
    .btn-warning { background: #f39c12; color: white; margin-bottom: 8px; }
    .btn-danger { background: #dd4b39; color: white; }
    .btn-redeploy { background: #00a65a; color: white; width: auto; padding: 10px 20px; margin-top: 10px; }
    .yaml-area { width: 100%; height: 250px; font-family: monospace; font-size: 13px; background: #1e1e1e; color: #00ff66; padding: 12px; border-radius: 4px; border: 1px solid #444; margin-top: 10px; white-space: pre; }
    .modal { display: none; position: fixed; top: 0; left: 0; width: 100vw; height: 100vh; background: rgba(0,0,0,0.85); align-items: center; justify-content: center; z-index: 100; }
    .modal-content { background: #fff; color: #333; padding: 25px; border-radius: 5px; width: 450px; text-align: center; }
    .modal-content input, .modal-content select, .modal-content textarea { width: 100%; padding: 8px; margin: 8px 0 15px; border: 1px solid #ccc; border-radius: 3px; }
  </style>
</head>
<body>

  <div class="col-clients">
    <div class="col-header">Clients</div>
    <div class="list" id="clientList"><div class="item active">Client 1</div></div>
    <div class="col-footer"><button class="btn btn-primary">ADD CLIENT BUTTON</button></div>
  </div>

  <div class="col-websites">
    <div class="col-header">Websites</div>
    <div class="list" id="websiteList"><div class="item active">Client's First Website</div></div>
    <div class="col-footer">
      <button class="btn btn-primary" style="margin-bottom:8px" onclick="openWebsiteModal()">ADD WEBSITE BUTTON</button>
      <button class="btn btn-warning">PAUSE/UNPAUSE CLIENT</button>
      <button class="btn btn-danger">DELETE CLIENT</button>
    </div>
  </div>

  <div class="col-config">
    <h2>CLIENT'S FIRST WEBSITE</h2>
    <div style="font-weight:bold; color:#555; margin-bottom:20px">TYPE: PHP, WORDPRESS, OR DOCKER CONTAINER</div>
    
    <div style="font-weight:bold; text-transform:uppercase; margin-bottom:8px">Production Configuration</div>
    <ul style="list-style:none; font-size:13px; line-height:1.8">
      <li>- DOMAIN NAME: <strong>example.com</strong></li>
      <li>- PATH: <strong>/var/www/vhosts/cli_1_web_1/www</strong></li>
      <li>- PHP VERSION: <strong>PHP 8.5 (lsphp85)</strong></li>
      <li>- DATABASE USER: <strong>web_1</strong></li>
      <li>- SFTP USER: <strong>cli_1_web_1</strong></li>
    </ul>

    <div id="dockerSection" style="display:none; margin-top:20px;">
      <label style="font-weight:bold">DOCKER COMPOSE CONFIGURATION (YAML):</label>
      <textarea id="yamlEditor" class="yaml-area"></textarea>
      <button class="btn btn-redeploy" onclick="saveAndRedeploy()">SAVE & REDEPLOY CONTAINERS</button>
    </div>

    <div style="margin-top: 40px;">
      <button class="btn btn-warning" style="width: auto; padding: 10px 20px;">PAUSE/UNPAUSE WEBSITE BUTTON</button>
      <button class="btn btn-danger" style="width: auto; padding: 10px 20px;">DELETE WEBSITE BUTTON (WITH CONFIRM)</button>
    </div>
  </div>

  <div class="modal" id="authModal" style="display:flex;">
    <div class="modal-content" id="authBox">
      <h3>Checking MinimalPanel Status...</h3>
    </div>
  </div>

  <div class="modal" id="siteModal">
    <div class="modal-content" style="text-align:left;">
      <h3>Add New Website</h3>
      <label>Site Type:</label>
      <select id="modalType" onchange="toggleSiteFields()">
        <option value="php">PHP</option>
        <option value="wordpress">WordPress</option>
        <option value="docker">Docker Container</option>
      </select>

      <label>PHP Version:</label>
      <select id="modalPhpVer">
        <option value="lsphp85">PHP 8.5</option>
        <option value="lsphp84">PHP 8.4</option>
        <option value="lsphp83">PHP 8.3</option>
        <option value="lsphp82">PHP 8.2</option>
        <option value="lsphp74">PHP 7.4</option>
      </select>

      <label>Domain Name:</label>
      <input type="text" id="modalDomain" placeholder="example.com">

      <div id="dockerFields" style="display:none;">
        <label>Docker Compose Yaml:</label>
        <textarea id="modalDockerCompose" rows="4" placeholder="version: '3.8'\\nservices:\\n  app:\\n    image: nginx:latest"></textarea>
      </div>

      <button class="btn btn-primary" onclick="submitNewSite()">Provision Website</button>
      <button class="btn" style="margin-top:5px; background:#aaa" onclick="closeModal()">Cancel</button>
    </div>
  </div>

  <script>
    let sessionToken = localStorage.getItem('sessionToken') || '';

    async function checkStatus() {
      const res = await fetch('/api/status');
      const data = await res.json();

      if (data.step === 'INITIAL_SETUP') {
        renderInitSetup();
      } else if (data.step === 'SETUP_2FA') {
        render2FASetup(data.qr);
      } else {
        if (!sessionToken) renderLogin();
        else document.getElementById('authModal').style.display = 'none';
      }
    }

    function renderInitSetup() {
      document.getElementById('authBox').innerHTML = `
        <h3>MinimalPanel Admin Setup</h3>
        <p style="font-size:13px; color:#666; margin-bottom:10px;">Choose your administrator username:</p>
        <input type="text" id="initUser" placeholder="Admin Username">
        <button class="btn btn-primary" onclick="submitInit()">Generate Password & 2FA</button>
      `;
    }

    async function submitInit() {
      const username = document.getElementById('initUser').value;
      const res = await fetch('/api/init-admin', {
        method: 'POST',
        headers: {'Content-Type': 'application/json'},
        body: JSON.stringify({ username })
      });
      const data = await res.json();
      render2FASetup(data.qr_code, data.initial_password);
    }

    function render2FASetup(qrCode, pass = '') {
      document.getElementById('authBox').innerHTML = `
        <h3>Setup 2-Factor Authentication</h3>
        ` + (pass ? `<p style="background:#eee; padding:10px; margin:10px 0; font-family:monospace; font-weight:bold;">Password: ` + pass + `</p><p style="color:red; font-size:12px;">Copy your password! It will not be shown again.</p>` : '') + `
        <img src="` + qrCode + `" style="width:180px; height:180px; margin:15px 0;">
        <p style="font-size:12px; margin-bottom:10px;">Scan with Google Authenticator or 1Password</p>
        <input type="text" id="totpCode" placeholder="Enter 6-digit 2FA Code">
        <button class="btn btn-primary" onclick="verify2FA()">Verify & Enable 2FA</button>
      `;
    }

    async function verify2FA() {
      const code = document.getElementById('totpCode').value;
      const res = await fetch('/api/verify-2fa', {
        method: 'POST',
        headers: {'Content-Type': 'application/json'},
        body: JSON.stringify({ code })
      });
      const data = await res.json();
      if (res.ok) {
        localStorage.setItem('sessionToken', data.session_token);
        sessionToken = data.session_token;
        document.getElementById('authModal').style.display = 'none';
      } else {
        alert(data.detail);
      }
    }

    function renderLogin() {
      document.getElementById('authBox').innerHTML = `
        <h3>MinimalPanel Login</h3>
        <input type="text" id="loginUser" placeholder="Username">
        <input type="password" id="loginPass" placeholder="Password">
        <input type="text" id="loginTotp" placeholder="6-digit 2FA Code">
        <button class="btn btn-primary" onclick="submitLogin()">Login</button>
      `;
    }

    async function submitLogin() {
      const res = await fetch('/api/login', {
        method: 'POST',
        headers: {'Content-Type': 'application/json'},
        body: JSON.stringify({
          username: document.getElementById('loginUser').value,
          password: document.getElementById('loginPass').value,
          totp_code: document.getElementById('loginTotp').value
        })
      });
      const data = await res.json();
      if (res.ok) {
        localStorage.setItem('sessionToken', data.session_token);
        sessionToken = data.session_token;
        document.getElementById('authModal').style.display = 'none';
      } else {
        alert(data.detail);
      }
    }

    function openWebsiteModal() { document.getElementById('siteModal').style.display = 'flex'; }
    function closeModal() { document.getElementById('siteModal').style.display = 'none'; }
    function toggleSiteFields() {
      const type = document.getElementById('modalType').value;
      document.getElementById('dockerFields').style.display = type === 'docker' ? 'block' : 'none';
    }

    async function submitNewSite() {
      const payload = {
        token: sessionToken,
        client_id: 'cli_1',
        site_type: document.getElementById('modalType').value,
        php_version: document.getElementById('modalPhpVer').value,
        domain: document.getElementById('modalDomain').value,
        website_id: 'web_' + Math.random().toString(36).substring(2, 8),
        docker_compose_content: document.getElementById('modalDockerCompose').value,
      };

      const res = await fetch('/api/create-site', {
        method: 'POST',
        headers: {'Content-Type': 'application/json'},
        body: JSON.stringify(payload)
      });

      const result = await res.json();
      if (res.ok) {
        alert('Site Provisioned Successfully!\\nSFTP User: ' + result.sftp.user + '\\nSFTP Pass: ' + result.sftp.pass + '\\nDB Pass: ' + result.db.pass);
        closeModal();
      } else {
        alert('Error: ' + result.detail);
      }
    }

    checkStatus();
  </script>
</body>
</html>
"""
PYTHON_EOF

# 9. Register MinimalPanel Systemd Service
echo -e "${CYAN}[7/11] Registering Systemd Agent Service...${NC}"
cat << SERVICE_EOF | sudo tee /etc/systemd/system/minimalpanel.service > /dev/null
[Unit]
Description=MinimalPanel Agent & Control Console
After=network.target mariadb.service docker.service

[Service]
User=root
WorkingDirectory=/opt/minimalpanel
ExecStart=/opt/minimalpanel/venv/bin/uvicorn main:app --host 127.0.0.1 --port 8080
Restart=always
RestartSec=3s
StartLimitIntervalSec=60s
StartLimitBurst=10
OOMScoreAdjust=-500

[Install]
WantedBy=multi-user.target
SERVICE_EOF

sudo systemctl daemon-reload
sudo systemctl enable --now minimalpanel.service

# 10. Configure OpenLiteSpeed Reverse Proxy Virtual Host
echo -e "${CYAN}[8/11] Configuring OpenLiteSpeed Reverse Proxy for ${PANEL_DOMAIN}...${NC}"

sudo mkdir -p /usr/local/lsws/conf/vhosts/${PANEL_DOMAIN}
cat << OLS_VHOST_EOF | sudo tee /usr/local/lsws/conf/vhosts/${PANEL_DOMAIN}/vhconf.conf > /dev/null
docRoot                   /opt/minimalpanel
enableGzip                1

extprocessor minimalpanel-agent {
  type                    proxy
  address                 127.0.0.1:8080
  maxConns                100
  initTimeout             60
  retryTimeout            0
  respBuffer              0
}

context / {
  type                    proxy
  handler                 minimalpanel-agent
  addDefaultCharset       off
}
OLS_VHOST_EOF

# Ensure OpenLiteSpeed starts up fresh and cleanly
sudo /usr/local/lsws/bin/lswsctrl restart || sudo /usr/local/lsws/bin/lswsctrl start

# 11. Configure Real-Time .htaccess File Watcher Daemon
echo -e "${CYAN}[9/11] Setting Up Real-Time .htaccess Watcher Service...${NC}"

cat << 'WATCHER_EOF' | sudo tee /opt/minimalpanel/htaccess-watcher.sh > /dev/null
#!/bin/bash

WATCH_DIR="/var/www/vhosts"
DEBOUNCE_SEC=2

mkdir -p "$WATCH_DIR"

echo "MinimalPanel .htaccess Watcher Active on $WATCH_DIR"

inotifywait -m -r -e modify,create,delete --format '%w%f' "$WATCH_DIR" 2>/dev/null | while read FILE; do
    if [[ "$FILE" == *".htaccess"* ]]; then
        echo "Detected change in $FILE. Queueing OpenLiteSpeed reload..."
        sleep $DEBOUNCE_SEC
        while read -t 1 DEBOUNCE_FILE; do :; done
        /usr/local/lsws/bin/lswsctrl reload
        echo "OpenLiteSpeed gracefully reloaded."
    fi
done
WATCHER_EOF

sudo chmod +x /opt/minimalpanel/htaccess-watcher.sh

cat << WATCHER_SERVICE_EOF | sudo tee /etc/systemd/system/minimalpanel-htaccess.service > /dev/null
[Unit]
Description=MinimalPanel .htaccess Real-Time Watcher
After=network.target lsws.service

[Service]
User=root
ExecStart=/opt/minimalpanel/htaccess-watcher.sh
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
WATCHER_SERVICE_EOF

sudo systemctl daemon-reload
sudo systemctl enable --now minimalpanel-htaccess.service

# 12. Generate Helper CLI Script (/usr/local/bin/minimalpanel & /usr/local/bin/mp)
echo -e "${CYAN}[10/11] Installing Helper CLI Utility (/usr/local/bin/minimalpanel)...${NC}"

sudo tee /usr/local/bin/minimalpanel > /dev/null << 'EOF'
#!/bin/bash

GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

PANEL_DOMAIN="HOST_DOMAIN_PLACEHOLDER"

case "$1" in
    ssl)
        echo -e "${CYAN}Ensuring OpenLiteSpeed is active and listening on port 80...${NC}"
        
        # Pre-flight check: Verify if port 80 is bound by OLS
        if ! ss -tulpn | grep -q ':80 '; then
            echo -e "${YELLOW}Port 80 is not active. Forcing OpenLiteSpeed recovery...${NC}"
            sudo killall -9 litespeed lshttpd 2>/dev/null || true
            sudo rm -rf /dev/shm/lsws/* 2>/dev/null || true
            sudo rm -f /usr/local/lsws/logs/lshttpd.pid
            sudo rm -f /usr/local/lsws/tmp/*.lock
            sudo /usr/local/lsws/bin/lswsctrl start || true
            sleep 2
        fi

        # Double-check port 80 state
        if ! ss -tulpn | grep -q ':80 '; then
            echo -e "${RED}Error: OpenLiteSpeed failed to bind to port 80. Cannot run AutoSSL challenge.${NC}"
            echo -e "${YELLOW}Check /usr/local/lsws/logs/error.log for startup issues.${NC}"
            exit 1
        fi

        echo -e "${CYAN}Verifying DNS resolution for ${PANEL_DOMAIN}...${NC}"
        SERVER_IP=$(curl -s https://api.ipify.org || curl -s https://ifconfig.me)
        DOMAIN_IP=$(dig +short A "${PANEL_DOMAIN}" | tail -n1)

        echo -e "Server Public IP: ${CYAN}${SERVER_IP}${NC}"
        echo -e "Domain Resolved IP: ${CYAN}${DOMAIN_IP:-Unresolved}${NC}"

        if [ "$SERVER_IP" = "$DOMAIN_IP" ]; then
            echo -e "${GREEN}DNS verified! Issuing Let's Encrypt SSL Certificate...${NC}"
            sudo certbot certonly --webroot -w /opt/minimalpanel -d ${PANEL_DOMAIN} --non-interactive --agree-tos -m admin@${PANEL_DOMAIN}
            sudo /usr/local/lsws/bin/lswsctrl restart
            echo -e "${GREEN}SSL Certificate successfully issued and web server reloaded!${NC}"
        else
            echo -e "${RED}Error: DNS record (${DOMAIN_IP:-Unresolved}) does not match Server IP (${SERVER_IP}).${NC}"
            echo -e "${YELLOW}Please update your DNS A record to point to ${SERVER_IP} and try again.${NC}"
        fi
        ;;

    restart)
        echo -e "${CYAN}Restarting Core Stack Services...${NC}"
        sudo systemctl restart mariadb
        sudo systemctl restart minimalpanel
        sudo systemctl restart minimalpanel-htaccess
        sudo /usr/local/lsws/bin/lswsctrl restart || sudo /usr/local/lsws/bin/lswsctrl start
        echo -e "${GREEN}All stack services restarted successfully.${NC}"
        ;;

    status)
        echo -e "${CYAN}=== MinimalPanel & Core Services Status ===${NC}"
        sudo systemctl status minimalpanel --no-pager
        sudo systemctl status minimalpanel-htaccess --no-pager
        sudo systemctl status mariadb --no-pager
        sudo systemctl status lsws --no-pager
        ;;

    check)
        SERVICES=("mariadb" "minimalpanel" "minimalpanel-htaccess")
        for SERVICE in "${SERVICES[@]}"; do
            if ! systemctl is-active --quiet "$SERVICE"; then
                echo -e "${RED}WARNING: ${SERVICE} is DOWN! Attempting automatic recovery...${NC}"
                sudo systemctl restart "$SERVICE"
            fi
        done
        if ! pgrep -x "litespeed" > /dev/null; then
            echo -e "${RED}WARNING: OpenLiteSpeed is DOWN! Attempting automatic recovery...${NC}"
            sudo /usr/local/lsws/bin/lswsctrl start || true
        fi

        OOM_LOGS=$(sudo dmesg -T | grep -i -E 'oom[-_]killer|out of memory' | tail -n 5 || true)
        if [ -n "$OOM_LOGS" ]; then
            echo -e "${RED}Recent OOM Events Detected:${NC}\n${OOM_LOGS}"
        fi
        ;;

    reset-2fa)
        echo -e "${YELLOW}Resetting 2FA state in /opt/minimalpanel/config.json...${NC}"
        if [ -f /opt/minimalpanel/config.json ]; then
            sudo jq '.2fa_enabled = false | del(.qr_code)' /opt/minimalpanel/config.json > /tmp/cfg.json
            sudo mv /tmp/cfg.json /opt/minimalpanel/config.json
            sudo systemctl restart minimalpanel
            echo -e "${GREEN}2FA successfully reset. Re-open your browser to scan a new QR code.${NC}"
        else
            echo -e "${RED}Config file not found.${NC}"
        fi
        ;;

    *)
        echo -e "${CYAN}MinimalPanel CLI Helper${NC}"
        echo -e "Usage: minimalpanel {check|ssl|restart|status|reset-2fa} (or use shorthand 'mp')"
        echo -e "  ${GREEN}minimalpanel check${NC}     - Inspect health, restart dead services & check OOM logs"
        echo -e "  ${GREEN}minimalpanel ssl${NC}       - Verify DNS & request AutoSSL certificate"
        echo -e "  ${GREEN}minimalpanel restart${NC}   - Restart MinimalPanel agent, MariaDB, and web server"
        echo -e "  ${GREEN}minimalpanel status${NC}    - View running status of core services"
        echo -e "  ${GREEN}minimalpanel reset-2fa${NC} - Reset 2FA configuration"
        ;;
esac
EOF

sudo sed -i "s/HOST_DOMAIN_PLACEHOLDER/${PANEL_DOMAIN}/g" /usr/local/bin/minimalpanel
sudo chmod +x /usr/local/bin/minimalpanel
sudo ln -sf /usr/local/bin/minimalpanel /usr/local/bin/mp

# 13. Automated Cron Watchdog (Runs Health Check Every 5 Minutes)
(crontab -l 2>/dev/null | grep -v "/usr/local/bin/minimalpanel check"; echo "*/5 * * * * /usr/local/bin/minimalpanel check >/dev/null 2>&1") | crontab -

# 14. Initial AutoSSL Request Pre-Check
echo -e "${CYAN}[11/11] Verifying DNS & Running AutoSSL Request...${NC}"
sudo /usr/local/bin/minimalpanel ssl || true

# Summary Output
echo -e "\n${GREEN}====================================================${NC}"
echo -e "${GREEN} SUCCESS: MinimalPanel Successfully Deployed!${NC}"
echo -e "${GREEN}====================================================${NC}\n"
echo -e "MinimalPanel URL: ${CYAN}http://${PANEL_DOMAIN}${NC}"
echo -e "Installed PHP Handlers: ${CYAN}7.4, 8.2, 8.3, 8.4, 8.5${NC}"
echo -e "Real-Time .htaccess Watcher: ${CYAN}ACTIVE (Auto-reloads OLS on changes)${NC}"
echo -e "CLI Helper Commands: Run ${CYAN}minimalpanel${NC} or ${CYAN}mp${NC} in SSH terminal"
echo -e "  - ${CYAN}mp ssl${NC}       (Verify DNS & issue Let's Encrypt SSL)"
echo -e "  - ${CYAN}mp check${NC}     (Check service health & auto-recover from crashes)"
echo -e "  - ${CYAN}mp restart${NC}   (Restart MinimalPanel agent, MariaDB, & OLS)"
echo -e "  - ${CYAN}mp reset-2fa${NC} (Reset lost 2FA credentials)"
