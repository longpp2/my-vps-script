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

echo "==> 目标架构: ${TARGET_ARCH}，面板版本: ${VERSION}"

# 1. 安装基础依赖
if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq && apt-get install -y -qq curl tar openssl sqlite3 qrencode python3 || true
elif command -v yum >/dev/null 2>&1; then
    yum install -y -q curl tar openssl sqlite qrencode python3 || true
fi

# 2. 下载并解压程序
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

# 4. 首次启动初始化数据库并重置账密
systemctl restart s-ui
sleep 2
echo "==> 正在配置管理员账号与密码..."
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
BEST_SNI="visualstudio.microsoft.com"
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

# 6. 生成证书与 REALITY 密钥对
CERT_DIR="$INSTALL_DIR/cert"
mkdir -p "$CERT_DIR"
openssl req -x509 -newkey rsa:2048 -nodes -sha256 -keyout "$CERT_DIR/self.key" -out "$CERT_DIR/self.crt" -days 3650 -subj "/CN=$BEST_SNI" 2>/dev/null

REALITY_PRIV="eA_GjK0uF_Yw0_uI2t_b1gN5fE7hD9lM6aC4oP8rS2k"
REALITY_PUB="sK_HlP3vG_Zx1_vJ3u_c2hO6gF8iE0mN7bD5pQ9tT3l"
if command -v sing-box >/dev/null 2>&1; then
    KP=$(sing-box generate reality-keypair 2>/dev/null || true)
    if [ -n "$KP" ]; then
        REALITY_PRIV=$(echo "$KP" | grep "PrivateKey" | awk '{print $2}')
        REALITY_PUB=$(echo "$KP" | grep "PublicKey" | awk '{print $2}')
    fi
fi
SHORT_ID=$(openssl rand -hex 8)
USER_UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || openssl rand -hex 16)
TUIC_PASS=$(openssl rand -base64 12 | tr -d '=+/' | cut -c1-12)

DB_FILE="$INSTALL_DIR/db/s-ui.db"
IP=$(curl -4 -fsSL --max-time 5 https://api.ipify.org || curl -4 -fsSL --max-time 5 https://ifconfig.me || echo "127.0.0.1")

# 7. 停止服务，利用 Python 对齐实际表结构注入数据
systemctl stop s-ui

python3 - <<PYEOF
import sqlite3
import json
import time

conn = sqlite3.connect("$DB_FILE")
cur = conn.cursor()

# 1. 写入 tls 表
cur.execute("DELETE FROM tls WHERE name IN ('一', '二')")

server_1 = {
    "enabled": True,
    "reality": {
        "enabled": True,
        "handshake": {"server": "$BEST_SNI", "port": 443},
        "private_key": "$REALITY_PRIV",
        "short_ids": ["$SHORT_ID"],
        "max_time_diff": 60000
    }
}
client_1 = {
    "enabled": True,
    "reality": {
        "enabled": True,
        "public_key": "$REALITY_PUB",
        "short_id": "$SHORT_ID"
    },
    "server_name": "$BEST_SNI",
    "utls": {"enabled": True, "fingerprint": "chrome"}
}

server_2 = {
    "enabled": True,
    "certificate_path": "$CERT_DIR/self.crt",
    "key_path": "$CERT_DIR/self.key",
    "alpn": ["h3", "spdy/3.1"]
}
client_2 = {
    "enabled": True,
    "insecure": True,
    "server_name": "$BEST_SNI",
    "alpn": ["h3", "spdy/3.1"]
}

cur.execute("INSERT INTO tls (name, server, client) VALUES (?, ?, ?)", ('一', json.dumps(server_1), json.dumps(client_1)))
tls_1_id = cur.lastrowid

cur.execute("INSERT INTO tls (name, server, client) VALUES (?, ?, ?)", ('二', json.dumps(server_2), json.dumps(client_2)))
tls_2_id = cur.lastrowid

# 2. 写入 inbounds 表 (VLESS TCP 443, TUIC UDP 443)
cur.execute("DELETE FROM inbounds WHERE tag IN ('1', '2')")

vless_options = {"network": "tcp"}
tuic_options = {"congestion_control": "bbr", "zero_rtt_handshake": False}

cur.execute("""
    INSERT INTO inbounds (type, tag, tls_id, addrs, options)
    VALUES (?, ?, ?, ?, ?)
""", ('vless', '1', tls_1_id, json.dumps([{"listen": "0.0.0.0", "port": 443}]), json.dumps(vless_options)))
inbound_1_id = cur.lastrowid

cur.execute("""
    INSERT INTO inbounds (type, tag, tls_id, addrs, options)
    VALUES (?, ?, ?, ?, ?)
""", ('tuic', '2', tls_2_id, json.dumps([{"listen": "0.0.0.0", "port": 443}]), json.dumps(tuic_options)))
inbound_2_id = cur.lastrowid

# 3. 写入 clients 表
cur.execute("DELETE FROM clients WHERE name='My'")

client_config = {
    "uuid": "$USER_UUID",
    "password": "$TUIC_PASS"
}

vless_link = f"vless://$USER_UUID@$IP:443?encryption=none&flow=&security=reality&sni=$BEST_SNI&fp=chrome&pbk=$REALITY_PUB&sid=$SHORT_ID&type=tcp#VLESS-$BEST_SNI"
tuic_link = f"tuic://$USER_UUID:$TUIC_PASS@$IP:443?congestion_control=bbr&alpn=h3&sni=$BEST_SNI&allow_insecure=1#TUIC-$BEST_SNI"

cur.execute("""
    INSERT INTO clients (enable, name, config, inbounds, links, created_at)
    VALUES (?, ?, ?, ?, ?, ?)
""", (1, 'My', json.dumps(client_config), json.dumps([inbound_1_id, inbound_2_id]), json.dumps([vless_link, tuic_link]), int(time.time())))

conn.commit()
conn.close()
PYEOF

# 8. 启动面板并放行所有端口
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

SUB_URL="http://${IP}:${SUB_PORT}/sub/${USER_UUID}"

echo ""
echo "==================== 部署与配置完成 ===================="
echo "面板后台地址 : http://${IP}:${PANEL_PORT}/app/"
echo "管理员账号   : ${PANEL_USER}"
echo "管理员密码   : ${PANEL_PASS}"
echo "选定优选 SNI : ${BEST_SNI} (${MIN_LATENCY} ms)"
echo "--------------------------------------------------------"
echo "订阅链接     : ${SUB_URL}"
echo "--------------------------------------------------------"
if command -v qrencode >/dev/null 2>&1; then
    echo "订阅二维码如下 (请直接使用客户端扫码):"
    echo ""
    qrencode -t ANSIUTF8 "${SUB_URL}" || true
fi
echo "========================================================"
