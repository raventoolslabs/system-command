#!/usr/bin/env bash
# docker/debian/run-simulation.sh
#
# Orquesta el ciclo completo: build+up -> esperar systemd -> aprovisionar
# estado roto -> security_check.sh (ANTES) -> fix_security.sh -> demo del
# bug DOCKER-USER (roto -> recuperación en dos pasos) -> security_check.sh
# (DESPUÉS) -> resumen PASS/FAIL.
#
# Usage: ./run-simulation.sh [--reset] [--keep-up] [--allow-egress]
#   --reset         docker compose down -v --remove-orphans antes de empezar
#                   (contenedor 100% nuevo, repite el experimento desde cero)
#   --keep-up       no apaga el contenedor al terminar (por defecto SÍ se
#                   apaga con "docker compose down", para dejar el host limpio)
#   --allow-egress  inserta TEMPORALMENTE, en el DOCKER-USER del HOST real
#                   (no del contenedor — ver README, "Limitación conocida"),
#                   una regla que permite salida nueva desde cualquier
#                   contenedor Docker del host hacia fuera de las subredes de
#                   contenedores. Se quita siempre al terminar (trap), tanto
#                   si el script acaba bien como si falla. Necesita sudo sin
#                   contraseña para "iptables -I/-D DOCKER-USER ..." — si no
#                   lo tienes, el script avisa y sigue sin la regla (los
#                   apartados fail2ban/clamav/ntp seguirán en WARNING).
#                   Afecta a TODOS los contenedores del host mientras esté
#                   activa, no solo al del simulador — por eso es opt-in y de
#                   ventana lo más corta posible.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

SVC=debian
REPO_C=/opt/code/system-command
SEC_CHECK="$REPO_C/scripts/check/security_check.sh"
FIX_SEC="$REPO_C/scripts/maintenance/fix_security.sh"
LOGDIR=./logs
mkdir -p "$LOGDIR"

# Regla temporal de salida (host real, ver arriba). Coincide con la que
# queda documentada en el README principal como posible arreglo permanente.
EGRESS_RULE=(-m conntrack --ctstate NEW -s 172.16.0.0/12 ! -d 172.16.0.0/12 -j ACCEPT)

RESET=0; KEEP_UP=0; ALLOW_EGRESS=0
for arg in "$@"; do
    case "$arg" in
        --reset) RESET=1 ;;
        --keep-up) KEEP_UP=1 ;;
        --allow-egress) ALLOW_EGRESS=1 ;;
        *) echo "Opción desconocida: $arg" >&2; exit 1 ;;
    esac
done

dc()   { docker compose "$@"; }
dcex() { dc exec -T "$SVC" "$@"; }

EGRESS_OPEN=0
EGRESS_USED=0   # a diferencia de EGRESS_OPEN, no se reinicia al cerrar — indica
                # si hubo salida real durante fail2ban/clamav/ntp, para saber si
                # esos apartados deben exigirse en el resumen final.
egress_open() {
    [ "$ALLOW_EGRESS" -eq 1 ] || return 0
    echo "== Abriendo temporalmente salida a internet para contenedores (DOCKER-USER del host) =="
    if sudo iptables -I DOCKER-USER 1 "${EGRESS_RULE[@]}" 2>&1; then
        EGRESS_OPEN=1
        EGRESS_USED=1
    else
        echo "AVISO: no se pudo insertar la regla temporal (¿sudo sin contraseña configurado?) — sigo sin ella." >&2
    fi
}
egress_close() {
    [ "$EGRESS_OPEN" -eq 1 ] || return 0
    echo "== Cerrando la salida temporal (DOCKER-USER del host, vuelta al estado original) =="
    sudo iptables -D DOCKER-USER "${EGRESS_RULE[@]}" 2>&1 || echo "AVISO: no se pudo quitar la regla temporal — revísalo a mano con: sudo iptables -D DOCKER-USER ${EGRESS_RULE[*]}" >&2
    EGRESS_OPEN=0
}

cleanup() {
    egress_close
    if [ "$KEEP_UP" -eq 0 ]; then
        echo "== Apagando el simulador =="
        dc down
    else
        echo "== Contenedor dejado arriba (--keep-up). Apágalo con: docker compose down =="
    fi
}
trap cleanup EXIT

[ "$RESET" -eq 1 ] && { echo "== --reset: eliminando estado previo =="; dc down -v --remove-orphans; }

echo "== 1/7: build + up =="
dc up -d --build

echo "== 2/7: esperando a systemd, ssh y nftables =="
ready=0; state=""
for i in $(seq 1 60); do
    state=$(dcex systemctl is-system-running 2>/dev/null || true)
    if { [ "$state" = "running" ] || [ "$state" = "degraded" ]; } \
        && dcex systemctl is-active --quiet ssh \
        && dcex systemctl is-active --quiet nftables; then
        ready=1; break
    fi
    sleep 2
done
if [ "$ready" -ne 1 ]; then
    echo "systemd/ssh/nftables no llegaron a estar listos a tiempo (is-system-running: $state)" >&2
    dcex systemctl --failed || true
    exit 1
fi
echo "Sistema listo (is-system-running: $state)"

echo "== 3/7: aprovisionando estado roto =="
dcex bash "$REPO_C/docker/debian/provision-broken-state.sh" | tee "$LOGDIR/01-provision.log"

echo "== 4/7: security_check.sh ANTES de fix_security.sh =="
dcex env SUDO_USER=testuser "$SEC_CHECK" > "$LOGDIR/02-security_check-before.log" 2>&1 || true
BEFORE_WARN=$(grep -oE 'WARNING: [0-9]+' "$LOGDIR/02-security_check-before.log" | grep -oE '[0-9]+')
cat "$LOGDIR/02-security_check-before.log"
echo ">>> WARNINGs ANTES: $BEFORE_WARN"

echo "== 5/7: fix_security.sh — primer intento (DOCKER-USER sigue roto a propósito) =="
dcex "$FIX_SEC" firewall > "$LOGDIR/03a-fix_security-firewall-attempt1.log" 2>&1 || true
cat "$LOGDIR/03a-fix_security-firewall-attempt1.log"
# NO nos fiamos del mensaje "[ + ] arreglado"/"FALLÓ" de fix_security.sh para
# este apartado: docker-user-firewall.sh no tiene "set -e" y su última
# instrucción es un "echo" que siempre sale con éxito, así que su código de
# salida (y por tanto lo que fix_security.sh reporta) NO refleja si los
# iptables de dentro fallaron o no — es un hallazgo real del propio script,
# no algo del simulador. Por eso se comprueba el estado REAL de DOCKER-USER
# en vez de creer el mensaje.
if dcex iptables -S DOCKER-USER > /dev/null 2>&1; then
    ATTEMPT1_STILL_BROKEN=0
    echo ">>> INESPERADO: DOCKER-USER existe tras el primer intento (no debería, la tabla se borró en el flush)" >&2
else
    ATTEMPT1_STILL_BROKEN=1
    echo ">>> Como se esperaba: DOCKER-USER sigue sin existir — docker-user-firewall.sh no puede recrear la tabla,"
    echo "    aunque fix_security.sh haya podido reportarlo como '[ + ] arreglado' (ver nota en el resumen final)."
fi

egress_open
dcex env SUDO_USER=testuser "$FIX_SEC" fail2ban updates autoupdates clamav ntp ssh perms \
    > "$LOGDIR/03b-fix_security-rest.log" 2>&1 || true
cat "$LOGDIR/03b-fix_security-rest.log"

echo "== 6/7: recuperación en dos pasos (igual que en el README) =="
echo "--- paso A: simular 'reiniciar Docker' (recrea la cadena DOCKER-USER) ---"
dcex iptables -N DOCKER-USER
echo "--- paso B: volver a correr el apartado firewall ---"
dcex "$FIX_SEC" firewall > "$LOGDIR/04-fix_security-firewall-retry.log" 2>&1
cat "$LOGDIR/04-fix_security-firewall-retry.log"
DOCKER_USER_AFTER=$(dcex iptables -S DOCKER-USER)
echo "$DOCKER_USER_AFTER"
if echo "$DOCKER_USER_AFTER" | grep -qE -- '-A DOCKER-USER( -i [^ ]+)? -j DROP'; then
    DOCKERUSER_FIXED=1
else
    DOCKERUSER_FIXED=0
fi

echo "== 7/7: security_check.sh DESPUÉS =="
dcex env SUDO_USER=testuser "$SEC_CHECK" > "$LOGDIR/05-security_check-after.log" 2>&1 || true
AFTER_WARN=$(grep -oE 'WARNING: [0-9]+' "$LOGDIR/05-security_check-after.log" | grep -oE '[0-9]+')
cat "$LOGDIR/05-security_check-after.log"
echo ">>> WARNINGs DESPUÉS: $AFTER_WARN"
egress_close

# ---- Chequeos itemizados deterministas (no dependen de red) — bloquean el PASS ----
declare -A ITEMS=(
    ["MaxAuthTries limitado"]="SSH: MaxAuthTries limitado"
    ["PermitEmptyPasswords"]="SSH: contraseñas vacías deshabilitadas"
    ["permisos ~/.ssh"]="Permisos de ~/.ssh correctos (700)"
    ["permisos authorized_keys"]="Permisos de authorized_keys correctos"
    ["permisos home"]="Directorios home sin acceso de otros usuarios"
)
ITEM_FAIL=0
for label in "${!ITEMS[@]}"; do
    if grep -q "${ITEMS[$label]}" "$LOGDIR/05-security_check-after.log"; then
        echo "[ OK ] $label"
    else
        echo "[FAIL] $label"
        ITEM_FAIL=1
    fi
done

# ---- Apartados que dependen de salida a internet del CONTENEDOR (apt-get
# install fail2ban/clamav). Con --allow-egress ya no hay excusa de red, así
# que se exigen igual que el resto; sin --allow-egress son solo informativos
# y no bloquean el PASS (ver "Limitación conocida" en el README principal). ----
declare -A NET_ITEMS=(
    ["fail2ban activo"]="fail2ban activo"
    ["ClamAV instalado"]="ClamAV está instalado"
)
for label in "${!NET_ITEMS[@]}"; do
    if grep -q "${NET_ITEMS[$label]}" "$LOGDIR/05-security_check-after.log"; then
        echo "[ OK ]     $label"
    elif [ "$EGRESS_USED" -eq 1 ]; then
        echo "[FAIL]     $label (tenía salida a internet vía --allow-egress y aun así falló)"
        ITEM_FAIL=1
    else
        echo "[ WARN ]   $label (requiere que el contenedor tenga salida a internet — ver limitaciones)"
    fi
done

echo
echo "== RESUMEN =="
echo "WARNINGs antes: $BEFORE_WARN   WARNINGs después: $AFTER_WARN"
echo "Nota: 'Docker: puertos reenviados' de security_check.sh SIEMPRE sale"
echo "'OK: no aplica' aquí (no hay dockerd real) — el bug de DOCKER-USER se"
echo "valida por separado, inspeccionando iptables directamente (arriba)."
if [ "$EGRESS_USED" -eq 1 ]; then
    echo "Nota: corrido con --allow-egress — se abrió temporalmente la salida a"
    echo "internet en el DOCKER-USER del HOST real durante fail2ban/clamav/ntp y"
    echo "se cerró justo después (ver arriba)."
else
    echo "Nota: la sincronización NTP real y la instalación de fail2ban/ClamAV"
    echo "dependen de que el CONTENEDOR tenga salida a internet. En este host el"
    echo "propio DOCKER-USER que gestiona docker-user-firewall.sh bloquea esa"
    echo "salida para TODOS los contenedores (ver 'Limitación conocida' en el"
    echo "README principal) — usa --allow-egress para probarlo con red real."
fi
echo "Nota: fix_security.sh reportó el apartado 'firewall' del primer intento"
echo "como '[ + ] arreglado' aunque DOCKER-USER siguiera sin existir —"
echo "docker-user-firewall.sh no tiene 'set -e' y termina en un echo que"
echo "siempre sale con éxito, así que su código de salida no refleja los"
echo "fallos de iptables de dentro. Hallazgo real del script, no del simulador."

OVERALL=0
[ "$BEFORE_WARN" -gt 0 ]                     || { echo "FALLO: el estado inicial no tenía WARNINGs"; OVERALL=1; }
[ "$AFTER_WARN" -lt "$BEFORE_WARN" ]         || { echo "FALLO: fix_security.sh no redujo los WARNINGs"; OVERALL=1; }
[ "$ATTEMPT1_STILL_BROKEN" -eq 1 ]           || { echo "FALLO: no se reprodujo el bug de DOCKER-USER"; OVERALL=1; }
[ "$DOCKERUSER_FIXED" -eq 1 ]                || { echo "FALLO: DOCKER-USER no quedó reparado"; OVERALL=1; }
[ "$ITEM_FAIL" -eq 0 ]                       || { echo "FALLO: algún chequeo itemizado (no ligado a red) no pasó"; OVERALL=1; }

if [ "$OVERALL" -eq 0 ]; then
    echo "PASS: el simulador demuestra (a) el estado recién aprovisionado con WARNINGs,"
    echo "      (b) fix_security.sh corrigiendo lo mecánico, y (c) el bug de"
    echo "      DOCKER-USER tras un flush + su recuperación en dos pasos."
else
    echo "FAIL: revisa $LOGDIR/*.log"
fi
exit "$OVERALL"
