#!/bin/sh

REPO_URL="https://raw.githubusercontent.com/StarConsole/podkop-autosub/main/files"

echo "=== Installing Podkop Auto-Sub Core ==="

# 1. Скачиваем конфиг (если его еще нет)
if [ ! -f /etc/config/podkop_rotator ]; then
    echo "Downloading config..."
    curl -sSL "$REPO_URL/etc/config/podkop_rotator" -o /etc/config/podkop_rotator
else
    echo "Config /etc/config/podkop_rotator already exists, skipping."
fi

# 2. Скачиваем основной скрипт
echo "Downloading core script..."
curl -sSL "$REPO_URL/usr/bin/podkop-rotator.sh" -o /usr/bin/podkop-rotator.sh
chmod +x /usr/bin/podkop-rotator.sh

# 3. Скачиваем init-скрипт службы
echo "Downloading init service..."
curl -sSL "$REPO_URL/etc/init.d/podkop_rotator" -o /etc/init.d/podkop_rotator
chmod +x /etc/init.d/podkop_rotator

# 4. Включаем и перезапускаем службу
echo "Enabling service..."
/etc/init.d/podkop_rotator enable
/etc/init.d/podkop_rotator restart

echo "=== Installation Complete! ==="
