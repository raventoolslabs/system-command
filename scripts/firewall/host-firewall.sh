#!/usr/bin/env bash
# Configura la cadena "input" (tabla "inet filter") como allowlist
# explícita para los puertos de servicios propios del host — el
# equivalente de docker-user-firewall.sh pero para tráfico dirigido al
# host, no reenviado a contenedores.
#
# Por qué existe: la cadena input ya la gestiona /etc/nftables.conf con
# política DROP por defecto y unas reglas base fijas (loopback,
# conntrack, ICMP, SSH con rate-limit y un DROP final con log). Este
# script NO toca esas reglas base — solo añade/retira reglas ACCEPT por
# puerto, y únicamente las que él mismo ha creado, marcadas con el
# comentario "host-firewall". Así nunca borra una regla que no sea suya
# aunque cambie el resto del firewall.
#
# A partir de ahora: cualquier puerto NUEVO de un servicio del host queda
# bloqueado por defecto hasta que se añada a HOST_ALLOWED_PORTS en .env y
# se vuelva a ejecutar este script.
#
# Reconciliación completa: en cada ejecución, las reglas marcadas
# "host-firewall" se ajustan para coincidir exactamente con
# HOST_ALLOWED_PORTS — se añaden las que faltan, se eliminan las de
# puertos que ya no están en la lista, y las que no cambian se dejan tal
# cual. Las reglas nuevas se insertan siempre justo antes del DROP final,
# para que se evalúen antes.
#
# IMPORTANTE — riesgo de bloqueo remoto: este script modifica el firewall
# del host que probablemente incluye tu propia conexión SSH. El puerto 22
# tiene su propia regla fija con rate-limit definida en /etc/nftables.conf,
# fuera del control de este script (no la gestiona ni la toca), así que
# SSH no depende de HOST_ALLOWED_PORTS. Aun así, revisa el contenido de
# HOST_ALLOWED_PORTS antes de ejecutar, y si tienes dudas usa --dry-run
# primero para ver qué cambiaría sin aplicarlo.
#
# Formato en .env:
#   HOST_ALLOWED_PORTS="80/tcp 443/tcp"
#   (puerto o rango puerto:puerto, seguido de /tcp o /udp, separados por espacios)
# Usage: sudo ./host-firewall.sh [--dry-run]
set -uo pipefail

DRY_RUN=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        *) echo "Opción desconocida: $arg" >&2; exit 1 ;;
    esac
done

if [ "$EUID" -ne 0 ]; then
    echo "Este script debe ejecutarse con sudo (lee/modifica reglas de nftables). Abortando." >&2
    exit 1
fi

NFT="$(command -v nft || true)"
if [ -z "$NFT" ]; then
    echo "nft no está disponible en PATH. Abortando." >&2
    exit 1
fi

if ! "$NFT" list chain inet filter input >/dev/null 2>&1; then
    echo "No existe la cadena 'input' en la tabla 'inet filter'. Este script asume que /etc/nftables.conf ya la define con política DROP. Abortando." >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../../.env"
if [ -f "$ENV_FILE" ]; then
    HOST_ALLOWED_PORTS=$(grep -E '^HOST_ALLOWED_PORTS=' "$ENV_FILE" | tail -1 | cut -d= -f2- | tr -d '"' | tr -d "'")
fi
HOST_ALLOWED_PORTS="${HOST_ALLOWED_PORTS:-}"

if [ -z "$HOST_ALLOWED_PORTS" ]; then
    echo "HOST_ALLOWED_PORTS no está definido en $ENV_FILE — nada que aplicar." >&2
    exit 1
fi

# Las reglas gestionadas por este script llevan siempre este comentario,
# literalmente entrecomillado tal y como nft lo espera y lo reimprime.
COMMENT_TAG='"host-firewall"'
MARK='comment "host-firewall"'

ADDED=0
SKIPPED=0
REMOVED=0
VALID_ENTRIES=""

# proto+puerto de cada regla marcada "host-firewall" que existe ahora
# mismo en la cadena (una línea "proto puerto" por regla).
managed_pairs() {
    "$NFT" -a list chain inet filter input 2>/dev/null | grep -F "$MARK" | while IFS= read -r rule; do
        proto=$(awk '{for(i=1;i<=NF;i++) if ($i=="tcp"||$i=="udp") {print $i; exit}}' <<< "$rule")
        port=$(awk '{for(i=1;i<=NF;i++) if ($i=="dport") {print $(i+1); exit}}' <<< "$rule")
        [ -n "$proto" ] && [ -n "$port" ] && printf '%s %s\n' "$proto" "$port"
    done
}

# Handle de la última regla de la cadena (el DROP final): las reglas
# nuevas se insertan siempre justo antes, para no quedar después de una
# regla que ya captura y descarta todo el tráfico restante.
last_rule_handle() {
    "$NFT" -a list chain inet filter input 2>/dev/null | grep -oE '# handle [0-9]+' | tail -1 | awk '{print $3}'
}

EXISTING_BEFORE="$(managed_pairs)"

for entry in $HOST_ALLOWED_PORTS; do
    port="${entry%/*}"
    proto="${entry##*/}"

    if [ "$port" = "$entry" ] || { [ "$proto" != "tcp" ] && [ "$proto" != "udp" ]; }; then
        echo "Entrada inválida en HOST_ALLOWED_PORTS (esperado puerto/tcp o puerto/udp): '$entry' — se omite" >&2
        continue
    fi
    if ! printf '%s' "$port" | grep -qE '^[0-9]+(:[0-9]+)?$'; then
        echo "Puerto inválido en HOST_ALLOWED_PORTS: '$entry' — se omite" >&2
        continue
    fi

    port_nft="${port/:/-}"   # 9000:9001 -> 9000-9001 (sintaxis de rango en nft)
    pair="${proto} ${port_nft}"

    if grep -qxF "$pair" <<< "$VALID_ENTRIES"; then
        continue   # entrada duplicada dentro de HOST_ALLOWED_PORTS
    fi
    VALID_ENTRIES="${VALID_ENTRIES}${pair}
"

    if grep -qxF "$pair" <<< "$EXISTING_BEFORE"; then
        printf '[ = ]  ya existe:  %s dport %s accept\n' "$proto" "$port_nft"
        SKIPPED=$((SKIPPED + 1))
    elif [ "$DRY_RUN" -eq 1 ]; then
        printf '[+dry]  añadiría:   %s dport %s accept\n' "$proto" "$port_nft"
        ADDED=$((ADDED + 1))
    else
        handle="$(last_rule_handle)"
        if [ -z "$handle" ]; then
            echo "No se pudo localizar la regla final de la cadena — aborto para no insertar en mal orden." >&2
            exit 1
        fi
        if "$NFT" insert rule inet filter input position "$handle" "$proto" dport "$port_nft" accept comment $COMMENT_TAG; then
            printf '[ + ]  añadida:    %s dport %s accept\n' "$proto" "$port_nft"
            ADDED=$((ADDED + 1))
        else
            echo "Fallo al insertar la regla para ${proto}/${port_nft} — revisa el mensaje de nft arriba." >&2
        fi
    fi
done

# Retirar reglas "host-firewall" cuyo puerto ya no está en HOST_ALLOWED_PORTS.
# Se leen las reglas reales de la cadena (nft -a list) en vez de fiarse de
# lo que había antes, así el script converge al estado de .env
# independientemente de cómo se llegó al estado actual.
EXISTING_ENTRIES=$("$NFT" -a list chain inet filter input 2>/dev/null | grep -F "$MARK" | while IFS= read -r rule; do
    proto=$(awk '{for(i=1;i<=NF;i++) if ($i=="tcp"||$i=="udp") {print $i; exit}}' <<< "$rule")
    port=$(awk '{for(i=1;i<=NF;i++) if ($i=="dport") {print $(i+1); exit}}' <<< "$rule")
    handle=$(grep -oE '# handle [0-9]+' <<< "$rule" | awk '{print $3}')
    [ -n "$proto" ] && [ -n "$port" ] && [ -n "$handle" ] && printf '%s %s %s\n' "$proto" "$port" "$handle"
done)

if [ -n "$EXISTING_ENTRIES" ]; then
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        proto=$(awk '{print $1}' <<< "$line")
        port=$(awk '{print $2}' <<< "$line")
        handle=$(awk '{print $3}' <<< "$line")
        if ! grep -qxF "${proto} ${port}" <<< "$VALID_ENTRIES"; then
            if [ "$DRY_RUN" -eq 1 ]; then
                printf '[-dry]  eliminaría: %s dport %s accept\n' "$proto" "$port"
                REMOVED=$((REMOVED + 1))
            elif "$NFT" delete rule inet filter input handle "$handle"; then
                printf '[ - ]  eliminada:  %s dport %s accept\n' "$proto" "$port"
                REMOVED=$((REMOVED + 1))
            else
                echo "Fallo al eliminar la regla ${proto}/${port} (handle $handle) — revisa el mensaje de nft arriba." >&2
            fi
        fi
    done <<< "$EXISTING_ENTRIES"
fi

echo
if [ "$DRY_RUN" -eq 1 ]; then
    echo "[dry-run, no se aplicó nada] Reglas a añadir: $ADDED   Ya presentes: $SKIPPED   A eliminar: $REMOVED"
else
    echo "Reglas añadidas: $ADDED   Reglas ya presentes: $SKIPPED   Reglas eliminadas: $REMOVED"
fi
echo "Nota: las reglas base (loopback, established, ICMP, SSH con rate-limit y el DROP final) no las gestiona este script — viven en /etc/nftables.conf."
