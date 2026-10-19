#!/usr/bin/env bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "错误：必须使用 root 权限运行！" >&2
    exit 1
fi

VERSION="v1.5.5"
INSTALL_DIR="/usr/local/s-ui"
PANEL_PORT="2095"
SUB_PORT="2096"

# ----------------- 账号密码交互配置 -----------------
echo "=========================================="
echo "          s-ui 面板管理员凭据设置         "
echo "=========================================="

RANDOM_USER="admin_$(openssl rand -hex 3)"
RANDOM_PASS=$(openssl rand -base64 12 | tr -d '=+/' | cut -c1-12)
# 生成随机订阅路径后缀，防止被扫描器枚举 /sub/My 盗刷流量
SUB_TOKEN="My_$(openssl rand -hex 4)"

if [ -t 0 ]; then
    INPUT_SRC="/dev/stdin"
else
    INPUT_SRC="/dev/tty"
fi

read -r -p "请输入管理员账号 [直接回车随机生成: ${RANDOM_USER}]: " INPUT_USER < "$INPUT_SRC" || true
PANEL_USER="${INPUT_USER:-$RANDOM_USER}"

read -r -p "请输入管理员密码 [直接回车随机生成: ${RANDOM_PASS}]: " INPUT_PASS < "$INPUT_SRC" || true
PANEL_PASS="${INPUT_PASS:-$RANDOM_PASS}"

echo "------------------------------------------"
echo "已设定管理员账号: ${PANEL_USER}"
echo "已设定管理员密码: ${PANEL_PASS}"
echo "已生成防扫订阅号: ${SUB_TOKEN}"
echo "=========================================="
# ----------------------------------------------------

ARCH=$(uname -m)
case "$ARCH" in
    x86_64|amd64) TARGET_ARCH="amd64" ;;
    aarch64|arm64) TARGET_ARCH="arm64" ;;
    armv7l|armv7) TARGET_ARCH="armv7" ;;
    *) echo "不支持的 CPU 架构: $ARCH" >&2; exit 1 ;;
esac

echo "==> 目标系统架构: ${TARGET_ARCH}，面板版本: ${VERSION}"

# 1. 安装基础依赖
echo "==> 正在检查并安装基础依赖..."
if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq && apt-get install -y -qq curl tar openssl sqlite3 qrencode python3 gawk || true
elif command -v dnf >/dev/null 2>&1; then
    dnf install -y -q curl tar openssl sqlite qrencode python3 gawk || true
elif command -v yum >/dev/null 2>&1; then
    yum install -y -q curl tar openssl sqlite qrencode python3 gawk || true
fi

# 2. 内核网络调优（开启 TCP BBR + 扩大 QUIC/UDP 缓冲区提升 TUIC 吞吐量）
echo "==> 正在应用系统内核 BBR 与 UDP 缓冲区调优..."
cat <<EOF > /etc/sysctl.d/99-sui-optimize.conf
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 26214400
net.core.wmem_max = 26214400
net.core.rmem_default = 26214400
net.core.wmem_default = 26214400
EOF
sysctl --system >/dev/null 2>&1 || true

# 3. 下载并解压安装
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

# 4. 配置 systemd 服务
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

# 5. 首次启动初始化数据库并离线设定管理员（消除 SQLite 锁冲突）
echo "==> 正在初始化数据库并配置管理员凭据..."
systemctl restart s-ui

DB_FILE="$INSTALL_DIR/db/s-ui.db"
for _ in {1..15}; do
    if [ -s "$DB_FILE" ]; then
        sleep 1
        break
    fi
    sleep 1
done

systemctl stop s-ui
(cd "$INSTALL_DIR" && ./sui admin -username "$PANEL_USER" -password "$PANEL_PASS")

# 6. 并发去重 SNI 握手测速（强制校验 TLS 1.3 + HTTP/2，剔除 DNS 解析耗时）
echo "==> 正在对候选 SNI 域名执行并发 TLS 1.3 净握手测速..."
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
SNI_TMP=$(mktemp)

CURL_H2_FLAG=""
if curl --help all 2>&1 | grep -q -- "--http2"; then
    CURL_H2_FLAG="--http2"
fi

for d in "${UNIQUE_DOMAINS[@]}"; do
    (
        res=$(curl -o /dev/null -s -w "%{time_namelookup} %{time_appconnect}" --connect-timeout 1 --max-time 2 --tlsv1.3 $CURL_H2_FLAG "https://$d" 2>/dev/null || true)
        if [ -n "$res" ]; then
            lat=$(echo "$res" | awk '{
                diff = ($2 - $1) * 1000;
                if ($2 > 0 && diff > 0) printf "%d", diff;
                else print 0;
            }')
            if [ "$lat" -gt 0 ] 2>/dev/null; then
                echo "${lat} ${d}" >> "$SNI_TMP"
            fi
        fi
    ) &
done
wait

if [ -s "$SNI_TMP" ]; then
    while read -r lat dom; do
        echo "  - ${dom}: ${lat} ms"
    done < <(sort -n "$SNI_TMP" | head -n 10)
    BEST_LINE=$(sort -n "$SNI_TMP" | head -n 1)
    MIN_LATENCY=$(echo "$BEST_LINE" | awk '{print $1}')
    BEST_SNI=$(echo "$BEST_LINE" | awk '{print $2}')
fi
rm -f "$SNI_TMP"

echo "==> 选定最低延迟 SNI (Top 1): $BEST_SNI (${MIN_LATENCY} ms)"

# 7. 生成配对的 X25519 Reality 密钥与 TUIC 自签证书
CERT_DIR=$(mktemp -d)
openssl req -x509 -newkey rsa:2048 -nodes -sha256 -keyout "$CERT_DIR/self.key" -out "$CERT_DIR/self.crt" -days 3650 -subj "/CN=$BEST_SNI" 2>/dev/null
CERT_PUBKEY_SHA256=$(openssl x509 -in "$CERT_DIR/self.crt" -pubkey -noout | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | base64)
CERT_PUBKEY_HEX=$(openssl x509 -in "$CERT_DIR/self.crt" -pubkey -noout | openssl pkey -pubin -outform der | openssl dgst -sha256 -hex | awk '{print $2}')

# 使用 OpenSSL 生成数学配对的 X25519 私钥与公钥（URL-safe Base64 无填充格式）
X25519_KEY=$(openssl genpkey -algorithm X25519 2>/dev/null)
REALITY_PRIV=$(echo "$X25519_KEY" | openssl pkey -outform DER | tail -c 32 | base64 | tr -d '\n=' | tr '+/' '-_')
REALITY_PUB=$(echo "$X25519_KEY" | openssl pkey -pubout -outform DER | tail -c 32 | base64 | tr -d '\n=' | tr '+/' '-_')

IP=$(curl -4 -fsSL --max-time 5 https://api.ipify.org || curl -4 -fsSL --max-time 5 https://ifconfig.me || echo "127.0.0.1")

# 8. Python 精准写入对齐官方架构的二进制 BLOB
python3 - <<PYEOF
import sqlite3
import json
import uuid
import secrets
import base64
import time

def to_blob(data):
    return sqlite3.Binary(json.dumps(data, indent=2, ensure_ascii=False).encode('utf-8'))

conn = sqlite3.connect("$DB_FILE")
cur = conn.cursor()

with open("$CERT_DIR/self.key", "r") as f:
    key_lines = [line.strip() for line in f if line.strip()]
with open("$CERT_DIR/self.crt", "r") as f:
    crt_lines = [line.strip() for line in f if line.strip()]

reality_priv = "$REALITY_PRIV"
reality_pub = "$REALITY_PUB"
short_id = secrets.token_hex(4)

client_uuid = str(uuid.uuid4())
client_pass = secrets.token_urlsafe(12)[:12]
ss_pass_1 = base64.b64encode(secrets.token_bytes(32)).decode('utf-8')
ss_pass_2 = base64.b64encode(secrets.token_bytes(16)).decode('utf-8')

# 1. TLS 表
cur.execute("DELETE FROM tls WHERE id IN (1, 2) OR name IN ('一', '二')")

tls_server_1 = {
    "enabled": True,
    "reality": {
        "enabled": True,
        "handshake": {
            "server": "$BEST_SNI",
            "server_port": 443
        },
        "private_key": reality_priv,
        "short_id": [short_id]
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

cur.execute("INSERT INTO tls (id, name, server, client) VALUES (1, '一', ?, ?)",
            (to_blob(tls_server_1), to_blob(tls_client_1)))
cur.execute("INSERT INTO tls (id, name, server, client) VALUES (2, '二', ?, ?)",
            (to_blob(tls_server_2), to_blob(tls_client_2)))

# 2. Inbounds 表 (带齐完整的 out_json 模板，保证 Clash 动态渲染)
cur.execute("DELETE FROM inbounds WHERE id IN (1, 2)")

vless_options = {
    "listen": "::",
    "listen_port": 443,
    "transport": {}
}
tuic_options = {
    "congestion_control": "bbr",
    "listen": "::",
    "listen_port": 443
}

vless_out_json = {
    "server": "$IP",
    "server_port": 443,
    "tag": "My1",
    "tls": {
        "enabled": True,
        "reality": {
            "enabled": True,
            "public_key": reality_pub,
            "short_id": short_id
        },
        "server_name": "$BEST_SNI",
        "utls": {
            "enabled": True,
            "fingerprint": "chrome"
        }
    },
    "transport": {},
    "type": "vless"
}

tuic_out_json = {
    "congestion_control": "bbr",
    "server": "$IP",
    "server_port": 443,
    "tag": "My2",
    "tls": {
        "alpn": ["h3"],
        "enabled": True,
        "insecure": True,
        "server_name": "$BEST_SNI"
    },
    "type": "tuic"
}

cur.execute("""
    INSERT INTO inbounds (id, type, tag, tls_id, addrs, options, out_json)
    VALUES (1, 'vless', 'My1', 1, ?, ?, ?)
""", (to_blob([]), to_blob(vless_options), to_blob(vless_out_json)))

cur.execute("""
    INSERT INTO inbounds (id, type, tag, tls_id, addrs, options, out_json)
    VALUES (2, 'tuic', 'My2', 2, ?, ?, ?)
""", (to_blob([]), to_blob(tuic_options), to_blob(tuic_out_json)))

# 3. Clients 表
cur.execute("DELETE FROM clients WHERE name LIKE 'My%'")

client_name = "$SUB_TOKEN"
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
    "vless": {"flow": "xtls-rprx-vision", "name": client_name, "uuid": client_uuid},
    "vmess": {"alterId": 0, "name": client_name, "uuid": client_uuid}
}

vless_uri = f"vless://{client_uuid}@$IP:443?type=tcp&security=reality&pbk={reality_pub}&sid={short_id}&fp=chrome&sni=$BEST_SNI&flow=xtls-rprx-vision#My1"
tuic_uri = f"tuic://{client_uuid}:{client_pass}@$IP:443?security=tls&insecure=1&pcs=$CERT_PUBKEY_HEX&sni=$BEST_SNI&alpn=h3,h2,http/1.1&congestion_control=bbr#My2"

client_links = [
    {"remark": "My1", "type": "local", "uri": vless_uri},
    {"remark": "My2", "type": "local", "uri": tuic_uri}
]

cur.execute("""
    INSERT INTO clients (enable, name, config, inbounds, links, created_at)
    VALUES (?, ?, ?, ?, ?, ?)
""", (1, client_name, to_blob(full_config), to_blob([1, 2]), to_blob(client_links), int(time.time())))

conn.commit()
conn.close()
PYEOF

rm -rf "$CERT_DIR"

# 9. 启动服务与防火墙放行
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

# 10. 输出通用订阅及专用 Clash 订阅链接
SUB_URL_RAW="http://${IP}:${SUB_PORT}/sub/${SUB_TOKEN}"
SUB_URL_CLASH="http://${IP}:${SUB_PORT}/sub/${SUB_TOKEN}?format=clash"

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
