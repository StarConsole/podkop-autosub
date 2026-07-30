#!/bin/sh

LOG_FILE="/tmp/podkop_rotator.log"
CACHE_FILE="/etc/podkop_sub_cache.txt"
TMP_LIST="/tmp/vpn_subscription.txt"
FILTERED_LIST="/tmp/vpn_filtered.txt"
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

    CURRENT_KEY=$(uci -q get podkop.main.proxy_string)
    SERVER_IP=$(echo "$CURRENT_KEY" | sed -n 's/.*@\([^:]*\):.*/\1/p')

    if [ -n "$SERVER_IP" ]; then
        PING_TIME=$(get_ping "$SERVER_IP")
        LAST_PING="${PING_TIME:-TIMEOUT}"

        if [ -z "$PING_TIME" ] || [ "$PING_TIME" -gt "$max_ping" ]; then
            LAST_REASON="Ping to $SERVER_IP is high/NA (${PING_TIME:-TIMEOUT} ms > ${max_ping} ms)"
            return 1
        fi
    fi

    # Проверка YouTube с 2 попытками для прогрева туннеля
    YT_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "https://www.youtube.com/generate_204")
    if [ "$YT_CODE" != "204" ]; then
        sleep 2
        YT_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "https://www.youtube.com/generate_204")
    fi

    if [ "$YT_CODE" != "204" ]; then
        LAST_REASON="YouTube check failed (HTTP: ${YT_CODE:-000})"
        return 1
    fi

    GEMINI_BLOCKED=$(curl -s -L --max-time 5 "https://gemini.google.com" | grep -ic "unsupported")
    if [ "$GEMINI_BLOCKED" -gt 0 ]; then
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

    # 1. Попытка обновить подписку перед ротацией
    fetch_and_cache_subscription

    # 2. Проверяем локальный кэш
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

        if [ -n "$KEY_IP" ]; then
            P_TIME=$(get_ping "$KEY_IP")
            if [ -z "$P_TIME" ] || [ "$P_TIME" -gt "$max_ping" ]; then
                log "  └─ [SKIP] Host ping failed or high (${P_TIME:-TIMEOUT} ms)"
                continue
            fi
            log "  ├─ Ping OK (${P_TIME} ms)"
        fi

        uci set podkop.main.proxy_string="$KEY"
        /etc/init.d/podkop restart >/dev/null 2>&1
        sleep 8

        if ! sing-box check -c /etc/sing-box/config.json >/dev/null 2>&1; then
            log "  └─ [FAIL] Sing-box rejected key syntax"
            continue
        fi

        if check_connection; then
            uci commit podkop
            log "=================================================="
            log "[SUCCESS] WORKING KEY FOUND AND APPLIED!"
            log "Server IP: $KEY_IP | Ping: ${LAST_PING} ms"
            log "=================================================="

            send_tg "🟢 Podkop Rotator: Успешно переключено на сервер ${KEY_IP} (Пинг: ${LAST_PING}мс)"

            # 3. Инет появился — сразу скачиваем свежайшую подписку на будущее!
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
        echo "Podkop Auto-Sub CLI Control"
        echo "Usage: podkop-autosub [command] or podkop-rotator.sh [command]"
        echo ""
        echo "Commands:"
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
log "=== Podkop Auto-Rotator Core Started ==="

# При старте служб проверяем/обновляем кэш
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
            log "Check OK | Ping: ${LAST_PING} ms"
        fi
    else
        log "Rotator disabled via UCI config."
    fi

    sleep "$INTERVAL"
done