#!/bin/sh

# Определяем абсолютную директорию, где находится сам install.sh
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Установка podkop-autosub v0.3.0 ==="

# 1. Создаем дефолтный конфиг, если его нет
if [ ! -f /etc/config/podkop_rotator ]; then
    echo "[+] Копируем конфиг по умолчанию в /etc/config/podkop_rotator"
    cp "$SCRIPT_DIR/files/etc/config/podkop_rotator" /etc/config/podkop_rotator
else
    echo "[*] Конфиг /etc/config/podkop_rotator уже существует, сохраняем пользовательские настройки"
fi

# 2. Копируем исполняемые файлы и выставляем права
echo "[+] Копируем скрипт и init.d сервис..."
cp "$SCRIPT_DIR/files/usr/bin/podkop-rotator.sh" /usr/bin/podkop-rotator.sh
chmod +x /usr/bin/podkop-rotator.sh

cp "$SCRIPT_DIR/files/etc/init.d/podkop_rotator" /etc/init.d/podkop_rotator
chmod +x /etc/init.d/podkop_rotator

# 3. Включение службы в автозагрузку
/etc/init.d/podkop_rotator enable

echo "=== Установка завершена! ==="
echo "Для ручной проверки запусти: /usr/bin/podkop-rotator.sh"