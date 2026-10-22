#!/bin/bash
# 完全卸载：退出 App、恢复正常休眠、删除 sudoers 规则、开机自启动、日志与偏好设置
set -euo pipefail

DEST="/Applications/LidNoSleep.app"

echo "==> 退出 App"
pkill -x LidNoSleep 2>/dev/null || true

echo "==> 恢复系统休眠设置（需要管理员密码）"
sudo /usr/bin/pmset -a disablesleep 0 || true
sudo /bin/rm -f /etc/sudoers.d/lidnosleep

echo "==> 删除开机自启动与文件"
/bin/rm -f "$HOME/Library/LaunchAgents/com.zcode.lidnosleep.plist"
/bin/rm -rf "$DEST"
/bin/rm -f "$HOME/Library/Logs/LidNoSleep.log"
defaults delete com.zcode.lidnosleep 2>/dev/null || true

echo "完成，已全部清理。"
