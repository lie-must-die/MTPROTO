#!/bin/bash

set -e

echo "=== Установка геоблокировки ==="

# Установка ipset если нет
if ! command -v ipset &>/dev/null; then
    echo "Устанавливаю ipset..."
    apt-get install -y -q ipset 2>/dev/null
fi

# Создаём скрипт обновления
echo "Создаю скрипт обновления геоблока..."
cat > /etc/cron.weekly/geoblock-update << 'EOF'
#!/bin/bash
COUNTRIES="pk iq ir af sa ae bd in cn id my th vn kh mm lk np bt mn kp sy ye ly dz ma tn eg jo lb kw bh om qa uz tj tm"

ipset create geoblock hash:net 2>/dev/null || ipset flush geoblock

for cc in $COUNTRIES; do
    curl -s "https://www.ipdeny.com/ipblocks/data/aggregated/${cc}-aggregated.zone" | while read cidr; do
        ipset add geoblock "$cidr" 2>/dev/null
    done
done

iptables -t raw -C PREROUTING -m set --match-set geoblock src -j DROP 2>/dev/null \
    || iptables -t raw -I PREROUTING -m set --match-set geoblock src -j DROP

ipset save geoblock > /etc/geoblock.ipset
EOF
chmod +x /etc/cron.weekly/geoblock-update

# Первый запуск
echo "Загружаю списки стран (1-2 минуты)..."
/etc/cron.weekly/geoblock-update

# Systemd сервис для автозагрузки
echo "Создаю systemd сервис..."
cat > /etc/systemd/system/geoblock.service << 'EOF'
[Unit]
Description=GeoIP block
After=network.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'ipset restore -! < /etc/geoblock.ipset && iptables -t raw -C PREROUTING -m set --match-set geoblock src -j DROP 2>/dev/null || iptables -t raw -I PREROUTING -m set --match-set geoblock src -j DROP'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl enable geoblock
systemctl start geoblock

# Алиас для ручной блокировки IP
if ! grep -q "banip" ~/.bashrc; then
    echo "" >> ~/.bashrc
    echo "# Быстрая блокировка IP" >> ~/.bashrc
    echo "alias banip='f() { iptables -t raw -I PREROUTING -s \$1 -j DROP && conntrack -D -s \$1 2>/dev/null; echo \"Banned \$1\"; }; f'" >> ~/.bashrc
    source ~/.bashrc
fi

echo ""
echo "=== Готово ==="
echo "Диапазонов загружено: $(ipset list geoblock | grep -c '/')"
echo "Сервис: $(systemctl is-active geoblock)"
echo ""
echo "Использование алиаса: banip 1.2.3.4"
