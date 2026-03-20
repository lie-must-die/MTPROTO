# MTProto Proxy — полная установка на Ubuntu 24

## Шаг 1 — Обновление системы

```bash
apt update && apt upgrade -y
```

---

## Шаг 2 — Установка зависимостей

```bash
apt install -y python3 git
pip install cryptography uvloop --break-system-packages
git clone https://github.com/alexbers/mtprotoproxy /root/mtprotoproxy
```

---

## Шаг 3 — Регистрация AD_TAG в @MTProxybot

1. Открыть [@MTProxybot](https://t.me/MTProxybot)
2. Отправить `/newproxy`
3. Указать `IP:443`
4. Отправить чистый секрет без префиксов — 32 hex символа

Команда для генерации:
```bash
python3 -c "import secrets; print(secrets.token_hex(16))"
```
5. Получить AD_TAG → вставить в config.py

---

## Шаг 4 — Конфиг

```bash
cat > /root/mtprotoproxy/config.py << 'EOF'
PORT = 443

USERS = {
    "user1": "123"  # заменить на свой секрет, который сгенерировали в шаге 3: python3 -c "import secrets; print(secrets.token_hex(16))"
}

AD_TAG = "122"  # вставить секрет из пункта выше в @MTProxybot, получить тег и заменить на свой

TLS_DOMAIN = "rijksoverheid.nl"  # нужен только чтобы не было warning, tls отключён (домен лучше брать из той же локации, где серв)

TO_CLT_BUFSIZE = 262144  # для серверов с 4GB+ RAM
TO_TG_BUFSIZE = 262144

MODES = {
    "classic": False,
    "secure": True,
    "tls": False,
}
EOF
```

---

## Шаг 5 — systemd (в примере два процесса на два ядра)

```bash
cat > /etc/systemd/system/mtproxy.service << 'EOF'
[Unit]
Description=MTProto Proxy
After=network.target

[Service]
Type=simple
WorkingDirectory=/root/mtprotoproxy
ExecStart=/usr/bin/python3 /root/mtprotoproxy/mtprotoproxy.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/mtproxy2.service << 'EOF'
[Unit]
Description=MTProto Proxy 2
After=network.target

[Service]
Type=simple
WorkingDirectory=/root/mtprotoproxy
ExecStart=/usr/bin/python3 /root/mtprotoproxy/mtprotoproxy.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now mtproxy mtproxy2
```

> Если сервер одноядерный — второй сервис не нужен, только mtproxy.

---

## Шаг 6 — sysctl оптимизации

```bash
cat > /etc/sysctl.d/99-mtproxy.conf << 'EOF'
# IPv6 — отключить (убирает зависание при старте)
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1

# TCP буферы
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864

# BBR congestion control
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# Очереди соединений
net.core.somaxconn = 131072
net.ipv4.tcp_max_syn_backlog = 131072

# TIME_WAIT оптимизация
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15

# Low latency
net.ipv4.tcp_low_latency = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
EOF

sysctl -p /etc/sysctl.d/99-mtproxy.conf
```

---

## Шаг 7 — DNS (Cloudflare, убрать Google)

```bash
cat > /etc/systemd/resolved.conf << 'EOF'
[Resolve]
DNS=1.1.1.1 1.0.0.1
FallbackDNS=1.1.1.1
DNSOverTLS=yes
DNSSEC=no
EOF

systemctl restart systemd-resolved
```

> **Важно:** не трогать `/etc/systemd/network/` — это сломает сеть.

---

## Шаг 8 — Firewall, если есть

```bash
ufw allow 22/tcp
ufw allow 443/tcp
ufw enable
```

---

## Шаг 9 — Проверка

```bash
# Оба процесса живые
systemctl status mtproxy mtproxy2 --no-pager

# Логи
journalctl -u mtproxy -u mtproxy2 -f

# Порт слушает
ss -tlnp | grep 443

# sysctl применился
sysctl net.core.somaxconn
sysctl net.ipv4.tcp_congestion_control
```

---

## Ссылка для пользователей

```
tg://proxy?server=IP&port=443&secret=dd<HEX_SECRET>
```

Готовую ссылку mtprotoproxy выводит в лог при старте.

---

## Мониторинг

```bash
# Живые логи (статистика раз в 10 минут)
journalctl -u mtproxy -u mtproxy2 -f

# Активные подключения
ss -tnp | grep :443 | wc -l

# CPU/RAM процессов
ps aux | grep mtprotoproxy
```

---

## Заметки

- **Два процесса** нужны только если сервер многоядерный
- **TO_CLT/TG_BUFSIZE = 262144** только для серверов с 4GB+ RAM, на 1GB оставить дефолт или 65536
- **TLS режим** добавляет ~100-150мс пинга, включать только если провайдер режет MTProto по DPI
