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

# 3. 安装基础依赖 (curl / tar)
if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq && apt-get install -y -qq curl tar
elif command -v yum >/dev/null 2>&1; then
    yum install -y -q curl tar || true
fi

# 4. 获取最新版本（使用纯 grep/sed，无需 jq 依赖）
echo "==> 正在获取 s-ui 最新版本..."
LATEST_JSON=$(curl -fsSL https://api.github.com/repos/alireza0/s-ui/releases/latest || true)
LATEST_VERSION=$(echo "$LATEST_JSON" | grep -o '"tag_name": *"[^"]*"' | head -n 1 | cut -d'"' -f4)

if [ -z "$LATEST_VERSION" ]; then
    echo "获取最新 tag 失败，回退使用稳定版本 v1.5.5"
    LATEST_VERSION="v1.5.5"
fi
echo "==> 目标安装版本: ${LATEST_VERSION}"

# 5. 调用官方脚本安装
bash <(curl -fsSL "https://raw.githubusercontent.com/alireza0/s-ui/${LATEST_VERSION}/install.sh") "${LATEST_VERSION}"

# 6. 配置指定用户名和密码
echo "==> 正在配置面板管理员账号与密码..."
s-ui reset-user -u tiangeben -p tiangeben2024 || s-ui user -u tiangeben -p tiangeben2024 || true
systemctl restart s-ui

# 7. 获取外网 IP 并输出
IP=$(curl -4 -fsSL --max-time 5 https://api.ipify.org || curl -4 -fsSL --max-time 5 https://ifconfig.me || echo "你的VPS公网IP")
echo ""
echo "================ 部署完成 ================"
echo "系统架构: $TARGET_ARCH"
echo "面板地址: http://${IP}:2096"
echo "用户名  : tiangeben"
echo "密码    : tiangeben2024"
echo "=========================================="
