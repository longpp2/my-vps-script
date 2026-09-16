#!/usr/bin/env bash
set -euo pipefail

# 1. 检查 root 权限
if [ "$(id -u)" -ne 0 ]; then
    echo "错误：必须使用 root 权限运行！" >&2
    exit 1
fi

# 2. 识别系统 CPU 架构
ARCH=$(uname -m)
case "$ARCH" in
    x86_64|amd64) TARGET_ARCH="amd64" ;;
    aarch64|arm64) TARGET_ARCH="arm64" ;;
    armv7l|armv7) TARGET_ARCH="armv7" ;;
    *) echo "不支持的 CPU 架构: $ARCH" >&2; exit 1 ;;
esac

# 3. 安装依赖
if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq && apt-get install -y -qq curl jq
elif command -v yum >/dev/null 2>&1; then
    yum install -y -q curl jq
fi

# 4. 获取最新版本并调用官方命令安装
LATEST_VERSION=$(curl -fsSL https://api.github.com/repos/alireza0/s-ui/releases/latest | jq -r '.tag_name // "v1.5.5"')
bash <(curl -fsSL "https://raw.githubusercontent.com/alireza0/s-ui/${LATEST_VERSION}/install.sh") "${LATEST_VERSION}"

# 5. 设置自定义账密与重启
s-ui reset-user -u tiangeben -p tiangeben2024 || true
systemctl restart s-ui

# 6. 输出面板信息
IP=$(curl -4 -fsSL https://api.ipify.org || curl -4 -fsSL https://ifconfig.me || echo "你的VPS_IP")
echo ""
echo "================ 部署完成 ================"
echo "架构: $TARGET_ARCH"
echo "面板地址: http://${IP}:2096"
echo "用户名  : tiangeben"
echo "密码    : tiangeben2024"
echo "=========================================="
