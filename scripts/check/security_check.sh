#!/usr/bin/env bash
# System security check — read-only audit of the local host.
# Evaluates each item and reports OK/WARNING, not raw command output.
# Usage: sudo ./security_check.sh
set -uo pipefail

if [ "$EUID" -ne 0 ]; then
    echo "Este script debe ejecutarse con sudo. Abortando." >&2
    exit 1
fi

INVOKING_USER="${SUDO_USER:-root}"
OK_COUNT=0
WARN_COUNT=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../../.env"
if [ -f "$ENV_FILE" ]; then
    EXPECTED_PORTS=$(grep -E '^EXPECTED_PORTS=' "$ENV_FILE" | tail -1 | cut -d= -f2- | tr -d '"' | tr -d "'")
    DOCKER_ALLOWED_PORTS=$(grep -E '^DOCKER_ALLOWED_PORTS=' "$ENV_FILE" | tail -1 | cut -d= -f2- | tr -d '"' | tr -d "'")
    HOST_ALLOWED_PORTS=$(grep -E '^HOST_ALLOWED_PORTS=' "$ENV_FILE" | tail -1 | cut -d= -f2- | tr -d '"' | tr -d "'")
    NTP_SERVER=$(grep -E '^NTP_SERVER=' "$ENV_FILE" | tail -1 | cut -d= -f2- | tr -d '"' | tr -d "'")
fi
EXPECTED_PORTS="${EXPECTED_PORTS:-22 80 443 41641}"
DOCKER_ALLOWED_PORTS="${DOCKER_ALLOWED_PORTS:-}"
HOST_ALLOWED_PORTS="${HOST_ALLOWED_PORTS:-}"
NTP_SERVER="${NTP_SERVER:-}"

# DOCKER_ALLOWED_PORTS y HOST_ALLOWED_PORTS ya declaran, con su propio
# propósito (aplicar reglas de firewall), qué puertos deben estar
# accesibles. Para no duplicar esa misma lista en EXPECTED_PORTS, el
# universo de puertos esperados aquí es la unión de las tres variables:
# EXPECTED_PORTS solo necesita los puertos que NO gestione ya ninguno de
# los dos scripts de firewall (p.ej. 22 y 41641, fuera de su control).
expand_ports() {
    # $1 = entradas "puerto[:puerto]/tcp|udp" separadas por espacios;
    # imprime un puerto suelto por línea, expandiendo los rangos.
    local entry port lo hi
    for entry in $1; do
        port="${entry%/*}"
        case "$port" in
            *:*)
                lo="${port%%:*}"
                hi="${port##*:}"
                seq "$lo" "$hi" 2>/dev/null
                ;;
            *)
                printf '%s\n' "$port"
                ;;
        esac
    done
}

ALL_EXPECTED_PORTS=$(printf '%s\n' $EXPECTED_PORTS $(expand_ports "$DOCKER_ALLOWED_PORTS") $(expand_ports "$HOST_ALLOWED_PORTS") | sort -un | tr '\n' ' ')

# Atajos al apartado de scripts/maintenance/fix_security.sh que arregla
# cada warning (o a "revisión manual" cuando no hay arreglo automático
# porque implica riesgo de bloqueo remoto o una decisión humana — ver el
# resumen final de fix_security.sh para la lista completa de motivos).
FIX="sudo ./scripts/maintenance/fix_security.sh"
HINT_FIREWALL="$FIX firewall"
HINT_FAIL2BAN="$FIX fail2ban"
HINT_UPDATES="$FIX updates"
HINT_CLAMAV="$FIX clamav"
HINT_NTP="$FIX ntp"
HINT_SSH="$FIX ssh"
HINT_PERMS="$FIX perms"
HINT_MANUAL="revisión manual, no hay arreglo automático (ver README)"

ok() {
    printf '[ OK ]    %s\n' "$1"
    OK_COUNT=$((OK_COUNT + 1))
}

warn() {
    printf '[WARNING] %s\n' "$1"
    [ -n "${2:-}" ] && printf '          -> %s\n' "$2"
    WARN_COUNT=$((WARN_COUNT + 1))
}

hr() { printf '\n== %s ==\n' "$1"; }
sub() { printf '\n-- %s --\n' "$1"; }

hr "Información básica"
. /etc/os-release 2>/dev/null
printf 'SO: %s\n' "${PRETTY_NAME:-desconocido}"
printf 'Kernel: %s\n' "$(uname -r)"
printf 'Host: %s\n' "$(hostname)"
printf 'Usuario invocando el script: %s\n' "$INVOKING_USER"
printf 'Fecha: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"

hr "Checks de seguridad"

sub "SSH"
SSHD_T=$(sshd -T 2>&1)

val() { printf '%s\n' "$SSHD_T" | grep -i "^$1 " | awk '{print $2}'; }

[ "$(val permitrootlogin)" = "no" ] \
    && ok "SSH: PermitRootLogin deshabilitado" \
    || warn "SSH: PermitRootLogin no está en 'no'" "$HINT_MANUAL (riesgo de bloqueo remoto)"

[ "$(val passwordauthentication)" = "no" ] \
    && ok "SSH: autenticación por contraseña deshabilitada" \
    || warn "SSH: PasswordAuthentication está habilitado (permite login por contraseña)" "$HINT_MANUAL (riesgo de bloqueo remoto)"

[ "$(val permitemptypasswords)" = "no" ] \
    && ok "SSH: contraseñas vacías deshabilitadas" \
    || warn "SSH: PermitEmptyPasswords no está en 'no'" "$HINT_SSH"

MAXAUTH=$(val maxauthtries)
[ -n "$MAXAUTH" ] && [ "$MAXAUTH" -le 4 ] 2>/dev/null \
    && ok "SSH: MaxAuthTries limitado ($MAXAUTH)" \
    || warn "SSH: MaxAuthTries alto o no definido ($MAXAUTH)" "$HINT_SSH"

printf '%s\n' "$SSHD_T" | grep -qi '^allowusers ' \
    && ok "SSH: acceso restringido con AllowUsers" \
    || warn "SSH: no hay restricción AllowUsers/AllowGroups (cualquier usuario del sistema puede intentar login)" "$HINT_MANUAL (requiere decidir la lista de usuarios)"

sub "Firewall y red"
NFT=$(nft list ruleset 2>&1)
printf '%s\n' "$NFT" | grep -A1 'hook input' | grep -q 'policy drop' \
    && ok "Firewall: política por defecto DROP en INPUT (tráfico dirigido al host)" \
    || warn "Firewall: la cadena INPUT no tiene política DROP por defecto" "$HINT_MANUAL (prerrequisito en /etc/nftables.conf)"

printf '%s\n' "$NFT" | grep -q 'dport 22.*limit rate' \
    && ok "Firewall: rate-limit activo en el puerto SSH" \
    || warn "Firewall: sin rate-limit para SSH (expuesto a fuerza bruta sin throttling)" "$HINT_MANUAL (prerrequisito en /etc/nftables.conf)"

PUBLIC_UNEXPECTED=$(ss -tulnH 2>/dev/null | awk '{print $5}' | grep -E '^(0\.0\.0\.0|\*|\[::\]):' | sed -E 's/.*:([0-9]+)$/\1/' | sort -u | while read -r p; do
    echo "$ALL_EXPECTED_PORTS" | grep -qw "$p" || echo "$p"
done)
if [ -z "$PUBLIC_UNEXPECTED" ]; then
    ok "Solo puertos esperados ($(echo "$ALL_EXPECTED_PORTS" | tr -s ' ' '/')) expuestos públicamente"
else
    warn "Puerto(s) inesperados expuestos públicamente: $(echo "$PUBLIC_UNEXPECTED" | tr '\n' ' ')" "$HINT_MANUAL (identificar el servicio primero)"
fi

if systemctl is-active --quiet fail2ban 2>/dev/null; then
    ok "fail2ban activo"
else
    warn "fail2ban no está activo" "$HINT_FAIL2BAN"
fi

sub "Docker: puertos reenviados"
# Los puertos publicados por Docker (-p host:cont) se reenvían vía DNAT +
# FORWARD/DOCKER, que NO pasan por la cadena INPUT comprobada arriba, así
# que su política DROP no los protege. El punto de control real es la
# cadena DOCKER-USER (ver scripts/docker-user-firewall.sh). Este bloque
# verifica que esa cadena exista, termine en DROP por defecto, y que cada
# puerto que Docker tiene publicado ahora mismo tenga su propia regla
# ACCEPT explícita — si no la tiene, está expuesto sin filtrar pese a
# que el resto del firewall parezca correcto.
if command -v docker >/dev/null 2>&1 && systemctl is-active --quiet docker 2>/dev/null; then
    DOCKER_USER_RULES=$(iptables -L DOCKER-USER -n 2>&1)
    if printf '%s\n' "$DOCKER_USER_RULES" | grep -qE '^Chain DOCKER-USER'; then
        LAST_RULE=$(printf '%s\n' "$DOCKER_USER_RULES" | tail -n1)
        printf '%s\n' "$LAST_RULE" | grep -qE '^DROP[[:space:]]' \
            && ok "DOCKER-USER termina en DROP por defecto (allowlist explícita activa)" \
            || warn "DOCKER-USER no termina en DROP: los puertos publicados por Docker se reenvían sin filtrar, saltándose la política DROP de INPUT" "$HINT_FIREWALL"

        # docker ps publica rangos como "9000-9001->9000-9001/tcp" (con
        # guion, no dos puertos sueltos) — hay que conservar el rango y
        # traducir el guion a ":" para que coincida con la sintaxis
        # --dport de iptables.
        PUBLISHED=$(docker ps --format '{{.Ports}}' 2>/dev/null \
            | tr ',' '\n' \
            | grep -oE '(0\.0\.0\.0|\[::\]|:::):[0-9]+(-[0-9]+)?->[0-9]+(-[0-9]+)?/(tcp|udp)' \
            | sed -E 's#^(0\.0\.0\.0|\[::\]|:::):##; s#->[0-9]+(-[0-9]+)?/#/#' \
            | tr '-' ':' \
            | sort -u)

        UNPROTECTED=""
        for entry in $PUBLISHED; do
            port="${entry%/*}"
            proto="${entry##*/}"
            iptables -C DOCKER-USER -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null \
                || UNPROTECTED="$UNPROTECTED $entry"
        done

        if [ -z "$PUBLISHED" ]; then
            ok "Docker no tiene puertos publicados actualmente"
        elif [ -z "$UNPROTECTED" ]; then
            ok "Todos los puertos publicados por Docker ($(echo "$PUBLISHED" | tr '\n' ' ')) tienen regla ACCEPT explícita en DOCKER-USER"
        else
            warn "Puerto(s) publicados por Docker SIN regla explícita en DOCKER-USER, expuestos sin filtrar:$UNPROTECTED" "$HINT_FIREWALL (añade el puerto a DOCKER_ALLOWED_PORTS en .env primero)"
        fi
    else
        warn "No existe la cadena DOCKER-USER o no se pudo leer — los puertos publicados por Docker podrían estar sin filtrar" "$HINT_MANUAL (estado inusual, revisar Docker/iptables)"
    fi
else
    ok "Docker no está instalado/activo — no aplica"
fi

sub "Sistema y paquetes"
UPGRADABLE=$(apt list --upgradable 2>/dev/null | tail -n +2 | wc -l)
[ "$UPGRADABLE" -eq 0 ] \
    && ok "Sistema al día (0 actualizaciones pendientes)" \
    || warn "$UPGRADABLE actualizaciones de paquetes pendientes" "$HINT_UPDATES"

sub "Sincronización horaria"
NTP_SYNCED=$(timedatectl show -p NTPSynchronized --value 2>/dev/null)
[ "$NTP_SYNCED" = "yes" ] \
    && ok "Reloj del sistema sincronizado vía NTP" \
    || warn "El reloj del sistema no está sincronizado vía NTP" "$HINT_NTP"

if [ -z "$NTP_SERVER" ]; then
    warn "NTP_SERVER no está definido en .env — configura el servidor NTP a usar" "$HINT_MANUAL (elegir el servidor es una decisión de despliegue)"
else
    TIMESYNC_SERVER=$(timedatectl timesync-status 2>/dev/null | grep -m1 '^ *Server:' | sed -E 's/^ *Server: *//')
    if printf '%s' "$TIMESYNC_SERVER" | grep -qiF "$NTP_SERVER"; then
        ok "El sistema sincroniza específicamente contra el servidor configurado ($TIMESYNC_SERVER)"
    elif [ -z "$TIMESYNC_SERVER" ] && systemd-detect-virt --container -q 2>/dev/null; then
        # systemd-timesyncd trae de fábrica ConditionVirtualization=!container
        # y no arranca dentro de un contenedor (asume que debe heredar la
        # hora del host) — "timedatectl timesync-status" nunca va a tener
        # nada que mostrar aquí, da igual cuántas veces se corra
        # "fix_security.sh ntp". No es un fallo de configuración: la
        # comprobación de abajo (consulta NTP directa, sin depender de
        # timesyncd) es la que de verdad valida la sincronización aquí.
        ok "No se puede confirmar el servidor vía timedatectl — no aplica (systemd-timesyncd no arranca dentro de un contenedor, ConditionVirtualization=!container; se valida por separado más abajo con una consulta NTP directa)"
    else
        warn "El sistema NO está configurado para sincronizar contra $NTP_SERVER (servidor actual: ${TIMESYNC_SERVER:-desconocido})" "$HINT_NTP"
    fi

    if command -v python3 >/dev/null 2>&1; then
        NTP_OFFSET=$(NTP_SERVER="$NTP_SERVER" timeout 8 python3 - <<'PYEOF' 2>/dev/null
import os, socket, struct, time, sys
HOST = os.environ["NTP_SERVER"]
PORT = 123
try:
    T1 = time.time()
    data = b'\x1b' + 47 * b'\0'
    client = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    client.settimeout(5)
    client.sendto(data, (HOST, PORT))
    recv, _ = client.recvfrom(48)
    T4 = time.time()
    fields = struct.unpack('!12I', recv)
    def to_unix(sec, frac):
        return sec - 2208988800 + frac / 2**32
    T2 = to_unix(fields[8], fields[9])
    T3 = to_unix(fields[10], fields[11])
    offset = ((T2 - T1) + (T3 - T4)) / 2
    print(f"{offset:.3f}")
except Exception:
    sys.exit(1)
PYEOF
)
        if [ -n "$NTP_OFFSET" ]; then
            ABS_OK=$(awk -v o="$NTP_OFFSET" 'BEGIN{v=o; if (v<0) v=-v; print (v<=1.0)?1:0}')
            if [ "$ABS_OK" = "1" ]; then
                ok "Hora sincronizada con el servidor NTP configurado ($NTP_SERVER), desviación ${NTP_OFFSET}s"
            else
                warn "Desviación de ${NTP_OFFSET}s respecto al servidor NTP configurado ($NTP_SERVER)" "$HINT_NTP"
            fi
        else
            warn "No se pudo consultar el servidor NTP configurado ($NTP_SERVER) — red/DNS/firewall" "$HINT_MANUAL (revisar conectividad/DNS/firewall hacia $NTP_SERVER)"
        fi
    else
        warn "python3 no disponible, no se pudo verificar contra $NTP_SERVER" "$HINT_MANUAL (instalar python3)"
    fi
fi

sub "Antivirus"
if command -v clamscan >/dev/null 2>&1 || command -v freshclam >/dev/null 2>&1; then
    ok "ClamAV está instalado"

    CLAM_DB=""
    for f in /var/lib/clamav/daily.cvd /var/lib/clamav/daily.cld; do
        [ -f "$f" ] && CLAM_DB="$f"
    done

    if [ -n "$CLAM_DB" ]; then
        DB_AGE_DAYS=$(( ( $(date +%s) - $(stat -c %Y "$CLAM_DB") ) / 86400 ))
        [ "$DB_AGE_DAYS" -le 7 ] \
            && ok "Base de datos de ClamAV actualizada (hace $DB_AGE_DAYS día(s))" \
            || warn "Base de datos de ClamAV desactualizada (hace $DB_AGE_DAYS días, revisar freshclam)" "$HINT_CLAMAV"
    else
        warn "ClamAV instalado pero no se encontró la base de datos de firmas (daily.cvd/cld)" "$HINT_CLAMAV"
    fi

    if command -v apt-cache >/dev/null 2>&1; then
        CLAM_POLICY=$(apt-cache policy clamav 2>/dev/null)
        CLAM_INSTALLED=$(printf '%s\n' "$CLAM_POLICY" | grep -E 'Instalados?:|Installed:' | head -1 | sed -E 's/.*: *//')
        CLAM_CANDIDATE=$(printf '%s\n' "$CLAM_POLICY" | grep -E 'Candidatos?:|Candidate:' | head -1 | sed -E 's/.*: *//')

        if [ -n "$CLAM_INSTALLED" ] && [ "$CLAM_INSTALLED" = "$CLAM_CANDIDATE" ]; then
            ok "ClamAV en la última versión disponible en los repositorios de Debian ($CLAM_INSTALLED)"
        elif [ -n "$CLAM_INSTALLED" ] && [ -n "$CLAM_CANDIDATE" ]; then
            warn "Hay una versión más nueva de ClamAV en apt (instalada: $CLAM_INSTALLED, disponible: $CLAM_CANDIDATE)" "$HINT_CLAMAV"
        else
            warn "No se pudo determinar la versión de ClamAV vía apt-cache policy" "$HINT_MANUAL"
        fi
    else
        warn "apt-cache no disponible, no se pudo verificar la versión de ClamAV" "$HINT_MANUAL"
    fi
else
    warn "No hay antivirus instalado (recomendado: ClamAV)" "$HINT_CLAMAV"
fi

sub "Sistema de archivos y permisos"
# Las capas de imágenes de contenedor (overlayfs de Docker/containerd)
# suelen incluir binarios world-writable de fábrica (p.ej. coreutils en
# imágenes tipo BusyBox/Alpine) — son contenido interno de la imagen, no
# alcanzable escribiendo desde el host, así que se excluyen aquí igual que
# ya se hace más abajo para el chequeo de SUID/SGID.
WW_COUNT=$(find / -xdev -type f -perm -0002 \
    -not -path "/proc/*" -not -path "/tmp/*" \
    -not -path "/var/tmp/*" -not -path "/dev/*" \
    -not -path "/var/lib/docker/*" -not -path "/var/lib/containerd/*" \
    2>/dev/null | wc -l)
[ "$WW_COUNT" -eq 0 ] \
    && ok "Sin archivos world-writable inesperados" \
    || warn "$WW_COUNT archivo(s) world-writable fuera de directorios temporales esperados" "$HINT_MANUAL (un chmod ciego puede romper algo legítimo)"

BASELINE_SUID="/usr/sbin/unix_chkpwd /usr/bin/gpasswd /usr/bin/umount /usr/bin/chsh /usr/bin/passwd /usr/bin/sudo /usr/bin/dotlockfile /usr/bin/chage /usr/bin/ssh-agent /usr/bin/chfn /usr/bin/expiry /usr/bin/su /usr/bin/crontab /usr/bin/newgrp /usr/bin/mount /usr/lib/openssh/ssh-keysign /usr/lib/dbus-1.0/dbus-daemon-launch-helper"
FOUND_SUID=$(find / -xdev -type f \( -perm -4000 -o -perm -2000 \) \
    -not -path "/var/lib/docker/*" -not -path "/var/lib/containerd/*" \
    2>/dev/null)
EXTRA_SUID=""
while IFS= read -r f; do
    [ -z "$f" ] && continue
    case " $BASELINE_SUID " in
        *" $f "*) ;;
        *) EXTRA_SUID="$EXTRA_SUID $f" ;;
    esac
done <<< "$FOUND_SUID"
if [ -z "$EXTRA_SUID" ]; then
    ok "Binarios SUID/SGID: solo los estándar del sistema"
else
    warn "Binarios SUID/SGID inesperados:$EXTRA_SUID" "$HINT_MANUAL (podrían ser legítimos o maliciosos, inspeccionar antes de tocar)"
fi

REAL_HOME=$(getent passwd "$INVOKING_USER" | cut -d: -f6)
if [ -d "$REAL_HOME/.ssh" ]; then
    SSH_DIR_PERM=$(stat -c '%a' "$REAL_HOME/.ssh")
    [ "$SSH_DIR_PERM" = "700" ] \
        && ok "Permisos de ~/.ssh correctos (700)" \
        || warn "Permisos de ~/.ssh inseguros ($SSH_DIR_PERM, debería ser 700)" "$HINT_PERMS"

    if [ -f "$REAL_HOME/.ssh/authorized_keys" ]; then
        AK_PERM=$(stat -c '%a' "$REAL_HOME/.ssh/authorized_keys")
        [ "$AK_PERM" = "600" ] || [ "$AK_PERM" = "400" ] \
            && ok "Permisos de authorized_keys correctos ($AK_PERM)" \
            || warn "Permisos de authorized_keys inseguros ($AK_PERM)" "$HINT_PERMS"
    fi
else
    warn "No existe ~/.ssh para $INVOKING_USER" "$HINT_MANUAL (crear el directorio y las claves es una decisión del usuario)"
fi

HOME_ISSUES=""
for d in /root /home/*; do
    [ -d "$d" ] || continue
    PERM=$(stat -c '%a' "$d")
    case "$PERM" in
        700|750) ;;
        *) HOME_ISSUES="$HOME_ISSUES $d($PERM)" ;;
    esac
done
if [ -z "$HOME_ISSUES" ]; then
    ok "Directorios home sin acceso de otros usuarios"
else
    warn "Directorios home con permisos amplios:$HOME_ISSUES" "$HINT_PERMS"
fi

sub "Sudo y privilegios"
SUDO_L=$(sudo -n -l -U "$INVOKING_USER" 2>&1)
if printf '%s\n' "$SUDO_L" | grep -qi 'NOPASSWD: *ALL'; then
    warn "El usuario $INVOKING_USER tiene sudo NOPASSWD:ALL (root sin contraseña)" "$HINT_MANUAL (editar sudoers mal es un riesgo de bloqueo total)"
else
    ok "El usuario $INVOKING_USER no tiene sudo NOPASSWD:ALL"
fi

hr "Resumen"
printf 'OK: %d   WARNING: %d\n' "$OK_COUNT" "$WARN_COUNT"
