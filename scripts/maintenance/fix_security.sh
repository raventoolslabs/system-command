#!/usr/bin/env bash
# Auto-remediación de los hallazgos "mecánicos" de check/security_check.sh
# — solo los que se pueden corregir sin analizar el caso en detalle ni
# riesgo de bloqueo remoto (SSH, sudoers, puertos públicos concretos,
# SUID/SGID, world-writable). Para esos, security_check.sh sigue siendo la
# única fuente de verdad: este script solo recuerda al final que hay que
# revisarlos a mano.
#
# Organizado en apartados independientes, cada uno invocable por
# separado (útil para arreglar justo lo que security_check.sh acaba de
# señalar, sin tocar el resto). Sin apartados de por medio se ejecutan
# todos, en el mismo orden que las secciones de security_check.sh.
#
# Idempotente: cada arreglo comprueba primero si ya está en el estado
# deseado (con la misma lógica de detección que security_check.sh) y solo
# actúa si no lo está — se puede ejecutar tantas veces como se quiera.
#
# Usage: sudo ./fix_security.sh [--dry-run] [apartado ...]
#   Apartados disponibles: firewall fail2ban updates autoupdates clamav ntp ssh perms
#   Sin apartados: se ejecutan todos.
set -uo pipefail

ALL_SECTIONS="firewall fail2ban updates autoupdates clamav ntp ssh perms"

DRY_RUN=0
SECTIONS=""
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        firewall|fail2ban|updates|autoupdates|clamav|ntp|ssh|perms) SECTIONS="$SECTIONS $arg" ;;
        *)
            echo "Opción o apartado desconocido: $arg" >&2
            echo "Apartados válidos: $ALL_SECTIONS" >&2
            exit 1
            ;;
    esac
done
SECTIONS="${SECTIONS:-$ALL_SECTIONS}"

if [ "$EUID" -ne 0 ]; then
    echo "Este script debe ejecutarse con sudo (instala paquetes y modifica configuración del sistema). Abortando." >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../../.env"
INVOKING_USER="${SUDO_USER:-root}"

if [ -f "$ENV_FILE" ]; then
    NTP_SERVER=$(grep -E '^NTP_SERVER=' "$ENV_FILE" | tail -1 | cut -d= -f2- | tr -d '"' | tr -d "'")
    DOCKER_ALLOWED_PORTS=$(grep -E '^DOCKER_ALLOWED_PORTS=' "$ENV_FILE" | tail -1 | cut -d= -f2- | tr -d '"' | tr -d "'")
fi
NTP_SERVER="${NTP_SERVER:-}"
DOCKER_ALLOWED_PORTS="${DOCKER_ALLOWED_PORTS:-}"

FIXED=0
SKIPPED=0
FAILED=0

hr()  { printf '\n== %s ==\n' "$1"; }
ok()     { printf '[ = ]  ya correcto: %s\n' "$1"; SKIPPED=$((SKIPPED + 1)); }
fixed()  { printf '[ + ]  arreglado:   %s\n' "$1"; FIXED=$((FIXED + 1)); }
would()  { printf '[+dry] arreglaría:  %s\n' "$1"; FIXED=$((FIXED + 1)); }
failed() { printf '[ ! ]  FALLÓ:       %s\n' "$1" >&2; FAILED=$((FAILED + 1)); }
manual() { printf '[ ? ]  pendiente:   %s\n' "$1"; }

contains() {
    # $1 = elemento a buscar; $2 = lista separada por espacios
    case " $2 " in
        *" $1 "*) return 0 ;;
        *) return 1 ;;
    esac
}

APT_UPDATED=0
ensure_apt_updated() {
    # fail2ban y clamav instalan paquetes vía apt-get install directo, sin
    # haber corrido antes "apt-get update" en esta ejecución. En un host
    # con el índice de apt ya poblado (el caso normal) nunca se nota, pero
    # si el índice está vacío (imagen recién construida con
    # "rm -rf /var/lib/apt/lists/*", o tras un "apt-get clean") el install
    # falla con "Unable to locate package" — pasaba también corriendo cada
    # apartado por separado, no solo por el orden de ALL_SECTIONS. Se cachea
    # con APT_UPDATED para no repetir el update si se piden varios
    # apartados en la misma invocación.
    [ "$APT_UPDATED" -eq 1 ] && return 0
    apt-get update -qq && APT_UPDATED=1
}

# =======================================================================
fix_firewall() {
hr "Firewall (reconciliación)"
# -----------------------------------------------------------------
# host-firewall.sh y docker-user-firewall.sh ya son reconciliadores
# idempotentes — dejan el estado exactamente igual a lo declarado en
# .env cada vez que se ejecutan. Se relanzan siempre, sin comprobar antes
# si "hacen falta": es justo lo que arregla el caso documentado en el
# README — tras un "nft -f /etc/nftables.conf" (flush ruleset) que vacía
# DOCKER-USER, docker-user-firewall.service no se reactiva solo.
if [ "$DRY_RUN" -eq 1 ]; then
    "$SCRIPT_DIR/../firewall/host-firewall.sh" --dry-run
    # docker-user-firewall.sh no soporta --dry-run (modifica iptables
    # directamente, sin modo de solo-lectura) — no se puede previsualizar
    # sin ejecutarlo de verdad, así que en dry-run solo se anuncia.
    if [ -z "$DOCKER_ALLOWED_PORTS" ]; then
        ok "docker-user-firewall.sh: DOCKER_ALLOWED_PORTS vacío en .env, nada que reconciliar"
    else
        would "reconciliar DOCKER-USER con docker-user-firewall.sh (no soporta --dry-run, se omite la ejecución real)"
    fi
else
    if "$SCRIPT_DIR/../firewall/host-firewall.sh"; then
        fixed "host-firewall.sh ejecutado (ver detalle de reglas arriba)"
    else
        failed "host-firewall.sh terminó con errores"
    fi

    if [ -z "$DOCKER_ALLOWED_PORTS" ]; then
        ok "docker-user-firewall.sh: DOCKER_ALLOWED_PORTS vacío en .env, nada que reconciliar"
    elif "$SCRIPT_DIR/../firewall/docker-user-firewall.sh"; then
        fixed "docker-user-firewall.sh ejecutado (ver detalle de reglas arriba)"
    else
        failed "docker-user-firewall.sh terminó con errores"
    fi
fi
}

# =======================================================================
fix_fail2ban() {
hr "fail2ban"
if systemctl is-active --quiet fail2ban 2>/dev/null; then
    ok "fail2ban activo"
else
    if [ "$DRY_RUN" -eq 1 ]; then
        would "instalar (si falta) y activar fail2ban"
    else
        command -v fail2ban-server >/dev/null 2>&1 || { ensure_apt_updated; apt-get install -y fail2ban; }
        if systemctl enable --now fail2ban 2>/dev/null; then
            fixed "fail2ban instalado/activado"
        else
            failed "no se pudo activar fail2ban"
        fi
    fi
fi
}

# =======================================================================
fix_updates() {
hr "Actualizaciones de paquetes"
# Delega en update_packages.sh en vez de duplicar su lógica (apt-get
# update/upgrade, paquetes retenidos, autoremove). Su propio resumen
# ("Nada que hacer" / contadores) ya es la fuente de verdad de qué
# cambió, así que no se intenta traducirlo a FIXED/SKIPPED aquí.
if "$SCRIPT_DIR/update_packages.sh" $( [ "$DRY_RUN" -eq 1 ] && echo --dry-run ); then
    :
else
    failed "update_packages.sh terminó con errores"
fi
}

# =======================================================================
fix_autoupdates() {
hr "Parches de seguridad automáticos (unattended-upgrades)"
# Mismas comprobaciones que security_check.sh, en el mismo orden.
if dpkg -s unattended-upgrades >/dev/null 2>&1; then
    ok "unattended-upgrades instalado"
elif [ "$DRY_RUN" -eq 1 ]; then
    would "instalar unattended-upgrades"
else
    ensure_apt_updated
    if apt-get install -y unattended-upgrades; then
        fixed "unattended-upgrades instalado"
    else
        failed "no se pudo instalar unattended-upgrades"
        return
    fi
fi

au_enabled() {
    AU_LISTS="" AU_UPGRADE=""
    eval "$(apt-config shell AU_LISTS APT::Periodic::Update-Package-Lists AU_UPGRADE APT::Periodic::Unattended-Upgrade 2>/dev/null)"
    [ "${AU_LISTS:-0}" != "0" ] && [ "${AU_UPGRADE:-0}" != "0" ]
}

# Mismo fichero que escribe "dpkg-reconfigure unattended-upgrades". Si
# otro fichero posterior de apt.conf.d lo desactiva, no se pisa: es una
# decisión explícita de alguien y se informa como fallo.
AU_CONF=/etc/apt/apt.conf.d/20auto-upgrades
if au_enabled; then
    ok "unattended-upgrades activado en apt"
elif [ "$DRY_RUN" -eq 1 ]; then
    would "escribir $AU_CONF (Update-Package-Lists y Unattended-Upgrade a 1)"
else
    printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\n' > "$AU_CONF"
    if au_enabled; then
        fixed "$AU_CONF escrito, unattended-upgrades activado"
    else
        failed "escrito $AU_CONF pero otro fichero de /etc/apt/apt.conf.d lo sigue desactivando (busca con: grep -r Periodic /etc/apt/apt.conf.d)"
    fi
fi

for t in apt-daily.timer apt-daily-upgrade.timer; do
    if systemctl is-enabled --quiet "$t" 2>/dev/null && systemctl is-active --quiet "$t" 2>/dev/null; then
        ok "$t activo"
    elif [ "$DRY_RUN" -eq 1 ]; then
        would "activar $t"
    elif systemctl enable --now "$t" 2>/dev/null; then
        fixed "$t activado"
    else
        failed "no se pudo activar $t"
    fi
done

# Una ejecución ahora: aplica ya los parches pendientes y demuestra que
# funciona en este host, sin esperar al próximo disparo del timer.
AU_LOG=/var/log/unattended-upgrades/unattended-upgrades.log
if [ -f "$AU_LOG" ] && [ $(( ( $(date +%s) - $(stat -c %Y "$AU_LOG") ) / 86400 )) -le 3 ]; then
    ok "unattended-upgrades se ha ejecutado en los últimos 3 días"
elif [ "$DRY_RUN" -eq 1 ]; then
    would "ejecutar unattended-upgrade ahora (aplica los parches de seguridad pendientes)"
else
    ensure_apt_updated
    if unattended-upgrade; then
        fixed "unattended-upgrade ejecutado (detalle en $AU_LOG)"
    else
        failed "unattended-upgrade terminó con errores (revisa $AU_LOG)"
    fi
fi
}

# =======================================================================
fix_clamav() {
hr "Antivirus (ClamAV)"
if command -v clamscan >/dev/null 2>&1 || command -v freshclam >/dev/null 2>&1; then
    ok "ClamAV instalado"
else
    if [ "$DRY_RUN" -eq 1 ]; then
        would "instalar clamav clamav-daemon clamav-freshclam"
    else
        ensure_apt_updated
        if apt-get install -y clamav clamav-daemon clamav-freshclam; then
            fixed "ClamAV instalado"
        else
            failed "no se pudo instalar ClamAV"
        fi
    fi
fi

if command -v clamscan >/dev/null 2>&1 || command -v freshclam >/dev/null 2>&1; then
    CLAM_DB=""
    for f in /var/lib/clamav/daily.cvd /var/lib/clamav/daily.cld; do
        [ -f "$f" ] && CLAM_DB="$f"
    done

    NEEDS_FRESHCLAM=0
    if [ -z "$CLAM_DB" ]; then
        NEEDS_FRESHCLAM=1
        REASON="no hay base de datos de firmas"
    else
        DB_AGE_DAYS=$(( ( $(date +%s) - $(stat -c %Y "$CLAM_DB") ) / 86400 ))
        if [ "$DB_AGE_DAYS" -gt 7 ]; then
            NEEDS_FRESHCLAM=1
            REASON="base de datos desactualizada (hace $DB_AGE_DAYS días)"
        fi
    fi

    if [ "$NEEDS_FRESHCLAM" -eq 0 ]; then
        ok "Base de datos de ClamAV actualizada (hace $DB_AGE_DAYS día(s))"
    elif [ "$DRY_RUN" -eq 1 ]; then
        would "actualizar base de datos de ClamAV con freshclam ($REASON)"
    else
        # clamav-freshclam.service ya corre freshclam en segundo plano y
        # mantiene un lock sobre la base de datos — invocarlo a mano en
        # paralelo falla con "Can't lock ... daily.cld". Se para el
        # servicio, se ejecuta freshclam una vez en primer plano, y se
        # reactiva el servicio (retoma su propio calendario).
        systemctl stop clamav-freshclam 2>/dev/null
        if freshclam --quiet; then
            fixed "base de datos de ClamAV actualizada con freshclam ($REASON)"
        else
            failed "freshclam no pudo actualizar la base de datos"
        fi
        systemctl start clamav-freshclam 2>/dev/null
    fi

    if command -v apt-cache >/dev/null 2>&1; then
        CLAM_POLICY=$(apt-cache policy clamav 2>/dev/null)
        CLAM_INSTALLED=$(printf '%s\n' "$CLAM_POLICY" | grep -E 'Instalados?:|Installed:' | head -1 | sed -E 's/.*: *//')
        CLAM_CANDIDATE=$(printf '%s\n' "$CLAM_POLICY" | grep -E 'Candidatos?:|Candidate:' | head -1 | sed -E 's/.*: *//')

        if [ -n "$CLAM_INSTALLED" ] && [ "$CLAM_INSTALLED" = "$CLAM_CANDIDATE" ]; then
            ok "ClamAV en la última versión disponible ($CLAM_INSTALLED)"
        elif [ -n "$CLAM_INSTALLED" ] && [ -n "$CLAM_CANDIDATE" ]; then
            if [ "$DRY_RUN" -eq 1 ]; then
                would "actualizar paquetes clamav* de $CLAM_INSTALLED a $CLAM_CANDIDATE"
            else
                # --only-upgrade (nunca "install" a secas): solo toca
                # paquetes clamav* que ya están instalados, igual que
                # update_packages.sh con el resto del sistema.
                mapfile -t CLAM_PKGS < <(dpkg -l 2>/dev/null | awk '/^ii/ && ($2 ~ /^clamav/ || $2 ~ /^libclamav/) {print $2}')
                if [ "${#CLAM_PKGS[@]}" -gt 0 ] && apt-get install --only-upgrade -y "${CLAM_PKGS[@]}"; then
                    fixed "ClamAV actualizado a $CLAM_CANDIDATE"
                else
                    failed "no se pudo actualizar ClamAV"
                fi
            fi
        fi
    fi
fi
}

# =======================================================================
fix_ntp() {
hr "Sincronización horaria (NTP)"
if ! command -v timedatectl >/dev/null 2>&1 || ! systemctl list-unit-files systemd-timesyncd.service >/dev/null 2>&1; then
    failed "systemd-timesyncd no está disponible en este sistema — si se usa chrony u otro cliente NTP, hay que gestionarlo a mano"
else
    NTP_SYNCED=$(timedatectl show -p NTPSynchronized --value 2>/dev/null)
    if [ "$NTP_SYNCED" = "yes" ]; then
        ok "Reloj sincronizado vía NTP"
    else
        if [ "$DRY_RUN" -eq 1 ]; then
            would "activar NTP (timedatectl set-ntp true)"
        elif timedatectl set-ntp true; then
            fixed "NTP activado"
        else
            failed "no se pudo activar NTP"
        fi
    fi

    # El servidor concreto es una decisión de despliegue (NTP_SERVER en
    # .env) — este script nunca elige uno por su cuenta. Si no está
    # definido, se deja fuera del auto-arreglo (ver resumen final).
    if [ -z "$NTP_SERVER" ]; then
        manual "NTP_SERVER no está definido en .env — configúralo y vuelve a ejecutar para fijar el servidor NTP"
    else
        TIMESYNC_SERVER=$(timedatectl timesync-status 2>/dev/null | grep -m1 '^ *Server:' | sed -E 's/^ *Server: *//')
        if printf '%s' "$TIMESYNC_SERVER" | grep -qiF "$NTP_SERVER"; then
            ok "Sincronizando contra el servidor configurado ($NTP_SERVER)"
        else
            CONF=/etc/systemd/timesyncd.conf
            if [ "$DRY_RUN" -eq 1 ]; then
                would "configurar NTP=$NTP_SERVER en $CONF y reiniciar systemd-timesyncd"
            else
                if [ -f "$CONF" ]; then
                    if grep -qE '^\s*#?\s*NTP=' "$CONF"; then
                        sed -i -E "s/^\s*#?\s*NTP=.*/NTP=$NTP_SERVER/" "$CONF"
                    else
                        printf 'NTP=%s\n' "$NTP_SERVER" >> "$CONF"
                    fi
                else
                    printf '[Time]\nNTP=%s\n' "$NTP_SERVER" > "$CONF"
                fi
                if systemctl restart systemd-timesyncd; then
                    fixed "NTP=$NTP_SERVER aplicado y systemd-timesyncd reiniciado"
                else
                    failed "no se pudo reiniciar systemd-timesyncd"
                fi
            fi
        fi
    fi
fi
}

# =======================================================================
fix_ssh() {
hr "SSH (directivas sin riesgo de bloqueo)"
# Solo PermitEmptyPasswords y MaxAuthTries: ninguna de las dos puede
# dejar fuera una sesión legítima (las contraseñas vacías nunca son un
# método de acceso pretendido, y un límite razonable de intentos no
# bloquea credenciales correctas). PermitRootLogin, PasswordAuthentication
# y AllowUsers se dejan fuera a propósito — ver resumen final.
SSHD_T=$(sshd -T 2>&1)
val() { printf '%s\n' "$SSHD_T" | grep -i "^$1 " | awk '{print $2}'; }

EMPTY_OK=0
[ "$(val permitemptypasswords)" = "no" ] && EMPTY_OK=1
MAXAUTH=$(val maxauthtries)
MAXAUTH_OK=0
[ -n "$MAXAUTH" ] && [ "$MAXAUTH" -le 4 ] 2>/dev/null && MAXAUTH_OK=1

DROPIN=/etc/ssh/sshd_config.d/99-fix-security.conf
if [ "$EMPTY_OK" -eq 1 ] && [ "$MAXAUTH_OK" -eq 1 ]; then
    ok "SSH: PermitEmptyPasswords y MaxAuthTries ya correctos"
elif [ "$DRY_RUN" -eq 1 ]; then
    would "escribir $DROPIN (PermitEmptyPasswords no, MaxAuthTries 4) y recargar sshd"
else
    cat > "$DROPIN" <<'EOF'
# Gestionado por fix_security.sh — no editar a mano, se sobrescribe en
# cada ejecución. Solo directivas que nunca pueden causar un bloqueo
# remoto: las contraseñas vacías nunca son un método de acceso legítimo
# pretendido, y un límite razonable de intentos no bloquea credenciales
# correctas.
PermitEmptyPasswords no
MaxAuthTries 4
EOF
    if sshd -t; then
        if systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null; then
            fixed "$DROPIN aplicado y sshd recargado"
        else
            failed "sshd -t OK pero no se pudo recargar el servicio ssh/sshd"
        fi
    else
        rm -f "$DROPIN"
        failed "sshd -t rechazó la configuración generada — no se aplicó nada (revisa si hay otro archivo en sshd_config.d/ con un conflicto, el error puede no ser de este script)"
    fi
fi
}

# =======================================================================
fix_perms() {
hr "Permisos ~/.ssh y directorios home"
REAL_HOME=$(getent passwd "$INVOKING_USER" | cut -d: -f6)
if [ -n "$REAL_HOME" ] && [ -d "$REAL_HOME/.ssh" ]; then
    SSH_DIR_PERM=$(stat -c '%a' "$REAL_HOME/.ssh")
    if [ "$SSH_DIR_PERM" = "700" ]; then
        ok "Permisos de $REAL_HOME/.ssh correctos (700)"
    elif [ "$DRY_RUN" -eq 1 ]; then
        would "chmod 700 $REAL_HOME/.ssh (actual: $SSH_DIR_PERM)"
    elif chmod 700 "$REAL_HOME/.ssh"; then
        fixed "chmod 700 $REAL_HOME/.ssh (era $SSH_DIR_PERM)"
    else
        failed "chmod $REAL_HOME/.ssh"
    fi

    if [ -f "$REAL_HOME/.ssh/authorized_keys" ]; then
        AK_PERM=$(stat -c '%a' "$REAL_HOME/.ssh/authorized_keys")
        if [ "$AK_PERM" = "600" ] || [ "$AK_PERM" = "400" ]; then
            ok "Permisos de authorized_keys correctos ($AK_PERM)"
        elif [ "$DRY_RUN" -eq 1 ]; then
            would "chmod 600 $REAL_HOME/.ssh/authorized_keys (actual: $AK_PERM)"
        elif chmod 600 "$REAL_HOME/.ssh/authorized_keys"; then
            fixed "chmod 600 $REAL_HOME/.ssh/authorized_keys (era $AK_PERM)"
        else
            failed "chmod $REAL_HOME/.ssh/authorized_keys"
        fi
    fi
else
    echo "No existe ~/.ssh para $INVOKING_USER — nada que corregir ahí."
fi

# Directorios home fuera de {700,750}: se lleva a 750, el más permisivo
# de los dos valores que security_check.sh ya acepta como correctos —
# es el único arreglo de este script que podría restringir un acceso
# que hoy funciona (p.ej. algo que dependía de 755).
for d in /root /home/*; do
    [ -d "$d" ] || continue
    PERM=$(stat -c '%a' "$d")
    case "$PERM" in
        700|750) ok "Permisos de $d correctos ($PERM)" ;;
        *)
            if [ "$DRY_RUN" -eq 1 ]; then
                would "chmod 750 $d (actual: $PERM)"
            elif chmod 750 "$d"; then
                fixed "chmod 750 $d (era $PERM)"
            else
                failed "chmod $d"
            fi
            ;;
    esac
done
}

# =======================================================================
# Solo se ejecutan los apartados pedidos (o todos, si no se pidió
# ninguno en concreto) — mismo orden que ALL_SECTIONS / security_check.sh.
for section in $ALL_SECTIONS; do
    contains "$section" "$SECTIONS" && "fix_$section"
done

hr "Resumen"
printf 'Apartados ejecutados: %s\n' "$SECTIONS"
printf 'Arreglados: %d   Ya correctos: %d   Fallos: %d\n' "$FIXED" "$SKIPPED" "$FAILED"
[ "$DRY_RUN" -eq 1 ] && echo "[dry-run, no se aplicó nada]"

if [ "$SECTIONS" = "$ALL_SECTIONS" ]; then
    hr "Requieren revisión manual (nunca se tocan aquí)"
    cat <<'EOF'
Los siguientes hallazgos de security_check.sh no se corrigen en este
script — requieren una decisión humana o implican riesgo de bloqueo
remoto. Vuelve a ejecutar sudo ./scripts/check/security_check.sh y
revísalos:

  - SSH PermitRootLogin / PasswordAuthentication: podrían ser el único
    método de acceso actual — deshabilitarlos a ciegas puede dejarte
    fuera del host.
  - SSH AllowUsers/AllowGroups: exige decidir la lista de usuarios
    permitidos, es una decisión de negocio, no técnica.
  - Firewall: política DROP de INPUT / rate-limit SSH ausente: eso es
    /etc/nftables.conf, un prerrequisito que este repo asume ya existe,
    no algo que host-firewall.sh/docker-user-firewall.sh gestionen.
  - Puertos públicos inesperados: hay que identificar el servicio y
    decidir si es intencional antes de bloquearlo o añadirlo a .env.
  - Archivos world-writable: un chmod a ciegas puede romper software
    legítimo que depende de esos permisos.
  - Binarios SUID/SGID inesperados: podrían ser legítimos o maliciosos
    — requieren inspección manual, nunca hay que quitarles el bit sin
    verificar antes qué son.
  - sudo NOPASSWD:ALL: editar sudoers mal es un riesgo de bloqueo total
    — hay que saber exactamente qué línea/usuario tocar.
  - NTP_SERVER sin definir en .env: elegir el servidor es una decisión
    de despliegue, este script no elige uno por su cuenta.
EOF
fi

if [ "$FAILED" -gt 0 ]; then
    exit 1
fi
exit 0
