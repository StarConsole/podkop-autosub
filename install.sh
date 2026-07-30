#!/bin/sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_RAW="https://raw.githubusercontent.com/StarConsole/podkop-autosub/main"

# Если локальной папки files нет, качаем подкоповский скрипт во временный файл
if [ -f "$SCRIPT_DIR/files/usr/bin/podkop-rotator.sh" ]; then
    VERSION=$(grep '^VERSION=' "$SCRIPT_DIR/files/usr/bin/podkop-rotator.sh" | cut -d'"' -f2)
else
    curl -sSL "$REPO_RAW/files/usr/bin/podkop-rotator.sh" -o /tmp/podkop-rotator.sh
    VERSION=$(grep '^VERSION=' /tmp/podkop-rotator.sh | cut -d'"' -f2)
fi

echo "=== Установка podkop-autosub v${VERSION} ==="

# 1. Конфиг
if [ ! -f /etc/config/podkop_rotator ]; then
    echo "[+] Копируем конфиг по умолчанию..."
    if [ -f "$SCRIPT_DIR/files/etc/config/podkop_rotator" ]; then
        cp "$SCRIPT_DIR/files/etc/config/podkop_rotator" /etc/config/podkop_rotator
    else
        curl -sSL "$REPO_RAW/files/etc/config/podkop_rotator" -o /etc/config/podkop_rotator
    fi
else
    echo "[*] Конфиг /etc/config/podkop_rotator уже существует"
fi

# 2. Исполняемые файлы
echo "[+] Копируем скрипт и init.d сервис..."
if [ -f "$SCRIPT_DIR/files/usr/bin/podkop-rotator.sh" ]; then
    cp "$SCRIPT_DIR/files/usr/bin/podkop-rotator.sh" /usr/bin/podkop-rotator.sh
else
    cp /tmp/podkop-rotator.sh /usr/bin/podkop-rotator.sh
    rm -f /tmp/podkop-rotator.sh
fi
chmod +x /usr/bin/podkop-rotator.sh

if [ -f "$SCRIPT_DIR/files/etc/init.d/podkop_rotator" ]; then
    cp "$SCRIPT_DIR/files/etc/init.d/podkop_rotator" /etc/init.d/podkop_rotator
else
    curl -sSL "$REPO_RAW/files/etc/init.d/podkop_rotator" -o /etc/init.d/podkop_rotator
fi
chmod +x /etc/init.d/podkop_rotator

# 3. Включение службы
/etc/init.d/podkop_rotator enable

echo "=== Установка завершена! ==="
echo "Для проверки статуса запусти: podkop-rotator.sh status"