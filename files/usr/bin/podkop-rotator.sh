#!/bin/sh

CONFIG="podkop_rotator"

log() {
    local log_file
    log_file=$(uci -q get ${CONFIG}.main.log_file || echo "/var/log/podkop-autosub.log")
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg"
    echo "$msg" >> "$log_file"
}

check_connection() {
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" --proxy http://127.0.0.1:4534 --max-time 5 https://cp.cloudflare.com/generate_204 2>/dev/null)
    [ "$code" = "204" ]
}

download_subscription() {
    local sub_url="$1"
    local cache_file="$2"
    log "[DOWNLOAD] Скачиваем свежую подписку с $sub_url..."
    if curl -sSL --max-time 15 "$sub_url" -o "$cache_file"; then
        log "[SUCCESS] Подписка успешно обновлена и сохранена в $cache_file"
        return 0
    else
        log "[ERROR] Ошибка скачивания подписки!"
        return 1
    fi
}

rotate_keys() {
    local cache_file="$1"
    local total_keys tested=0
    total_keys=$(grep -cE '^(vless|trojan|ss|vmess)://' "$cache_file" 2>/dev/null || echo 0)
    log "[INFO] Найдено ключей в кэше: $total_keys"

    if [ "$total_keys" -eq 0 ]; then
        log "[WARN] Кэш пуст или содержит мусор."
        return 1
    fi

    while IFS= read -r key || [ -n "$key" ]; do
        case "$key" in
            vless://*|trojan://*|ss://*|vmess://*) ;;
            *) continue ;;
        esac

        tested=$((tested + 1))
        log "[$tested/$total_keys] Тестируем ключ..."

        uci set podkop.main.proxy_string="$key"
        uci commit podkop
        /etc/init.d/podkop restart >/dev/null 2>&1

        sleep 3

        if check_connection; then
            log "[SUCCESS] Рабочий ключ найден и применён! (HTTP 204)"
            return 0
        else
            log "[SKIP] Ключ не прошёл проверку"
        fi
    done < "$cache_file"

    return 1
}

log "=== Запуск службы Podkop Rotator (v0.3.0) ==="

while true; do
    ENABLED=$(uci -q get ${CONFIG}.main.enabled || echo "1")
    SUB_URL=$(uci -q get ${CONFIG}.main.url)
    CACHE_FILE=$(uci -q get ${CONFIG}.main.cache_file || echo "/tmp/podkop_sub.txt")
    CHECK_INTERVAL=$(uci -q get ${CONFIG}.main.check_interval || echo "60")

    if [ "$ENABLED" -eq 1 ]; then
        if ! check_connection; then
            log "[FAIL] Соединение упало или отсутствует. Начинаем подбор..."

            if [ ! -s "$CACHE_FILE" ]; then
                download_subscription "$SUB_URL" "$CACHE_FILE"
            fi

            if ! rotate_keys "$CACHE_FILE"; then
                log "[WARN] Все ключи из кэша не сработали. Скачиваем свежую подписку..."
                if download_subscription "$SUB_URL" "$CACHE_FILE"; then
                    rotate_keys "$CACHE_FILE" || log "[FATAL] Ни один ключ из новой подписки не подошёл!"
                fi
            fi
        fi
    fi

    sleep "$CHECK_INTERVAL"
done