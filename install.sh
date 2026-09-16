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

# 3. 安装依赖 (curl, tar)
if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq && apt-get install -y -qq curl tar
elif command -v yum >/dev/null 2>&1; then
    yum install -y -q curl tar || true
fi

# 4. 下载预编译二进制包并解压提取
rm -rf "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
TMP_DIR=$(mktemp -d)

DOWNLOAD_URL="https://github.com/alireza0/s-ui/releases/download/${VERSION}/s-ui-linux-${TARGET_ARCH}.tar.gz"
echo "==> 正在下载官方安装包: ${DOWNLOAD_URL}"
curl -fL "$DOWNLOAD_URL" -o "$TMP_DIR/s-ui.tar.gz"
tar -zxf "$TMP_DIR/s-ui.tar.gz" -C "$TMP_DIR"

# 兼容提取解压出来的程序文件
if [ -d "$TMP_DIR/s-ui" ]; then
    cp -rf "$TMP_DIR/s-ui/"* "$INSTALL_DIR/"
else
    cp -rf "$TMP_DIR/"* "$INSTALL_DIR/"
fi
rm -rf "$TMP_DIR"

# 统一主程序二进制名为 sui
if [ ! -f "$INSTALL_DIR/sui" ] && [ -f "$INSTALL_DIR/s-ui" ]; then
    mv "$INSTALL_DIR/s-ui" "$INSTALL_DIR/sui"
fi

chmod +x "$INSTALL_DIR/sui"
ln -sf "$INSTALL_DIR/sui" /usr/local/bin/s-ui
ln -sf "$INSTALL_DIR/sui" /usr/bin/s-ui
ln -sf "$INSTALL_DIR/sui" /usr/local/bin/sui
ln -sf "$INSTALL_DIR/sui" /usr/bin/sui

# 5. 配置 systemd 服务 (固定 WorkingDirectory，杜绝相对路径寻库错误)
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

# 6. 配置指定用户名与密码 (必须进入工作目录下执行，确保命中真实的 SQLite 数据库)
echo "==> 正在初始化面板管理员账号与密码..."
(cd "$INSTALL_DIR" && ./sui admin -username "$PANEL_USER" -password "$PANEL_PASS")

# 7. 启动服务并配置防火墙 (放行 2095 面板端口与 2096 订阅端口)
systemctl enable s-ui >/dev/null 2>&1
systemctl restart s-ui

if command -v ufw >/dev/null 2>&1; then
    ufw allow "${PANEL_PORT}/tcp" >/dev/null 2>&1 || true
    ufw allow "${SUB_PORT}/tcp" >/dev/null 2>&1 || true
elif command -v firewall-cmd >/dev/null 2>&1; then
    firewall-cmd --zone=public --add-port="${PANEL_PORT}/tcp" --permanent >/dev/null 2>&1 || true
    firewall-cmd --zone=public --add-port="${SUB_PORT}/tcp" --permanent >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
fi

# 8. 获取公网 IP 并打印访问入口
IP=$(curl -4 -fsSL --max-time 5 https://api.ipify.org || curl -4 -fsSL --max-time 5 https://ifconfig.me || echo "你的VPS公网IP")

echo ""
echo "================ 部署完成 ================"
echo "系统架构    : $TARGET_ARCH"
echo "面板版本    : $VERSION"
echo "面板后台地址: http://${IP}:${PANEL_PORT}/app/"
echo "订阅服务端口: ${SUB_PORT} (/sub/)"
echo "管理员账号  : ${PANEL_USER}"
echo "管理员密码  : ${PANEL_PASS}"
echo "=========================================="
echo "提示：请确保云服务器控制台安全组已放行 TCP ${PANEL_PORT} 与 ${SUB_PORT} 端口。"
