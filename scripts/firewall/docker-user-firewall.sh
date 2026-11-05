#!/usr/bin/env bash
# Configura la cadena DOCKER-USER como allowlist explícita de lo que se
# enruta HACIA los contenedores.
#
# Por qué existe: Docker publica puertos (-p host:cont) vía DNAT +
# reglas automáticas en FORWARD/DOCKER, que NO pasan por la cadena
# INPUT del host (tabla inet filter) y por tanto ignoran su política
# "drop". DOCKER-USER es la única cadena que Docker garantiza no tocar
# y que se evalúa ANTES de sus reglas automáticas, así que es el punto
# correcto para imponer un allowlist sobre lo que se enruta hacia
# contenedores.
#
# POR QUÉ LAS REGLAS LLEVAN "-i": DOCKER-USER cuelga de FORWARD y ve
# TODO el tráfico que atraviesa las redes de Docker, en los dos
# sentidos. Filtrando solo por --dport, el DROP final también alcanzaba
# a las conexiones que ABREN los contenedores: una salida a un
# registro en el 443 no es ESTABLISHED, no coincide con ningún puerto
# publicado y acababa descartada. El efecto era que ningún contenedor
# podía instalar dependencias ni hablar con internet —un `docker build`
# fallaba con `npm ci` colgado y `apk add` con errores de TLS—, y solo
# funcionaba lo que casualmente usara un puerto de la lista.
# Acotando cada regla a la interfaz de entrada externa, el
# allowlist se aplica a lo que llega de fuera, que es su cometido, y el
# tráfico saliente de los contenedores —que entra por docker0 o br-*—
# ni siquiera se evalúa.
#
# A partir de aquí: cualquier puerto NUEVO publicado por un contenedor
# queda bloqueado por defecto hasta que se añada a DOCKER_ALLOWED_PORTS
# en .env y se vuelva a ejecutar este script.
#
# Reconciliación completa: en cada ejecución, el estado de DOCKER-USER
# se ajusta para que coincida exactamente con lo declarado — se añaden
# las reglas que faltan, se eliminan las que sobran (incluidas las de
# versiones anteriores de este script, que no llevaban interfaz) y las
# que no cambian se dejan tal cual. Los DROP finales se recolocan
# siempre al final de la cadena.
#
# Formato en .env:
#   DOCKER_ALLOWED_PORTS="8080/tcp 8443/tcp 3000:3001/tcp"
#   (puerto o rango puerto:puerto, seguido de /tcp o /udp, separados por espacios)
#
#   DOCKER_WAN_IFACES="eth0 wg0"   (opcional)
#   Interfaces por las que llega el tráfico externo al que se aplica el
#   allowlist. Si no se define, se usa la de la ruta por defecto. Si el
#   host publica servicios también por una VPN, hay que listarla aquí:
#   lo que no aparezca queda SIN filtrar por esta cadena.
#
# Usage: sudo ./docker-user-firewall.sh
set -uo pipefail

if [ "$EUID" -ne 0 ]; then
    echo "Este script debe ejecutarse con sudo (modifica reglas de iptables). Abortando." >&2
    exit 1
fi

# Sobrescribible para poder ejercitar el script contra un netfilter de
# pruebas sin tocar el del host.
IPT="${IPT:-/usr/sbin/iptables}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../../.env"
if [ -f "$ENV_FILE" ]; then
    DOCKER_ALLOWED_PORTS=$(grep -E '^DOCKER_ALLOWED_PORTS=' "$ENV_FILE" | tail -1 | cut -d= -f2- | tr -d '"' | tr -d "'")
    ENV_WAN_IFACES=$(grep -E '^DOCKER_WAN_IFACES=' "$ENV_FILE" | tail -1 | cut -d= -f2- | tr -d '"' | tr -d "'")
fi
DOCKER_ALLOWED_PORTS="${DOCKER_ALLOWED_PORTS:-}"
DOCKER_WAN_IFACES="${DOCKER_WAN_IFACES:-${ENV_WAN_IFACES:-}}"

if [ -z "$DOCKER_ALLOWED_PORTS" ]; then
    echo "DOCKER_ALLOWED_PORTS no está definido en $ENV_FILE — nada que aplicar." >&2
    exit 1
fi

# Sin interfaces declaradas se usa la de la ruta por defecto. Si no se
# puede averiguar, se aborta en lugar de caer hacia atrás en el
# comportamiento sin "-i": ese es justo el que rompe la salida de los
# contenedores, y hacerlo en silencio sería repetir el fallo.
if [ -z "$DOCKER_WAN_IFACES" ]; then
    DOCKER_WAN_IFACES=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
fi

if [ -z "$DOCKER_WAN_IFACES" ]; then
    echo "No se ha podido determinar la interfaz externa y DOCKER_WAN_IFACES no está definido en $ENV_FILE. Abortando." >&2
    exit 1
fi

echo "Interfaces externas filtradas: $DOCKER_WAN_IFACES"
echo

ADDED=0
SKIPPED=0
REMOVED=0

# Conjunto de reglas ACCEPT que deben existir, como claves
# "interfaz|protocolo|puerto". Es contra esto contra lo que se
# reconcilia la cadena real.
DESIRED=""

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

    for iface in $DOCKER_WAN_IFACES; do
        DESIRED="${DESIRED}${iface}|${proto}|${port}
"
    done
done

# --- limpieza -------------------------------------------------------
#
# Se recorren las reglas REALES de la cadena en vez de fiarse de lo que
# hubiera antes, así el script converge al estado declarado
# independientemente de cómo se llegó al actual. Se borra por la
# especificación exacta que imprime "iptables -S", que incluye los "-m
# tcp" que iptables añade por su cuenta: reconstruirla a mano no
# coincidiría y el borrado fallaría en silencio.
while IFS= read -r line; do
    [ -z "$line" ] && continue

    spec="${line#-A DOCKER-USER }"

    # Los DROP se retiran siempre: se vuelven a poner al final, que es
    # donde tienen que estar para que los ACCEPT se evalúen antes.
    if printf '%s' "$spec" | grep -q -- '-j DROP'; then
        # shellcheck disable=SC2086
        "$IPT" -D DOCKER-USER $spec
        continue
    fi

    printf '%s' "$spec" | grep -q -- '--dport' || continue

    r_iface=$(awk '{for(i=1;i<=NF;i++) if ($i=="-i") {print $(i+1); exit}}' <<< "$spec")
    r_proto=$(awk '{for(i=1;i<=NF;i++) if ($i=="-p") {print $(i+1); exit}}' <<< "$spec")
    r_port=$(awk '{for(i=1;i<=NF;i++) if ($i=="--dport") {print $(i+1); exit}}' <<< "$spec")

    if ! grep -qxF "${r_iface}|${r_proto}|${r_port}" <<< "$DESIRED"; then
        # shellcheck disable=SC2086
        "$IPT" -D DOCKER-USER $spec
        printf '[ - ]  eliminada:  %s\n' "$spec"
        REMOVED=$((REMOVED + 1))
    fi
done <<< "$("$IPT" -S DOCKER-USER 2>/dev/null | grep -- '-A DOCKER-USER')"

# --- alta -----------------------------------------------------------

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
# respuestas de tráfico existente. Sin "-i" a propósito: vale para los
# dos sentidos.
add_rule_if_missing -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

while IFS= read -r key; do
    [ -z "$key" ] && continue
    iface="${key%%|*}"
    rest="${key#*|}"
    proto="${rest%%|*}"
    port="${rest#*|}"
    add_rule_if_missing -i "$iface" -p "$proto" --dport "$port" -j ACCEPT
done <<< "$DESIRED"

# El DROP va al final y SOLO sobre las interfaces externas. Todo lo
# demás —incluido lo que abren los propios contenedores hacia fuera—
# atraviesa la cadena sin veredicto y sigue su curso.
for iface in $DOCKER_WAN_IFACES; do
    "$IPT" -A DOCKER-USER -i "$iface" -j DROP
    printf '[ + ]  añadida:    -i %s -j DROP\n' "$iface"
done

echo
echo "Reglas añadidas: $ADDED   Reglas ya presentes: $SKIPPED   Reglas eliminadas: $REMOVED"
