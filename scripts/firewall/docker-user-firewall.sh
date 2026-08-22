#!/usr/bin/env bash
# Configura la cadena DOCKER-USER como allowlist explícita.
#
# Por qué existe: Docker publica puertos (-p host:cont) vía DNAT +
# reglas automáticas en FORWARD/DOCKER, que NO pasan por la cadena
# INPUT del host (tabla inet filter) y por tanto ignoran su política
# "drop". DOCKER-USER es la única cadena que Docker garantiza no tocar
# y que se evalúa ANTES de sus reglas automáticas, así que es el punto
# correcto para imponer un allowlist sobre lo que se enruta hacia
# contenedores.
#
# A partir de ahora: cualquier puerto NUEVO publicado por un contenedor
# queda bloqueado por defecto hasta que se añada a DOCKER_ALLOWED_PORTS
# en .env y se vuelva a ejecutar este script.
#
# Reconciliación completa: en cada ejecución, el estado de DOCKER-USER
# se ajusta para que coincida exactamente con DOCKER_ALLOWED_PORTS —
# se añaden las reglas que faltan, se eliminan las reglas de puertos
# que ya no están en la lista, y las que no cambian se dejan tal cual.
# El DROP final se recoloca siempre al final de la cadena.
#
# Formato en .env:
#   DOCKER_ALLOWED_PORTS="53/tcp 53/udp 5432/tcp 6379/tcp 9000:9001/tcp"
#   (puerto o rango puerto:puerto, seguido de /tcp o /udp, separados por espacios)
# Usage: sudo ./docker-user-firewall.sh
set -uo pipefail

if [ "$EUID" -ne 0 ]; then
    echo "Este script debe ejecutarse con sudo (modifica reglas de iptables). Abortando." >&2
    exit 1
fi

IPT="/usr/sbin/iptables"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../../.env"
if [ -f "$ENV_FILE" ]; then
    DOCKER_ALLOWED_PORTS=$(grep -E '^DOCKER_ALLOWED_PORTS=' "$ENV_FILE" | tail -1 | cut -d= -f2- | tr -d '"' | tr -d "'")
fi
DOCKER_ALLOWED_PORTS="${DOCKER_ALLOWED_PORTS:-}"

if [ -z "$DOCKER_ALLOWED_PORTS" ]; then
    echo "DOCKER_ALLOWED_PORTS no está definido en $ENV_FILE — nada que aplicar." >&2
    exit 1
fi

ADDED=0
SKIPPED=0
REMOVED=0
VALID_ENTRIES=""

add_rule_if_missing() {
    # $@ = especificación de la regla (sin -A/-C)
    if "$IPT" -C DOCKER-USER "$@" 2>/dev/null; then
        printf '[ = ]  ya existe:  %s\n' "$*"
        SKIPPED=$((SKIPPED + 1))
    else
        "$IPT" -A DOCKER-USER "$@"
        printf '[ + ]  añadida:    %s\n' "$*"
        ADDED=$((ADDED + 1))
    fi
}

# Conexiones ya establecidas: se permiten primero, para no romper
# respuestas de tráfico existente.
add_rule_if_missing -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# Puertos/protocolos declarados en .env
for entry in $DOCKER_ALLOWED_PORTS; do
    port="${entry%/*}"
    proto="${entry##*/}"

    if [ "$port" = "$entry" ] || [ "$proto" != "tcp" ] && [ "$proto" != "udp" ]; then
        echo "Entrada inválida en DOCKER_ALLOWED_PORTS (esperado puerto/tcp o puerto/udp): '$entry' — se omite" >&2
        continue
    fi
    if ! printf '%s' "$port" | grep -qE '^[0-9]+(:[0-9]+)?$'; then
        echo "Puerto inválido en DOCKER_ALLOWED_PORTS: '$entry' — se omite" >&2
        continue
    fi

    VALID_ENTRIES="${VALID_ENTRIES}${port}/${proto}
"
    add_rule_if_missing -p "$proto" --dport "$port" -j ACCEPT
done

# Retirar reglas de puertos que ya no están en DOCKER_ALLOWED_PORTS.
# Se leen las reglas reales de la cadena (iptables -S) en vez de fiarse
# de lo que había antes, así el script converge al estado de .env
# independientemente de cómo se llegó al estado actual.
EXISTING_ENTRIES=$("$IPT" -S DOCKER-USER 2>/dev/null | grep -- '--dport' | while IFS= read -r rule; do
    proto=$(awk '{for(i=1;i<=NF;i++) if ($i=="-p") {print $(i+1); exit}}' <<< "$rule")
    port=$(awk '{for(i=1;i<=NF;i++) if ($i=="--dport") {print $(i+1); exit}}' <<< "$rule")
    [ -n "$proto" ] && [ -n "$port" ] && printf '%s/%s\n' "$port" "$proto"
done)

if [ -n "$EXISTING_ENTRIES" ]; then
    while IFS= read -r entry; do
        [ -z "$entry" ] && continue
        if ! grep -qxF "$entry" <<< "$VALID_ENTRIES"; then
            port="${entry%/*}"
            proto="${entry##*/}"
            "$IPT" -D DOCKER-USER -p "$proto" --dport "$port" -j ACCEPT
            printf '[ - ]  eliminada:  -p %s --dport %s -j ACCEPT\n' "$proto" "$port"
            REMOVED=$((REMOVED + 1))
        fi
    done <<< "$EXISTING_ENTRIES"
fi

# El DROP final debe quedar siempre al final de la cadena (para que las
# reglas ACCEPT de arriba, incluidas las recién añadidas, se evalúen
# antes). Se elimina cualquier instancia existente y se vuelve a añadir
# al final; esto no cambia el efecto, solo su posición.
while "$IPT" -C DOCKER-USER -j DROP 2>/dev/null; do
    "$IPT" -D DOCKER-USER -j DROP
done
"$IPT" -A DOCKER-USER -j DROP

echo
echo "Reglas añadidas: $ADDED   Reglas ya presentes: $SKIPPED   Reglas eliminadas: $REMOVED"
