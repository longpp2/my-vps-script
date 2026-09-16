#!/usr/bin/env bash
set -euo pipefail

# 1. 检查 root 权限
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

# 2. 识别系统 CPU 架构
ARCH=$(uname -m)
case "$ARCH" in
    x86_64|amd64) TARGET_ARCH="amd64" ;;
    aarch64|arm64) TARGET_ARCH="arm64" ;;
    armv7l|armv7) TARGET_ARCH="armv7" ;;
    *) echo "不支持的 CPU 架构: $ARCH" >&2; exit 1 ;;
esac

echo "==> 目标系统架构: ${TARGET_ARCH}，面板版本: ${VERSION}"

# 3. 安装依赖 (curl, tar, openssl, sqlite3, qrencode)
if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq && apt-get install -y -qq curl tar openssl sqlite3 qrencode || true
elif command -v yum >/dev/null 2>&1; then
    yum install -y -q curl tar openssl sqlite qrencode || true
fi

# 4. 下载预编译二进制包并解压
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

# 5. 配置 systemd 服务
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

# 6. 初始化管理员账密
echo "==> 正在初始化管理员账号与密码..."
(cd "$INSTALL_DIR" && ./sui admin -username "$PANEL_USER" -password "$PANEL_PASS")

# 7. 去重整合所有 SNI 域名进行测速选优
echo "==> 正在对所有候选 SNI 域名执行 TCP/TLS 握手测速..."
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

# 数组去重
UNIQUE_DOMAINS=($(printf "%s\n" "${DOMAINS[@]}" | sort -u))

BEST_SNI=""
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

# 保底默认
if [ -z "$BEST_SNI" ]; then
    BEST_SNI="iosapps.itunes.apple.com"
    echo "测速超时，使用保底 SNI: $BEST_SNI"
else
    echo "==> 选定最低延迟 SNI: $BEST_SNI (${MIN_LATENCY} ms)"
fi

# 8. 生成密钥与自签证书
CERT_DIR="$INSTALL_DIR/cert"
mkdir -p "$CERT_DIR"
openssl req -x509 -newkey rsa:2048 -nodes -sha256 -keyout "$CERT_DIR/self.key" -out "$CERT_DIR/self.crt" -days 3650 -subj "/CN=$BEST_SNI" 2>/dev/null

REALITY_KEYPAIR=$(openssl ecparam -name prime256v1 -genkey -noout -out /tmp/ec.key 2>/dev/null && openssl ec -in /tmp/ec.key -text -noout 2>/dev/null || true)
REALITY_PRIV=$(openssl rand -base64 32 | tr -d '=+/' | cut -c1-43)
REALITY_PUB=$(openssl rand -base64 32 | tr -d '=+/' | cut -c1-43)
SHORT_ID=$(openssl rand -hex 8)
rm -f /tmp/ec.key

# 用户 UUID 与密码
USER_UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || openssl rand -hex 16)
TUIC_PASS=$(openssl rand -base64 12 | tr -d '=+/' | cut -c1-12)

# 9. 写入 s-ui 本地 SQLite 数据库
mkdir -p "$INSTALL_DIR/db"
DB_FILE="$INSTALL_DIR/db/s-ui.db"

# 临时拉起服务让数据库自动初始化表结构
systemctl restart s-ui
sleep 2
systemctl stop s-ui

NOW_SEC=$(date +%s)

# 清理并写入两组 TLS 配置模板
sqlite3 "$DB_FILE" "DELETE FROM inbound_tls WHERE name IN ('一', '二');" 2>/dev/null || true
sqlite3 "$DB_FILE" <<SQL
INSERT INTO inbound_tls (name, type, server_name, reality_server_name, reality_server_port, reality_private_key, reality_public_key, reality_short_ids, reality_fingerprint, cert_file, key_file, insecure, enabled, created_at, updated_at)
VALUES (
    '一', 'reality', '', '$BEST_SNI', 443, '$REALITY_PRIV', '$REALITY_PUB', '$SHORT_ID', 'chrome', '', '', 0, 1, $NOW_SEC, $NOW_SEC
);

INSERT INTO inbound_tls (name, type, server_name, reality_server_name, reality_server_port, reality_private_key, reality_public_key, reality_short_ids, reality_fingerprint, cert_file, key_file, insecure, enabled, created_at, updated_at)
VALUES (
    '二', 'tls', '$BEST_SNI', '', 0, '', '', '', '', '$CERT_DIR/self.crt', '$CERT_DIR/self.key', 1, 1, $NOW_SEC, $NOW_SEC
);
SQL

# 写入入站配置：1 为 VLESS(TCP:443)，2 为 TUIC(UDP:443, BBR)
sqlite3 "$DB_FILE" "DELETE FROM inbounds WHERE tag IN ('1', '2');" 2>/dev/null || true
sqlite3 "$DB_FILE" <<SQL
INSERT INTO inbounds (tag, protocol, listen, port, tls_id, settings, enabled, created_at, updated_at)
VALUES (
    '1', 'vless', '0.0.0.0', 443, (SELECT id FROM inbound_tls WHERE name='一'), '{"network":"tcp"}', 1, $NOW_SEC, $NOW_SEC
);

INSERT INTO inbounds (tag, protocol, listen, port, tls_id, settings, enabled, created_at, updated_at)
VALUES (
    '2', 'tuic', '0.0.0.0', 443, (SELECT id FROM inbound_tls WHERE name='二'), '{"congestion_control":"bbr","zero_rtt_handshake":false}', 1, $NOW_SEC, $NOW_SEC
);
SQL

# 写入用户 My 并关联两个入站标签
sqlite3 "$DB_FILE" "DELETE FROM clients WHERE name='My';" 2>/dev/null || true
sqlite3 "$DB_FILE" <<SQL
INSERT INTO clients (name, uuid, password, inbounds, enable, created_at, updated_at)
VALUES (
    'My', '$USER_UUID', '$TUIC_PASS', '["1","2"]', 1, $NOW_SEC, $NOW_SEC
);
SQL

# 10. 启动并放行所有端口 (2095后台, 2096订阅, 443节点)
systemctl enable s-ui >/dev/null 2>&1
systemctl start s-ui

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

# 11. 获取外网 IP 与订阅 Token
IP=$(curl -4 -fsSL --max-time 5 https://api.ipify.org || curl -4 -fsSL --max-time 5 https://ifconfig.me || echo "你的VPS公网IP")
SUB_TOKEN=$(sqlite3 "$DB_FILE" "SELECT token FROM settings WHERE key='sub_token' LIMIT 1;" 2>/dev/null || true)
[ -z "$SUB_TOKEN" ] && SUB_TOKEN="$USER_UUID"

SUB_URL="http://${IP}:${SUB_PORT}/sub/${SUB_TOKEN}"

# 打印最终输出
echo ""
echo "==================== 部署与配置完成 ===================="
echo "面板后台地址 : http://${IP}:${PANEL_PORT}/app/"
echo "管理员账号   : ${PANEL_USER}"
echo "管理员密码   : ${PANEL_PASS}"
echo "最低延迟 SNI : ${BEST_SNI} (${MIN_LATENCY} ms)"
echo "--------------------------------------------------------"
echo "订阅链接     : ${SUB_URL}"
echo "--------------------------------------------------------"
echo "订阅二维码如下 (请直接使用客户端扫码):"
echo ""
if command -v qrencode >/dev/null 2>&1; then
    qrencode -t ANSIUTF8 "${SUB_URL}" || echo "无法渲染二维码，请直接复制上方订阅链接"
else
    echo "未安装 qrencode，请直接复制上方订阅链接到客户端使用。"
fi
echo "========================================================"
