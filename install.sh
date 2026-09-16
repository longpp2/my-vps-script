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

# 3. 安装依赖
if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq && apt-get install -y -qq curl tar
elif command -v yum >/dev/null 2>&1; then
    yum install -y -q curl tar || true
fi

# 4. 清理旧残留并下载解压
rm -rf "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
TMP_DIR=$(mktemp -d)

DOWNLOAD_URL="https://github.com/alireza0/s-ui/releases/download/${VERSION}/s-ui-linux-${TARGET_ARCH}.tar.gz"
echo "==> 正在下载: ${DOWNLOAD_URL}"
curl -fL "$DOWNLOAD_URL" -o "$TMP_DIR/s-ui.tar.gz"
tar -zxf "$TMP_DIR/s-ui.tar.gz" -C "$TMP_DIR"

# 智能提取核心可执行文件（自动搜索解压出来的可执行程序）
TARGET_BIN=$(find "$TMP_DIR" -type f \( -name "sui" -o -name "s-ui" \) | head -n 1)

if [ -z "$TARGET_BIN" ]; then
    echo "错误：压缩包内未找到可执行文件！解压内容如下：" >&2
    ls -laR "$TMP_DIR"
    exit 1
fi

# 将所有解压内容平铺移入目标目录
if [ -d "$TMP_DIR/s-ui" ]; then
    cp -rf "$TMP_DIR/s-ui/"* "$INSTALL_DIR/"
else
    cp -rf "$TMP_DIR/"* "$INSTALL_DIR/"
fi
rm -rf "$TMP_DIR"

# 确保主二进制名为 sui
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
systemctl enable s-ui >/dev/null 2>&1
systemctl restart s-ui

# 6. 配置指定用户名与密码
echo "==> 正在配置面板管理员账号与密码..."
sleep 2
"$INSTALL_DIR/sui" reset-user -u "$PANEL_USER" -p "$PANEL_PASS" || "$INSTALL_DIR/sui" user -u "$PANEL_USER" -p "$PANEL_PASS" || true
systemctl restart s-ui

# 7. 防火墙端口放行
if command -v ufw >/dev/null 2>&1; then
    ufw allow "${PANEL_PORT}/tcp" >/dev/null 2>&1 || true
elif command -v firewall-cmd >/dev/null 2>&1; then
    firewall-cmd --zone=public --add-port="${PANEL_PORT}/tcp" --permanent >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
fi

# 8. 输出结果
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
