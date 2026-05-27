#!/bin/bash
#=============================================================================
# WiFi Cracker TUI — 一键安装脚本
# 安装后终端输入 wifitui 即可启动
#=============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE="$SCRIPT_DIR/wifi_crack_tui.sh"

# 安装位置：优先 ~/.local/bin，其次 /usr/local/bin
if [ -d "$HOME/.local/bin" ] || mkdir -p "$HOME/.local/bin" 2>/dev/null; then
    BIN_DIR="$HOME/.local/bin"
else
    BIN_DIR="/usr/local/bin"
    [ -w "$BIN_DIR" ] || { echo "需要 sudo 来安装到 $BIN_DIR"; exit 1; }
fi
TARGET="$BIN_DIR/wifitui"

echo "WiFi Cracker TUI — 安装"
echo "========================="
echo "源文件: $SOURCE"
echo "安装到: $TARGET"
echo ""

# 检查依赖
echo -n "检查依赖 ... "
MISSING=""
for dep in nmcli wpa_supplicant wpa_cli tput bash; do
    command -v "$dep" &>/dev/null || MISSING="$MISSING $dep"
done
if [ -n "$MISSING" ]; then
    echo "缺少:$MISSING"
    echo "请先安装: sudo apt install network-manager wpasupplicant ncurses-bin"
    exit 1
fi
echo "OK"

# 复制脚本
echo -n "安装 wifitui ... "
cp "$SOURCE" "$TARGET"
chmod +x "$TARGET"
echo "OK"

# 确保在 PATH 中
if ! echo "$PATH" | grep -qF "$BIN_DIR"; then
    echo ""
    echo "注意: $BIN_DIR 不在 PATH 中"
    echo "添加到 PATH (可选):"
    echo "  echo 'export PATH=\"$BIN_DIR:\$PATH\"' >> ~/.bashrc"
    echo "  source ~/.bashrc"
fi

echo ""
echo "安装完成！"
echo "  首次运行:  wifitui"
echo "  请输入 sudo 密码 (或留空手动输入)"
echo ""
echo "  配置存储在: ~/.config/wifi-cracker/config.json"
echo "  日志文件:   /tmp/wifi_brute_found.log"
