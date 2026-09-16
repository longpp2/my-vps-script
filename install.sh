#!/usr/bin/env bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "错误：必须使用 root 权限运行！" >&2
    exit 1
fi

VERSION="v1.5.5"
INSTALL_DIR="/usr/local/s-ui"
PANEL_USER="tiangeben"
PANEL_PASS="tiangeben2024"
PANEL_PORT="2095"
SUB_PORT="2096"

ARCH=$(uname -m)
case "$ARCH" in
    x86_64|amd64) TARGET_ARCH="amd64" ;;
    aarch64|arm64) TARGET_ARCH="arm64" ;;
    armv7l|armv7) TARGET_ARCH="armv7" ;;
    *) echo "不支持的 CPU 架构: $ARCH" >&2; exit 1 ;;
esac

echo "==> 目标系统架构: ${TARGET_ARCH}，面板版本: ${VERSION}"

# 1. 安装基础依赖
if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq && apt-get install -y -qq curl tar openssl sqlite3 qrencode python3 || true
elif command -v yum >/dev/null 2>&1; then
    yum install -y -q curl tar openssl sqlite qrencode python3 || true
fi

# 2. 下载并解压安装
rm -rf "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
TMP_DIR=$(mktemp -d)

DOWNLOAD_URL="https://github.com/alireza0/s-ui/releases/download/${VERSION}/s-ui-linux-${TARGET_ARCH}.tar.gz"
echo "==> 正在下载官方安装包: ${DOWNLOAD_URL}"
curl -fL "$DOWNLOAD_URL" -o "$TMP_DIR/s-ui.tar.gz"
tar -zxf "$TMP_DIR/s-ui.tar.gz" -C "$TMP_DIR"

if [ -d "$TMP_DIR/s-ui" ]; then
    cp -rf "$TMP_DIR/s-ui/"* "$INSTALL_DIR/"
else
    cp -rf "$TMP_DIR/"* "$INSTALL_DIR/"
fi
rm -rf "$TMP_DIR"

if [ ! -f "$INSTALL_DIR/sui" ] && [ -f "$INSTALL_DIR/s-ui" ]; then
    mv "$INSTALL_DIR/s-ui" "$INSTALL_DIR/sui"
fi

chmod +x "$INSTALL_DIR/sui"
ln -sf "$INSTALL_DIR/sui" /usr/local/bin/s-ui
ln -sf "$INSTALL_DIR/sui" /usr/bin/s-ui
ln -sf "$INSTALL_DIR/sui" /usr/local/bin/sui
ln -sf "$INSTALL_DIR/sui" /usr/bin/sui

# 3. 配置 systemd 服务
cat <<EOF > /etc/systemd/system/s-ui.service
[Unit]
Description=s-ui service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/sui
Restart=on-failure
RestartSec=5s
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload

# 4. 首次拉起初始化数据库并配置管理员账密
systemctl restart s-ui
sleep 2
echo "==> 正在配置面板管理员账号与密码..."
(cd "$INSTALL_DIR" && ./sui admin -username "$PANEL_USER" -password "$PANEL_PASS")

# 5. 全量去重 SNI 握手测速
echo "==> 正在对候选 SNI 域名执行 TCP/TLS 握手测速..."
DOMAINS=(
    "amd.com" "d.impactradius-event.com" "t0.m.awsstatic.com" "acctcdn.msftauth.net" "www.oracle.com"
    "lpcdn.lpsnmedia.net" "cdn-dynmedia-1.microsoft.com" "ms-vscode.gallerycdn.vsassets.io" "aws.com" "intel.com"
    "b.6sc.co" "digitalassets.tesla.com" "rum.hlx.page" "download.amd.com" "ts1.tc.mm.bing.net"
    "prod.us-east-1.ui.gcr-chat.marketing.aws.dev" "assets.adobedtm.com" "visualstudio.microsoft.com"
    "d.oracleinfinity.io" "r.bing.com" "img-prod-cms-rt-microsoft-com.akamaized.net" "tags.tiqcdn.com"
    "snap.licdn.com" "j.6sc.co" "c.s-microsoft.com" "consent.trustarc.com" "www.bing.com" "aadcdn.msftauth.net"
    "fpinit.itunes.apple.com" "s.company-target.com" "c.6sc.co" "d2c.aws.amazon.com" "c.marsflag.com"
    "mscom.demdex.net" "www.nvidia.com" "gray-wowt-prod.gtv-cdn.com" "www.wowt.com" "aws.amazon.com"
    "azure.microsoft.com" "electronics.sony.com" "apps.mzstatic.com" "devblogs.microsoft.com"
    "catalog.gamepass.com" "static.cloud.coveo.com" "cdn.bizibly.com" "www.intel.com"
    "downloadmirror.intel.com" "ce.mf.marsflag.com" "www.amd.com" "ts2.tc.mm.bing.net" "s.go-mpulse.net"
    "drivers.amd.com" "github.gallerycdn.vsassets.io" "www.sony.com" "cdnssl.clicktale.net"
    "api.company-target.com" "services.digitaleast.mobi" "d0.m.awsstatic.com" "iosapps.itunes.apple.com"
    "tag-logger.demandbase.com"
)

UNIQUE_DOMAINS=($(printf "%s\n" "${DOMAINS[@]}" | sort -u))
BEST_SNI="d.oracleinfinity.io"
MIN_LATENCY=99999

for d in "${UNIQUE_DOMAINS[@]}"; do
    t1=$(date +%s%3N)
    if timeout 1 openssl s_client -connect "$d:443" -servername "$d" </dev/null &>/dev/null; then
        t2=$(date +%s%3N)
        lat=$((t2 - t1))
        echo "  - $d: ${lat} ms"
        if [ "$lat" -lt "$MIN_LATENCY" ]; then
            MIN_LATENCY=$lat
            BEST_SNI=$d
        fi
    fi
done
echo "==> 选定最低延迟 SNI: $BEST_SNI (${MIN_LATENCY} ms)"

# 6. 生成证书和密钥
CERT_DIR=$(mktemp -d)
openssl req -x509 -newkey rsa:2048 -nodes -sha256 -keyout "$CERT_DIR/self.key" -out "$CERT_DIR/self.crt" -days 3650 -subj "/CN=$BEST_SNI" 2>/dev/null
CERT_PUBKEY_SHA256=$(openssl x509 -in "$CERT_DIR/self.crt" -pubkey -noout | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | base64)
CERT_PUBKEY_HEX=$(openssl x509 -in "$CERT_DIR/self.crt" -pubkey -noout | openssl pkey -pubin -outform der | openssl dgst -sha256 -hex | awk '{print $2}')

systemctl stop s-ui

DB_FILE="$INSTALL_DIR/db/s-ui.db"
IP=$(curl -4 -fsSL --max-time 5 https://api.ipify.org || curl -4 -fsSL --max-time 5 https://ifconfig.me || echo "127.0.0.1")

# 7. Python 精准写入对齐官方架构的二进制 BLOB
python3 - <<PYEOF
import sqlite3
import json
import uuid
import secrets
import base64
import time

def to_blob(data):
    return sqlite3.Binary(json.dumps(data, indent=2).encode('utf-8'))

conn = sqlite3.connect("$DB_FILE")
cur = conn.cursor()

with open("$CERT_DIR/self.key", "r") as f:
    key_lines = [line.strip() for line in f if line.strip()]
with open("$CERT_DIR/self.crt", "r") as f:
    crt_lines = [line.strip() for line in f if line.strip()]

reality_priv = secrets.token_urlsafe(32)[:43]
reality_pub = secrets.token_urlsafe(32)[:43]
short_id = secrets.token_hex(4)

client_uuid = str(uuid.uuid4())
client_pass = secrets.token_urlsafe(8)[:8]
ss_pass_1 = base64.b64encode(secrets.token_bytes(32)).decode('utf-8')
ss_pass_2 = base64.b64encode(secrets.token_bytes(16)).decode('utf-8')

# TLS 表
cur.execute("DELETE FROM tls WHERE name IN ('一', '二')")

tls_server_1 = {
    "enabled": True,
    "reality": {
        "enabled": True,
        "handshake": {
            "server": "$BEST_SNI",
            "server_port": 443
        },
        "private_key": reality_priv,
        "short_id": ["", short_id]
    },
    "server_name": "$BEST_SNI"
}
tls_client_1 = {
    "reality": {
        "public_key": reality_pub
    },
    "utls": {
        "enabled": True,
        "fingerprint": "chrome"
    }
}

tls_server_2 = {
    "enabled": True,
    "key": key_lines,
    "certificate": crt_lines,
    "alpn": ["h3", "h2", "http/1.1"],
    "server_name": "$BEST_SNI"
}
tls_client_2 = {
    "certificate_public_key_sha256": ["$CERT_PUBKEY_SHA256"],
    "insecure": True
}

cur.execute("INSERT INTO tls (name, server, client) VALUES (?, ?, ?)",
            ('一', to_blob(tls_server_1), to_blob(tls_client_1)))
tls_1_id = cur.lastrowid

cur.execute("INSERT INTO tls (name, server, client) VALUES (?, ?, ?)",
            ('二', to_blob(tls_server_2), to_blob(tls_client_2)))
tls_2_id = cur.lastrowid

# Inbounds 表 (tag 1: VLESS, tag 2: TUIC)
cur.execute("DELETE FROM inbounds WHERE tag IN ('1', '2')")

inbound_1_options = {
    "listen": "::",
    "listen_port": 443,
    "transport": {}
}
inbound_2_options = {
    "congestion_control": "bbr",
    "listen": "::",
    "listen_port": 443
}

cur.execute("""
    INSERT INTO inbounds (type, tag, tls_id, addrs, options)
    VALUES (?, ?, ?, ?, ?)
""", ('vless', '1', tls_1_id, to_blob([]), to_blob(inbound_1_options)))
inbound_1_id = cur.lastrowid

cur.execute("""
    INSERT INTO inbounds (type, tag, tls_id, addrs, options)
    VALUES (?, ?, ?, ?, ?)
""", ('tuic', '2', tls_2_id, to_blob([]), to_blob(inbound_2_options)))
inbound_2_id = cur.lastrowid

# Clients 表
cur.execute("DELETE FROM clients WHERE name='My'")

client_name = "My"
full_config = {
    "anytls": {"name": client_name, "password": client_pass},
    "http": {"name": client_name, "username": client_name, "password": client_pass},
    "hysteria": {"name": client_name, "auth_str": client_pass},
    "hysteria2": {"name": client_name, "password": client_pass},
    "mixed": {"name": client_name, "username": client_name, "password": client_pass},
    "naive": {"name": client_name, "username": client_name, "password": client_pass},
    "shadowsocks": {"name": client_name, "password": ss_pass_1},
    "shadowsocks16": {"name": client_name, "password": ss_pass_2},
    "shadowtls": {"name": client_name, "password": ss_pass_1},
    "socks": {"name": client_name, "username": client_name, "password": client_pass},
    "trojan": {"name": client_name, "password": client_pass},
    "tuic": {"name": client_name, "uuid": client_uuid, "password": client_pass},
    "vless": {"name": client_name, "uuid": client_uuid, "flow": "xtls-rprx-vision"},
    "vmess": {"name": client_name, "uuid": client_uuid, "alterId": 0}
}

vless_uri = f"vless://{client_uuid}@$IP:443?type=tcp&security=reality&pbk={reality_pub}&sid={short_id}&fp=chrome&sni=$BEST_SNI&flow=xtls-rprx-vision#%E4%B8%80"
tuic_uri = f"tuic://{client_uuid}:{client_pass}@$IP:443?security=tls&insecure=1&pcs=$CERT_PUBKEY_HEX&sni=$BEST_SNI&alpn=h3,h2,http/1.1&congestion_control=bbr#%E4%BA%8C"

client_links = [
    {"remark": "一", "type": "local", "uri": vless_uri},
    {"remark": "二", "type": "local", "uri": tuic_uri}
]

cur.execute("""
    INSERT INTO clients (enable, name, config, inbounds, links, created_at)
    VALUES (?, ?, ?, ?, ?, ?)
""", (1, client_name, to_blob(full_config), to_blob([inbound_1_id, inbound_2_id]), to_blob(client_links), int(time.time())))

conn.commit()
conn.close()
PYEOF

rm -rf "$CERT_DIR"

# 8. 启动服务与放行端口
systemctl enable s-ui >/dev/null 2>&1
systemctl restart s-ui

if command -v ufw >/dev/null 2>&1; then
    ufw allow 2095/tcp >/dev/null 2>&1 || true
    ufw allow 2096/tcp >/dev/null 2>&1 || true
    ufw allow 443/tcp >/dev/null 2>&1 || true
    ufw allow 443/udp >/dev/null 2>&1 || true
elif command -v firewall-cmd >/dev/null 2>&1; then
    firewall-cmd --zone=public --add-port=2095/tcp --permanent >/dev/null 2>&1 || true
    firewall-cmd --zone=public --add-port=2096/tcp --permanent >/dev/null 2>&1 || true
    firewall-cmd --zone=public --add-port=443/tcp --permanent >/dev/null 2>&1 || true
    firewall-cmd --zone=public --add-port=443/udp --permanent >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
fi

# 9. 输出通用订阅及专用 Clash 订阅链接
CLIENT_UUID=$(sqlite3 "$DB_FILE" "SELECT json_extract(config, '$.vless.uuid') FROM clients WHERE name='My';" 2>/dev/null || echo "My")
SUB_URL_RAW="http://${IP}:${SUB_PORT}/sub/${CLIENT_UUID}"
SUB_URL_CLASH="http://${IP}:${SUB_PORT}/sub/${CLIENT_UUID}?format=clash"

echo ""
echo "==================== 部署与配置完成 ===================="
echo "面板后台地址   : http://${IP}:${PANEL_PORT}/app/"
echo "管理员账号     : ${PANEL_USER}"
echo "管理员密码     : ${PANEL_PASS}"
echo "选定优选 SNI   : ${BEST_SNI} (${MIN_LATENCY} ms)"
echo "--------------------------------------------------------"
echo "小火箭/通用订阅: ${SUB_URL_RAW}"
echo "Clash 订阅链接 : ${SUB_URL_CLASH}"
echo "--------------------------------------------------------"
if command -v qrencode >/dev/null 2>&1; then
    echo "小火箭扫码专用二维码:"
    echo ""
    qrencode -t ANSIUTF8 "${SUB_URL_RAW}" || true
fi
echo "========================================================"
