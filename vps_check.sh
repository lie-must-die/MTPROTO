#!/bin/bash

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Pre-install dependencies silently before any output
APT_PACKAGES=""

# Проверяем, чего не хватает, и собираем в список
if ! command -v sysbench &>/dev/null; then
    APT_PACKAGES="$APT_PACKAGES sysbench"
fi

if ! command -v fio &>/dev/null; then
    APT_PACKAGES="$APT_PACKAGES fio"
fi

# Если список apt-пакетов не пустой, обновляем индексы один раз и ставим всё разом
if [ -n "$APT_PACKAGES" ]; then
    echo "Устанавливаю пакеты: $APT_PACKAGES..."
    apt-get update -qq
    apt-get install -y -qq $APT_PACKAGES >/dev/null 2>&1
fi

# Установка snap-пакета (apt update для него не нужен)
if ! [ -f /snap/bin/speedtest ]; then
    echo "Устанавливаю speedtest (Ookla)..."
    snap install speedtest >/dev/null 2>&1
fi
echo ""

echo -e "${BOLD}=====================================${NC}"
echo -e "${BOLD}       VPS Quality Check             ${NC}"
echo -e "${BOLD}=====================================${NC}"
echo ""

# ---- 1. Basic info ----
echo -e "${CYAN}[INFO]${NC}"
echo "Hostname:  $(hostname)"
echo "OS:        $(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')"
echo "Kernel:    $(uname -r)"
echo "CPU:       $(grep 'model name' /proc/cpuinfo 2>/dev/null | head -1 | cut -d: -f2 | xargs)"
echo "Cores:     $(nproc)"
echo "RAM:       $(free -h | awk '/^Mem:/{print $2}')"
echo "Swap:      $(free -h | awk '/^Swap:/{print $2}')"
echo "Uptime:    $(uptime -p)"
echo ""

# ---- 2. Steal time ----
echo -e "${CYAN}[STEAL TIME - 10 sec sample]${NC}"

# Find the column index of 'st' from vmstat header
ST_COL=$(vmstat 1 1 2>/dev/null | grep -n "st" | head -1 | awk '{
    n=split($0,a," "); for(i=1;i<=n;i++) if(a[i]=="st") print i
}')

if [ -z "$ST_COL" ]; then
    # fallback: try to find st in header line
    HEADER=$(vmstat 1 1 2>/dev/null | grep " st")
    ST_COL=$(echo "$HEADER" | awk '{for(i=1;i<=NF;i++) if($i=="st") print i}')
fi

STEAL_VERDICT="SKIP"
if [ -n "$ST_COL" ] && [ "$ST_COL" -gt 0 ] 2>/dev/null; then
    STEAL_VALUES=$(vmstat 1 11 2>/dev/null | tail -10 | awk -v col="$ST_COL" '{print $col}' | grep -E '^[0-9]+$')
    if [ -n "$STEAL_VALUES" ]; then
        AVG_STEAL=$(echo "$STEAL_VALUES" | awk '{sum+=$1; count++} END {printf "%.1f", sum/count}')
        MAX_STEAL=$(echo "$STEAL_VALUES" | sort -n | tail -1)
        echo "Values:    $(echo $STEAL_VALUES | tr '\n' ' ')"
        echo "Average:   ${AVG_STEAL}%  Max: ${MAX_STEAL}%"
        STEAL_INT=${AVG_STEAL%.*}
        if [ "$STEAL_INT" -ge 20 ]; then
            echo -e "Result:    ${RED}КРИТИЧНО — сильный оверселл (avg ${AVG_STEAL}%)${NC}"
            STEAL_VERDICT="BAD"
        elif [ "$STEAL_INT" -ge 10 ]; then
            echo -e "Result:    ${YELLOW}ПЛОХО — заметный оверселл (avg ${AVG_STEAL}%)${NC}"
            STEAL_VERDICT="WARN"
        elif [ "$STEAL_INT" -ge 3 ]; then
            echo -e "Result:    ${YELLOW}УМЕРЕННО — небольшой оверселл (avg ${AVG_STEAL}%)${NC}"
            STEAL_VERDICT="WARN"
        else
            echo -e "Result:    ${GREEN}ОТЛИЧНО — оверселла нет (avg ${AVG_STEAL}%)${NC}"
            STEAL_VERDICT="OK"
        fi
    else
        echo -e "${YELLOW}Не удалось считать steal time${NC}"
    fi
else
    echo -e "${YELLOW}vmstat недоступен или не поддерживается${NC}"
fi
echo ""

# ---- 3. CPU benchmark ----
echo -e "${CYAN}[CPU BENCHMARK - 30 sec]${NC}"
CPU_VERDICT="SKIP"
if command -v sysbench &>/dev/null; then
    CORES=$(nproc)
    RESULT=$(sysbench cpu --cpu-max-prime=20000 --threads=$CORES --time=30 run 2>/dev/null)
    EPS=$(echo "$RESULT" | grep "events per second" | awk '{print $NF}')
    MIN_LAT=$(echo "$RESULT" | grep "min:" | awk '{print $NF}')
    MAX_LAT=$(echo "$RESULT" | grep "max:" | awk '{print $NF}')
    AVG_LAT=$(echo "$RESULT" | grep "avg:" | awk '{print $NF}')
    P95_LAT=$(echo "$RESULT" | grep "95th percentile" | awk '{print $NF}')
    echo "Events/sec:     $EPS"
    echo "Latency avg:    ${AVG_LAT}ms"
    echo "Latency 95th:   ${P95_LAT}ms"
    echo "Latency max:    ${MAX_LAT}ms"

    # Use 95th percentile vs avg ratio — more reliable than max/min
    P95_INT=${P95_LAT%.*}
    AVG_INT=${AVG_LAT%.*}
    if [ -n "$P95_INT" ] && [ -n "$AVG_INT" ] && [ "$AVG_INT" -gt 0 ]; then
        SPREAD=$((P95_INT / AVG_INT))
        if [ "$SPREAD" -ge 5 ]; then
            echo -e "Result:    ${RED}ПЛОХО — нестабильный CPU (p95/avg = ${SPREAD}x)${NC}"
            CPU_VERDICT="BAD"
        elif [ "$SPREAD" -ge 3 ]; then
            echo -e "Result:    ${YELLOW}УМЕРЕННО — небольшая нестабильность (p95/avg = ${SPREAD}x)${NC}"
            CPU_VERDICT="WARN"
        else
            echo -e "Result:    ${GREEN}ХОРОШО — стабильный CPU (p95/avg = ${SPREAD}x)${NC}"
            CPU_VERDICT="OK"
        fi
    else
        echo -e "Result:    ${GREEN}ХОРОШО${NC}"
        CPU_VERDICT="OK"
    fi
else
    echo -e "${YELLOW}sysbench не установлен. Установи: apt install sysbench${NC}"
fi
echo ""

# ---- 4. Disk I/O ----
echo -e "${CYAN}[DISK I/O]${NC}"
DISK_VERDICT="SKIP"

# Sequential write (dd)
DD_OUT=$(dd if=/dev/zero of=/tmp/vps_test bs=64k count=16k conv=fdatasync 2>&1)
rm -f /tmp/vps_test
DISK_LINE=$(echo "$DD_OUT" | grep -E "MB/s|GB/s" | tail -1)
DISK_MBS=$(echo "$DISK_LINE" | grep -oP '[\d.]+(?= MB/s)' | tail -1)
DISK_GBS=$(echo "$DISK_LINE" | grep -oP '[\d.]+(?= GB/s)' | tail -1)
[ -n "$DISK_GBS" ] && DISK_MBS=$(echo "$DISK_GBS * 1000" | bc 2>/dev/null || echo "1000")
echo "Sequential write: ${DISK_MBS:-?} MB/s"

# Random write 4K (fio)
RAND_IOPS=""
RAND_MBS=""
if command -v fio &>/dev/null; then
    FIO_OUT=$(fio --name=randwrite --ioengine=libaio --iodepth=16 \
        --rw=randwrite --bs=4k --size=128m --numjobs=1 \
        --runtime=10 --time_based --filename=/tmp/fio_test \
        --output-format=terse 2>/dev/null)
    rm -f /tmp/fio_test
    # terse format: field 49 = write IOPS, field 48 = write BW KB/s
    RAND_IOPS=$(echo "$FIO_OUT" | awk -F';' '{print $49}' | head -1)
    RAND_BW=$(echo "$FIO_OUT"   | awk -F';' '{print $48}' | head -1)
    if [ -n "$RAND_IOPS" ] && [ "$RAND_IOPS" -gt 0 ] 2>/dev/null; then
        RAND_MBS=$((RAND_BW / 1024))
        echo "Random write 4K: ${RAND_IOPS} IOPS (${RAND_MBS} MB/s)"
    fi
fi

# Verdict based on random write (more realistic)
if [ -n "$RAND_IOPS" ] && [ "$RAND_IOPS" -gt 0 ] 2>/dev/null; then
    if [ "$RAND_IOPS" -ge 10000 ]; then
        echo -e "Result:    ${GREEN}ОТЛИЧНО (${RAND_IOPS} IOPS)${NC}"
        DISK_VERDICT="OK"
    elif [ "$RAND_IOPS" -ge 3000 ]; then
        echo -e "Result:    ${GREEN}ХОРОШО (${RAND_IOPS} IOPS)${NC}"
        DISK_VERDICT="OK"
    elif [ "$RAND_IOPS" -ge 1000 ]; then
        echo -e "Result:    ${YELLOW}ПРИЕМЛЕМО (${RAND_IOPS} IOPS)${NC}"
        DISK_VERDICT="WARN"
    else
        echo -e "Result:    ${RED}ПЛОХО — диск перегружен (${RAND_IOPS} IOPS)${NC}"
        DISK_VERDICT="BAD"
    fi
elif [ -n "$DISK_MBS" ]; then
    DISK_INT=${DISK_MBS%.*}
    if [ "$DISK_INT" -ge 300 ]; then
        echo -e "Result:    ${GREEN}ОТЛИЧНО (seq ${DISK_MBS} MB/s)${NC}"
        DISK_VERDICT="OK"
    elif [ "$DISK_INT" -ge 150 ]; then
        echo -e "Result:    ${GREEN}ХОРОШО (seq ${DISK_MBS} MB/s)${NC}"
        DISK_VERDICT="OK"
    elif [ "$DISK_INT" -ge 80 ]; then
        echo -e "Result:    ${YELLOW}ПРИЕМЛЕМО (seq ${DISK_MBS} MB/s)${NC}"
        DISK_VERDICT="WARN"
    else
        echo -e "Result:    ${RED}ПЛОХО (seq ${DISK_MBS} MB/s)${NC}"
        DISK_VERDICT="BAD"
    fi
else
    echo -e "${YELLOW}Не удалось определить скорость${NC}"
fi
echo ""

# ---- 5. Memory ----
echo -e "${CYAN}[MEMORY]${NC}"
TOTAL_RAM=$(free -m | awk '/^Mem:/{print $2}')
USED_RAM=$(free -m | awk '/^Mem:/{print $3}')
SWAP_USED=$(free -m | awk '/^Swap:/{print $3}')
SWAP_TOTAL=$(free -m | awk '/^Swap:/{print $2}')
RAM_PCT=$((USED_RAM * 100 / TOTAL_RAM))

echo "RAM:       ${USED_RAM}M / ${TOTAL_RAM}M (${RAM_PCT}%)"
echo "Swap used: ${SWAP_USED}M / ${SWAP_TOTAL}M"

MEM_VERDICT="OK"
if [ "$SWAP_USED" -gt 500 ]; then
    echo -e "Result:    ${RED}ПЛОХО — активно используется своп (${SWAP_USED}M)${NC}"
    MEM_VERDICT="BAD"
elif [ "$RAM_PCT" -ge 90 ]; then
    echo -e "Result:    ${YELLOW}ВНИМАНИЕ — RAM почти заполнена (${RAM_PCT}%)${NC}"
    MEM_VERDICT="WARN"
else
    echo -e "Result:    ${GREEN}НОРМАЛЬНО${NC}"
fi
echo ""

# ---- 6. Network / Speedtest ----
echo -e "${CYAN}[NETWORK & SPEEDTEST]${NC}"
for host in 8.8.8.8 1.1.1.1; do
    PING=$(ping -c3 -q $host 2>/dev/null | grep rtt | awk -F'/' '{print $5}')
    if [ -n "$PING" ]; then
        echo "Ping $host:  ${PING}ms avg"
    fi
done

NET_VERDICT="SKIP"
ST_BIN=""
if [ -f /snap/bin/speedtest ]; then
    ST_BIN="/snap/bin/speedtest"
fi

if [ -n "$ST_BIN" ]; then
    echo "Запускаю speedtest..."
    ST_JSON=$($ST_BIN --accept-license --accept-gdpr --format=json 2>/dev/null)

    if [ -n "$ST_JSON" ]; then
        ST_PING=$(echo "$ST_JSON" | grep -o '"latency":[0-9.]*' | head -1 | cut -d: -f2)
        ST_DOWN=$(echo "$ST_JSON" | grep -o '"bandwidth":[0-9]*' | sed -n '1p' | cut -d: -f2)
        ST_UP=$(echo   "$ST_JSON" | grep -o '"bandwidth":[0-9]*' | sed -n '2p' | cut -d: -f2)
        ST_SERVER=$(echo "$ST_JSON" | grep -o '"name":"[^"]*' | head -1 | cut -d: -f2 | tr -d '"')
        [ -n "$ST_DOWN" ] && ST_DOWN=$((ST_DOWN / 125000))
        [ -n "$ST_UP" ]   && ST_UP=$((ST_UP / 125000))

        if [ -n "$ST_DOWN" ]; then
            echo "Server:    $ST_SERVER"
            echo "Ping:      ${ST_PING} ms"
            echo "Download:  ${ST_DOWN} Mbps"
            echo "Upload:    ${ST_UP} Mbps"

            if [ "$ST_DOWN" -ge 500 ]; then
                echo -e "Result:    ${GREEN}ОТЛИЧНО — канал широкий (${ST_DOWN} Mbps)${NC}"
                NET_VERDICT="OK"
            elif [ "$ST_DOWN" -ge 100 ]; then
                echo -e "Result:    ${GREEN}ХОРОШО (${ST_DOWN} Mbps)${NC}"
                NET_VERDICT="OK"
            elif [ "$ST_DOWN" -ge 50 ]; then
                echo -e "Result:    ${YELLOW}ПРИЕМЛЕМО (${ST_DOWN} Mbps)${NC}"
                NET_VERDICT="WARN"
            else
                echo -e "Result:    ${RED}ПЛОХО — узкий канал (${ST_DOWN} Mbps)${NC}"
                NET_VERDICT="BAD"
            fi
        else
            echo -e "${YELLOW}Speedtest не смог подключиться к серверу${NC}"
        fi
    else
        echo -e "${YELLOW}Speedtest не смог подключиться к серверу${NC}"
    fi
else
    echo -e "${YELLOW}speedtest не установлен (snap недоступен)${NC}"
fi
echo ""

# ---- SUMMARY ----
echo -e "${BOLD}=====================================${NC}"
echo -e "${BOLD}           ИТОГОВЫЙ ВЫВОД            ${NC}"
echo -e "${BOLD}=====================================${NC}"

ISSUES=0
WARNINGS=0

[ "$STEAL_VERDICT" = "BAD" ]  && { echo -e "${RED}✗ ОВЕРСЕЛЛ КРИТИЧЕСКИЙ (steal avg ${AVG_STEAL}%) — менять хостера${NC}"; ISSUES=$((ISSUES+1)); }
[ "$STEAL_VERDICT" = "WARN" ] && { echo -e "${YELLOW}⚠ Умеренный оверселл (steal avg ${AVG_STEAL}%)${NC}"; WARNINGS=$((WARNINGS+1)); }
[ "$STEAL_VERDICT" = "OK" ]   && echo -e "${GREEN}✓ Steal time в норме${NC}"

[ "$CPU_VERDICT" = "BAD" ]  && { echo -e "${RED}✗ CPU нестабилен${NC}"; ISSUES=$((ISSUES+1)); }
[ "$CPU_VERDICT" = "WARN" ] && { echo -e "${YELLOW}⚠ CPU умеренно нестабилен${NC}"; WARNINGS=$((WARNINGS+1)); }
[ "$CPU_VERDICT" = "OK" ]   && echo -e "${GREEN}✓ CPU стабилен${NC}"

[ "$DISK_VERDICT" = "BAD" ]  && { echo -e "${RED}✗ Диск медленный${NC}"; ISSUES=$((ISSUES+1)); }
[ "$DISK_VERDICT" = "WARN" ] && { echo -e "${YELLOW}⚠ Диск приемлемый но не быстрый${NC}"; WARNINGS=$((WARNINGS+1)); }
[ "$DISK_VERDICT" = "OK" ]   && echo -e "${GREEN}✓ Диск в норме${NC}"

[ "$MEM_VERDICT" = "BAD" ]  && { echo -e "${RED}✗ Нехватка RAM — активный своп${NC}"; ISSUES=$((ISSUES+1)); }
[ "$MEM_VERDICT" = "WARN" ] && { echo -e "${YELLOW}⚠ RAM почти заполнена${NC}"; WARNINGS=$((WARNINGS+1)); }
[ "$MEM_VERDICT" = "OK" ]   && echo -e "${GREEN}✓ RAM в норме${NC}"

[ "$NET_VERDICT" = "BAD" ]  && { echo -e "${RED}✗ Узкий канал${NC}"; ISSUES=$((ISSUES+1)); }
[ "$NET_VERDICT" = "WARN" ] && { echo -e "${YELLOW}⚠ Канал приемлемый но не широкий${NC}"; WARNINGS=$((WARNINGS+1)); }
[ "$NET_VERDICT" = "OK" ]   && echo -e "${GREEN}✓ Канал в норме${NC}"

echo ""
if [ "$ISSUES" -ge 2 ]; then
    echo -e "${RED}${BOLD}ВЕРДИКТ: НЕ БРАТЬ — слишком много проблем${NC}"
elif [ "$ISSUES" -eq 1 ]; then
    echo -e "${RED}${BOLD}ВЕРДИКТ: СОМНИТЕЛЬНО — есть критическая проблема${NC}"
elif [ "$WARNINGS" -ge 2 ]; then
    echo -e "${YELLOW}${BOLD}ВЕРДИКТ: С ОСТОРОЖНОСТЬЮ — несколько предупреждений${NC}"
elif [ "$WARNINGS" -eq 1 ]; then
    echo -e "${YELLOW}${BOLD}ВЕРДИКТ: ПРИЕМЛЕМО — одно замечание, мониторь под нагрузкой${NC}"
else
    echo -e "${GREEN}${BOLD}ВЕРДИКТ: ОТЛИЧНО — можно брать в прод${NC}"
fi
echo -e "${BOLD}=====================================${NC}"
