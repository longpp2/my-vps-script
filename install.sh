#!/usr/bin/env bash
set -euo pipefail

# 1. 检查 root 权限
if [ "$(id -u)" -ne 0 ]; then
    echo "错误：必须使用 root 权限运行！" >&2
    exit 1
fi

INSTALL_DIR="/usr/local/s-ui"

# 2. 识别系统 CPU 架构
ARCH=$(uname -m)
case "$ARCH" in
    x86_64|amd64) TARGET_ARCH="amd64" ;;
    aarch64|arm64) TARGET_ARCH="arm64" ;;
    armv7l|armv7) TARGET_ARCH="armv7" ;;
    *) echo "不支持的 CPU 架构: $ARCH" >&2; exit 1 ;;
esac

# 3. 安装依赖 (curl, tar)
if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq && apt-get install -y -qq curl tar
elif command -v yum >/dev/null 2>&1; then
    yum install -y -q curl tar || true
fi

# 4. 获取 s-ui 最新版本号并规范化（去除多余的 'v' 前缀）
echo "==> 正在获取 s-ui 最新版本..."
LATEST_JSON=$(curl -fsSL https://api.github.com/repos/alireza0/s-ui/releases/latest || true)
TAG_NAME=$(echo "$LATEST_JSON" | grep -o '"tag_name": *"[^"]*"' | head -n 1 | cut -d'"' -f4)

if [ -z "$TAG_NAME" ]; then
    TAG_NAME="v1.6.3"
fi
# 确保 TAG_NAME 以 v 开头
[[ "$TAG_NAME" =~ ^v ]] || TAG_NAME="v${TAG_NAME}"
echo "==> 目标安装版本: ${TAG_NAME} (${TARGET_ARCH})"

# 5. 直接下载官方预编译二进制包（绕过官方不兼容的 install.sh）
DOWNLOAD_URL="https://github.com/alireza0/s-ui/releases/download/${TAG_NAME}/s-ui-linux-${TARGET_ARCH}.tar.gz"
echo "==> 正在下载安装包: ${DOWNLOAD_URL}"

mkdir -p "$INSTALL_DIR"
TMP_DIR=$(mktemp -d)
curl -fL "$DOWNLOAD_URL" -o "$TMP_DIR/s-ui.tar.gz"
tar -zxf "$TMP_DIR/s-ui.tar.gz" -C "$INSTALL_DIR"
rm -rf "$TMP_DIR"
chmod +x "$INSTALL_DIR/s-ui"

# 软链接命令到全局 PATH
ln -sf "$INSTALL_DIR/s-ui" /usr/local/bin/s-ui
ln -sf "$INSTALL_DIR/s-ui" /usr/bin/s-ui

# 6. 配置 systemd 服务
cat <<EOF > /etc/systemd/system/s-ui.service
[Unit]
Description=s-ui service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/s-ui
Restart=on-failure
RestartSec=5s
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable s-ui >/dev/null 2>&1
systemctl restart s-ui

# 7. 设置管理员账号和密码
echo "==> 正在配置面板管理员账号密码..."
sleep 2
s-ui reset-user -u tiangeben -p tiangeben2024 || s-ui user -u tiangeben -p tiangeben2024 || true
systemctl restart s-ui

# 8. 获取公网 IP 并输出信息
IP=$(curl -4 -fsSL --max-time 5 https://api.ipify.org || curl -4 -fsSL --max-time 5 https://ifconfig.me || echo "你的VPS公网IP")
echo ""
echo "================ 部署完成 ================"
echo "面板地址: http://${IP}:2096"
echo "用户名  : tiangeben"
echo "密码    : tiangeben2024"
echo "=========================================="
