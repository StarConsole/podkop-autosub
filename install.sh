#!/bin/sh

VERSION="0.2.0"
REPO_URL="https://raw.githubusercontent.com/StarConsole/podkop-autosub/main/files"

echo "=== Installing Podkop Auto-Sub Core (v${VERSION}) ==="

# 1. Скачиваем конфиг (если его еще нет)
if [ ! -f /etc/config/podkop_rotator ]; then
    echo "Downloading config..."
    curl -sSL "$REPO_URL/etc/config/podkop_rotator" -o /etc/config/podkop_rotator
else
    echo "Config /etc/config/podkop_rotator already exists, skipping."
fi

# 2. Останавливаем сервис перед перезаписью файлов
if [ -f /etc/init.d/podkop_rotator ]; then
    echo "Stopping existing service..."
    /etc/init.d/podkop_rotator stop >/dev/null 2>&1
fi

# 3. Скачиваем основной скрипт
echo "Downloading core script..."
curl -sSL "$REPO_URL/usr/bin/podkop-rotator.sh" -o /usr/bin/podkop-rotator.sh
chmod +x /usr/bin/podkop-rotator.sh

# 4. Создаем симлинк для удобного вызова через CLI
echo "Creating CLI alias (podkop-autosub)..."
ln -sf /usr/bin/podkop-rotator.sh /usr/bin/podkop-autosub

# 5. Скачиваем init-скрипт службы
echo "Downloading init service..."
curl -sSL "$REPO_URL/etc/init.d/podkop_rotator" -o /etc/init.d/podkop_rotator
chmod +x /etc/init.d/podkop_rotator

# 6. Включаем и перезапускаем службу
echo "Enabling and starting service..."
/etc/init.d/podkop_rotator enable
/etc/init.d/podkop_rotator restart

echo "=== Installation Complete! Version v${VERSION} ==="
echo "Use 'podkop-autosub help' or 'podkop-autosub version' for CLI management."