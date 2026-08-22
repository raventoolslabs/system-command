#!/usr/bin/env bash
# Chequeo de recursos — CPU, RAM y disco del host local.
# Evalúa cada item y reporta OK/WARNING, no solo la salida cruda del comando.
# Usage: ./resource_check.sh [--cpu-warn N] [--ram-warn N] [--disk-warn N]
set -uo pipefail

CPU_WARN=85
RAM_WARN=85
DISK_WARN=85

while [ $# -gt 0 ]; do
    case "$1" in
        --cpu-warn) CPU_WARN="$2"; shift 2 ;;
        --ram-warn) RAM_WARN="$2"; shift 2 ;;
        --disk-warn) DISK_WARN="$2"; shift 2 ;;
        *) echo "Opción desconocida: $1" >&2; exit 1 ;;
    esac
done

OK_COUNT=0
WARN_COUNT=0

ok() {
    printf '[ OK ]    %s\n' "$1"
    OK_COUNT=$((OK_COUNT + 1))
}

warn() {
    printf '[WARNING] %s\n' "$1"
    WARN_COUNT=$((WARN_COUNT + 1))
}

hr() { printf '\n== %s ==\n' "$1"; }

hr "Información básica"
printf 'Host: %s\n' "$(hostname)"
printf 'Fecha: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
printf 'Uptime: %s\n' "$(uptime -p 2>/dev/null || uptime)"

hr "CPU"
CORES=$(nproc 2>/dev/null || echo 1)
printf 'Núcleos: %s\n' "$CORES"

LOAD1=$(awk '{print $1}' /proc/loadavg)
LOAD5=$(awk '{print $2}' /proc/loadavg)
LOAD15=$(awk '{print $3}' /proc/loadavg)
printf 'Load average (1/5/15 min): %s / %s / %s\n' "$LOAD1" "$LOAD5" "$LOAD15"

CPU_USE=$(awk -v l="$LOAD1" -v c="$CORES" 'BEGIN{printf "%.0f", (l/c)*100}')
if [ "$CPU_USE" -le "$CPU_WARN" ]; then
    ok "Uso de CPU (load1/núcleos): ${CPU_USE}%"
else
    warn "Uso de CPU alto (load1/núcleos): ${CPU_USE}% (umbral ${CPU_WARN}%)"
fi

printf '\nTop 5 procesos por CPU:\n'
ps -eo pid,comm,%cpu --sort=-%cpu --no-headers 2>/dev/null | head -5 \
    | awk '{printf "  PID %-8s %-20s CPU %5s%%\n", $1, $2, $3}'

hr "Memoria (RAM)"
MEM_TOTAL_KB=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
MEM_AVAIL_KB=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)
MEM_USED_KB=$((MEM_TOTAL_KB - MEM_AVAIL_KB))
MEM_USE_PCT=$(awk -v u="$MEM_USED_KB" -v t="$MEM_TOTAL_KB" 'BEGIN{printf "%.0f", (u/t)*100}')

printf 'Total: %s   Usada: %s   Disponible: %s\n' \
    "$(awk -v k="$MEM_TOTAL_KB" 'BEGIN{printf "%.1fG", k/1024/1024}')" \
    "$(awk -v k="$MEM_USED_KB" 'BEGIN{printf "%.1fG", k/1024/1024}')" \
    "$(awk -v k="$MEM_AVAIL_KB" 'BEGIN{printf "%.1fG", k/1024/1024}')"

if [ "$MEM_USE_PCT" -le "$RAM_WARN" ]; then
    ok "Uso de RAM: ${MEM_USE_PCT}%"
else
    warn "Uso de RAM alto: ${MEM_USE_PCT}% (umbral ${RAM_WARN}%)"
fi

SWAP_TOTAL_KB=$(awk '/^SwapTotal:/{print $2}' /proc/meminfo)
SWAP_FREE_KB=$(awk '/^SwapFree:/{print $2}' /proc/meminfo)
if [ "$SWAP_TOTAL_KB" -gt 0 ]; then
    SWAP_USED_KB=$((SWAP_TOTAL_KB - SWAP_FREE_KB))
    SWAP_USE_PCT=$(awk -v u="$SWAP_USED_KB" -v t="$SWAP_TOTAL_KB" 'BEGIN{printf "%.0f", (u/t)*100}')
    if [ "$SWAP_USE_PCT" -le 50 ]; then
        ok "Uso de swap: ${SWAP_USE_PCT}%"
    else
        warn "Uso de swap alto: ${SWAP_USE_PCT}%"
    fi
else
    ok "Sin swap configurado (o no en uso)"
fi

printf '\nTop 5 procesos por RAM:\n'
ps -eo pid,comm,%mem --sort=-%mem --no-headers 2>/dev/null | head -5 \
    | awk '{printf "  PID %-8s %-20s MEM %5s%%\n", $1, $2, $3}'

hr "Disco"
while read -r FS SIZE USED AVAIL PCT MOUNT; do
    PCT_NUM=${PCT%\%}
    if [ "$PCT_NUM" -le "$DISK_WARN" ]; then
        ok "$MOUNT ($FS): ${PCT} usado — ${USED}/${SIZE} (libre: $AVAIL)"
    else
        warn "$MOUNT ($FS): ${PCT} usado — ${USED}/${SIZE} (libre: $AVAIL, umbral ${DISK_WARN}%)"
    fi
done < <(df -hP -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null | tail -n +2 | awk '{print $1, $2, $3, $4, $5, $6}')

hr "Resumen"
printf 'OK: %d   WARNING: %d\n' "$OK_COUNT" "$WARN_COUNT"
