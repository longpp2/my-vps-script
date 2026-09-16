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
PANEL_PORT="2096"

# 2. 识别系统 CPU 架构
ARCH=$(uname -m)
case "$ARCH" in
    x86_64|amd64) TARGET_ARCH="amd64" ;;
    aarch64|arm64) TARGET_ARCH="arm64" ;;
    armv7l|armv7) TARGET_ARCH="armv7" ;;
    *) echo "不支持的 CPU 架构: $ARCH" >&2; exit 1 ;;
esac

echo "==> 目标系统架构: ${TARGET_ARCH}，版本: ${VERSION}"

# 3. 安装解压与网络工具
if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq && apt-get install -y -qq curl tar
elif command -v yum >/dev/null 2>&1; then
    yum install -y -q curl tar || true
fi

# 4. 下载官方预编译二进制包并解压（剥离顶层目录 --strip-components=1）
DOWNLOAD_URL="https://github.com/alireza0/s-ui/releases/download/${VERSION}/s-ui-linux-${TARGET_ARCH}.tar.gz"
echo "==> 正在下载: ${DOWNLOAD_URL}"

mkdir -p "$INSTALL_DIR"
TMP_DIR=$(mktemp -d)
curl -fL "$DOWNLOAD_URL" -o "$TMP_DIR/s-ui.tar.gz"
tar -zxf "$TMP_DIR/s-ui.tar.gz" -C "$INSTALL_DIR" --strip-components=1
rm -rf "$TMP_DIR"

# 赋予执行权限并建立软链接
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
systemctl enable s-ui >/dev/null 2>&1
systemctl restart s-ui

# 6. 配置管理员账号密码
echo "==> 正在配置面板管理员账号与密码..."
sleep 2
"$INSTALL_DIR/sui" reset-user -u "$PANEL_USER" -p "$PANEL_PASS" || "$INSTALL_DIR/sui" user -u "$PANEL_USER" -p "$PANEL_PASS" || true
systemctl restart s-ui

# 7. 配置防火墙放行端口
if command -v ufw >/dev/null 2>&1; then
    ufw allow "${PANEL_PORT}/tcp" >/dev/null 2>&1 || true
elif command -v firewall-cmd >/dev/null 2>&1; then
    firewall-cmd --zone=public --add-port="${PANEL_PORT}/tcp" --permanent >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
fi

# 8. 获取公网 IP 并输出
IP=$(curl -4 -fsSL --max-time 5 https://api.ipify.org || curl -4 -fsSL --max-time 5 https://ifconfig.me || echo "你的VPS公网IP")

echo ""
echo "================ 部署完成 ================"
echo "系统架构: $TARGET_ARCH"
echo "版本状态: $VERSION"
echo "面板地址: http://${IP}:${PANEL_PORT}"
echo "备用安全: https://${IP}:${PANEL_PORT}"
echo "用户名  : ${PANEL_USER}"
echo "密码    : ${PANEL_PASS}"
echo "=========================================="
echo "提示：若网页无法打开，请确保云厂商控制台安全组已放行 TCP ${PANEL_PORT} 端口。"
