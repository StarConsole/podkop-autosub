#!/bin/sh

# Определяем абсолютную директорию
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Подсасываем версию из основного файла
VERSION=$(grep '^VERSION=' "$SCRIPT_DIR/files/usr/bin/podkop-rotator.sh" | cut -d'"' -f2)

echo "=== Установка podkop-autosub v${VERSION} ==="

# 1. Создаем дефолтный конфиг
if [ ! -f /etc/config/podkop_rotator ]; then
    echo "[+] Копируем конфиг по умолчанию в /etc/config/podkop_rotator"
    cp "$SCRIPT_DIR/files/etc/config/podkop_rotator" /etc/config/podkop_rotator
else
    echo "[*] Конфиг /etc/config/podkop_rotator уже существует"
fi

# 2. Копируем исполняемые файлы и выставляем права
echo "[+] Копируем скрипт и init.d сервис..."
cp "$SCRIPT_DIR/files/usr/bin/podkop-rotator.sh" /usr/bin/podkop-rotator.sh
chmod +x /usr/bin/podkop-rotator.sh

cp "$SCRIPT_DIR/files/etc/init.d/podkop_rotator" /etc/init.d/podkop_rotator
chmod +x /etc/init.d/podkop_rotator

# 3. Включение службы
/etc/init.d/podkop_rotator enable

echo "=== Установка завершена! ==="
echo "Для проверки статуса запусти: podkop-rotator.sh status"