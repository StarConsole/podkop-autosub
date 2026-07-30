#!/bin/sh

VERSION="0.2.1-debug"
LOG_FILE="/tmp/podkop_rotator.log"
CACHE_FILE="/etc/podkop_sub_cache.txt"
TMP_LIST="/tmp/vpn_subscription.txt"
FILTERED_LIST="/tmp/vpn_filtered.txt"
CURL_ERR_LOG="/tmp/podkop_curl_err.log"
LAST_REASON="Unknown"
LAST_PING="N/A"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

send_tg() {
    local message="$1"
    local tg_enabled=$(uci -q get podkop_rotator.main.tg_notifications)
    local token=$(uci -q get podkop_rotator.main.tg_token)
    local chat_id=$(uci -q get podkop_rotator.main.tg_chat_id)

    if [ "$tg_enabled" = "1" ] && [ -n "$token" ] && [ -n "$chat_id" ]; then
        curl -s -X POST "https://api.telegram.org/bot${token}/sendMessage" \
             -d "chat_id=${chat_id}" \
             -d "text=${message}" >/dev/null 2>&1 &
    fi
}

get_ping() {
    local ip="$1"
    local res=$(ping -c 2 -W 2 "$ip" 2>/dev/null | grep -oE "time=[0-9.]+" | head -n 1 | cut -d'=' -f2 | cut -d'.' -f1)
    echo "$res"
}

check_connection() {
    local max_ping=$(uci -q get podkop_rotator.main.max_ping || echo 500)

    # 1. Детектим SOCKS-порт Sing-box
    local proxy_port=$(grep -oE '"(listen_)?port":\s*[0-9]+' /etc/sing-box/config.json 2>/dev/null | head -n 1 | awk -F':' '{print $2}' | tr -d ' ')
    proxy_port="${proxy_port:-2080}"
    log "  ├─ [DEBUG] Detected SOCKS5 port: ${proxy_port}"

    # 2. Проверяем статус sing-box
    local sb_pid=$(pgrep sing-box | head -n 1)
    if [ -z "$sb_pid" ]; then
        log "  ├─ [DEBUG-ERROR] sing-box process is NOT running!"
        LAST_REASON="sing-box daemon is dead"
        return 1
    else
        log "  ├─ [DEBUG] sing-box process alive (PID: ${sb_pid})"
    fi

    # 3. Делаем запрос к YouTube через SOCKS5 и фиксируем stderr от curl
    rm -f "$CURL_ERR_LOG"
    local res=$(curl -s -4 -x "socks5h://127.0.0.1:${proxy_port}" -o /dev/null -w "%{http_code}:%{time_total}" --max-time 6 "https://www.youtube.com/generate_204" 2>"$CURL_ERR_LOG")
    local yt_code=$(echo "$res" | cut -d':' -f1)
    local time_sec=$(echo "$res" | cut -d':' -f2)
    local curl_err=$(cat "$CURL_ERR_LOG" | tr '\n' ' ' | sed 's/  */ /g')

    log "  ├─ [DEBUG] YouTube response: HTTP=${yt_code:-000} | Time=${time_sec:-0.00}s"
    if [ -n "$curl_err" ]; then
        log "  ├─ [DEBUG-CURL-ERR] $curl_err"
    fi

    if [ "$yt_code" != "204" ] || [ -z "$time_sec" ]; then
        LAST_REASON="YouTube check failed (HTTP: ${yt_code:-000}, err: ${curl_err:-none})"
        LAST_PING="TIMEOUT"
        return 1
    fi

    # Замер задержки туннеля
    local ping_ms=$(echo "$time_sec" | awk '{print int($1 * 1000)}')
    LAST_PING="${ping_ms}"
    log "  ├─ [DEBUG] Tunnel latency: ${ping_ms} ms"

    if [ "$ping_ms" -gt "$max_ping" ]; then
        LAST_REASON="Tunnel ping too high (${ping_ms} ms > ${max_ping} ms)"
        return 1
    fi

    # 4. Проверяем Gemini
    rm -f "$CURL_ERR_LOG"
    local gemini_raw=$(curl -s -4 -x "socks5h://127.0.0.1:${proxy_port}" -L --max-time 6 "https://gemini.google.com" 2>"$CURL_ERR_LOG")
    local gemini_blocked=$(echo "$gemini_raw" | grep -ic "unsupported")
    local g_curl_err=$(cat "$CURL_ERR_LOG" | tr '\n' ' ' | sed 's/  */ /g')

    log "  ├─ [DEBUG] Gemini check: blocked_matches=${gemini_blocked}"
    if [ -n "$g_curl_err" ]; then
        log "  ├─ [DEBUG-GEMINI-ERR] $g_curl_err"
    fi

    if [ "$gemini_blocked" -gt 0 ]; then
        LAST_REASON="Gemini is region-blocked"
        return 1
    fi

    return 0
}

fetch_and_cache_subscription() {
    local sub_url=$(uci -q get podkop_rotator.main.sub_url)

    if [ -z "$sub_url" ]; then
        log "[ERROR] Subscription URL is empty in UCI config!"
        return 1
    fi

    log "[DEBUG] Downloading subscription from: $sub_url"
    curl -sL --max-time 10 "$sub_url" > "$TMP_LIST"

    if [ ! -s "$TMP_LIST" ]; then
        log "[WARNING] Could not download fresh subscription from network."
        return 1
    fi

    grep -E "^vless://" "$TMP_LIST" | \
    grep -vE "type=(xhttp|splithttp|quic|kcp|http)" | \
    grep -E "security=(tls|reality)" > "$CACHE_FILE"

    rm -f "$TMP_LIST"
    local total=$(wc -l < "$CACHE_FILE")
    log "Subscription cache updated. Saved $total valid keys to $CACHE_FILE"
    return 0
}

rotate_keys() {
    local max_ping=$(uci -q get podkop_rotator.main.max_ping || echo 500)

    log ">>> Starting server rotation sequence..."

    fetch_and_cache_subscription

    if [ ! -s "$CACHE_FILE" ]; then
        log "[ERROR] No cached keys available in $CACHE_FILE and network download failed!"
        send_tg "🔴 Podkop Rotator: Нет доступа к подписке и локальный кэш пуст!"
        return 1
    fi

    cp "$CACHE_FILE" "$FILTERED_LIST"
    TOTAL_KEYS=$(wc -l < "$FILTERED_LIST")
    log "Using key cache (total candidates: $TOTAL_KEYS)..."

    COUNTER=0

    while read -r KEY; do
        [ -z "$KEY" ] && continue
        COUNTER=$((COUNTER + 1))

        KEY_IP=$(echo "$KEY" | sed -n 's/.*@\([^:]*\):.*/\1/p')
        log "[$COUNTER/$TOTAL_KEYS] Testing candidate (IP: ${KEY_IP:-unknown})..."

        # 1. ICMP-Пинг до сервера
        if [ -n "$KEY_IP" ]; then
            P_TIME=$(get_ping "$KEY_IP")
            log "  ├─ [DEBUG] Direct ICMP Ping to $KEY_IP: ${P_TIME:-TIMEOUT} ms"
            if [ -z "$P_TIME" ] || [ "$P_TIME" -gt "$max_ping" ]; then
                log "  └─ [SKIP] Host ping failed or high (${P_TIME:-TIMEOUT} ms > ${max_ping} ms)"
                continue
            fi
        fi

        log "  ├─ [DEBUG] Applying proxy_string to UCI..."
        uci set podkop.main.proxy_string="$KEY"

        log "  ├─ [DEBUG] Restarting /etc/init.d/podkop..."
        /etc/init.d/podkop restart >/dev/null 2>&1
        sleep 4

        # Проверка синтаксиса Sing-box
        local sb_check_out=$(sing-box check -c /etc/sing-box/config.json 2>&1)
        if [ $? -ne 0 ]; then
            log "  └─ [FAIL] Sing-box rejected key syntax: ${sb_check_out}"
            continue
        fi

        if check_connection; then
            uci commit podkop
            log "=================================================="
            log "[SUCCESS] WORKING KEY FOUND AND APPLIED!"
            log "Server IP: $KEY_IP | Tunnel Ping: ${LAST_PING} ms"
            log "=================================================="

            send_tg "🟢 Podkop Rotator: Успешно переключено на сервер ${KEY_IP} (Пинг: ${LAST_PING}мс)"

            log "Connection restored! Fetching latest subscription for offline cache..."
            fetch_and_cache_subscription

            rm -f "$FILTERED_LIST"
            return 0
        else
            log "  └─ [FAIL] Network check failed: $LAST_REASON"
        fi

    done < "$FILTERED_LIST"

    log "[WARNING] No working keys found in the entire list"
    send_tg "🔴 Podkop Rotator: Не удалось найти рабочий ключ из списка!"
    rm -f "$FILTERED_LIST"
    return 1
}

# --- CLI Handling ---
case "$1" in
    version|--version|-v)
        echo "Podkop Auto-Sub v${VERSION}"
        exit 0
        ;;
    log)
        exec tail -f "$LOG_FILE"
        ;;
    start)
        /etc/init.d/podkop_rotator start
        exit 0
        ;;
    stop)
        /etc/init.d/podkop_rotator stop
        exit 0
        ;;
    restart)
        /etc/init.d/podkop_rotator restart
        exit 0
        ;;
    subupdate)
        log "Manual subscription update requested."
        fetch_and_cache_subscription
        exit 0
        ;;
    update)
        log "Self-update sequence initiated..."
        curl -sSL https://raw.githubusercontent.com/StarConsole/podkop-autosub/main/install.sh | sh
        log "Self-update complete!"
        exit 0
        ;;
    help|--help|-h)
        echo "Podkop Auto-Sub v${VERSION}"
        echo "Usage: podkop-autosub [command] or podkop-rotator.sh [command]"
        echo ""
        echo "Commands:"
        echo "  version     - Show version"
        echo "  log         - Real-time rotator log stream"
        echo "  start       - Start background daemon"
        echo "  stop        - Stop background daemon"
        echo "  restart     - Restart daemon"
        echo "  subupdate   - Force fetch and cache latest subscription"
        echo "  update      - Re-run installer from GitHub main branch"
        echo "  help        - Show this help message"
        exit 0
        ;;
esac

# --- Daemon Mode ---
log "=== Podkop Auto-Rotator Core Started (v${VERSION}) ==="

if [ ! -s "$CACHE_FILE" ]; then
    fetch_and_cache_subscription
fi

while true; do
    ENABLED=$(uci -q get podkop_rotator.main.enabled || echo 1)
    INTERVAL=$(uci -q get podkop_rotator.main.check_interval || echo 180)

    if [ "$ENABLED" = "1" ]; then
        if ! check_connection; then
            log "Trigger: Connection test failed ($LAST_REASON)"
            send_tg "⚠️ Podkop Rotator: Зафиксирован отвал связи (${LAST_REASON}). Запускаю ротацию..."
            rotate_keys
        else
            log "Check OK | Tunnel Ping: ${LAST_PING} ms"
        fi
    else
        log "Rotator disabled via UCI config."
    fi

    sleep "$INTERVAL"
done