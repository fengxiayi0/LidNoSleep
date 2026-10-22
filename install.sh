#!/bin/bash
# 安装到 /Applications，并写入一条只允许两条 pmset 命令的 sudoers 规则。
# 用法：./install.sh
set -euo pipefail
cd "$(dirname "$0")"

DEST="/Applications/LidNoSleep.app"
SUDOERS_FILE="/etc/sudoers.d/lidnosleep"

./build.sh

echo "==> 停止已在运行的实例"
pkill -x LidNoSleep 2>/dev/null || true
sleep 0.3

echo "==> 安装到 $DEST"
rm -rf "$DEST"
ditto "build/LidNoSleep.app" "$DEST"

echo "==> 写入 sudoers 规则（需要输入一次管理员密码）"
USER_NAME="$(id -un)"
RULE="$USER_NAME ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0"
TMP="$(mktemp /tmp/lidnosleep.XXXXXX)"
printf '%s\n' "$RULE" > "$TMP"

# 先校验语法，通过后才安装，避免把 sudo 配置写坏
sudo /usr/sbin/visudo -cf "$TMP"
sudo /bin/chmod 0440 "$TMP"
sudo /usr/sbin/chown root:wheel "$TMP"
sudo /bin/mv -f "$TMP" "$SUDOERS_FILE"
sudo /usr/sbin/visudo -cf "$SUDOERS_FILE"

echo "==> 启动 App"
open "$DEST"

echo ""
echo "完成。菜单栏会出现月亮图标；首次授权已由本脚本完成。"
echo "如需开机自启动：点菜单栏图标 → 勾选「开机自启动」。"
