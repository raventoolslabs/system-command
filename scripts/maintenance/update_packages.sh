#!/usr/bin/env bash
# Aplica las actualizaciones de paquetes pendientes (apt) — arregla el
# warning "N actualizaciones de paquetes pendientes" de
# check/security_check.sh.
#
# Por qué "upgrade" y no "dist-upgrade"/"full-upgrade": upgrade nunca
# elimina paquetes instalados para resolver dependencias, solo actualiza
# los que ya tienes. Es el modo seguro por defecto en un host con
# servicios corriendo (Docker, bases de datos, almacenamiento...).
#
# Paquetes retenidos ("se han retenido"): apt-get upgrade también se
# niega a INSTALAR paquetes nuevos, y algunas actualizaciones lo exigen
# — el caso típico es el kernel: linux-image-amd64 apunta a una versión
# concreta, y pasar a la siguiente exige instalar el paquete nuevo
# linux-image-<version>-amd64. Para esos casos, en vez de recurrir a un
# dist-upgrade/full-upgrade general (que podría tocar más paquetes de
# los necesarios), este script identifica justo los paquetes que
# quedaron retenidos y les pide su actualización de forma dirigida con
# "apt-get install --only-upgrade".
#
# Nota sobre "phased updates": Debian/Ubuntu a veces retiene una versión
# nueva para un subconjunto de máquinas (rollout gradual), y no hay nada
# que instalar todavía aunque "apt list --upgradable" la cuente como
# pendiente. Si el contador no llega a 0 tras ejecutar este script, puede
# ser justo eso — no es un fallo del script.
#
# Usage: sudo ./update_packages.sh [--dry-run]
set -uo pipefail

DRY_RUN=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        *) echo "Opción desconocida: $arg" >&2; exit 1 ;;
    esac
done

if [ "$EUID" -ne 0 ]; then
    echo "Este script debe ejecutarse con sudo (modifica paquetes del sistema). Abortando." >&2
    exit 1
fi

upgradable_count() {
    apt list --upgradable 2>/dev/null | tail -n +2 | wc -l
}

echo "== Actualizando índices de paquetes (apt-get update) =="
if ! apt-get update -qq; then
    echo "apt-get update falló — revisa los mensajes de arriba antes de continuar." >&2
    exit 1
fi

BEFORE=$(upgradable_count)
echo
echo "Actualizaciones pendientes antes: $BEFORE"

if [ "$BEFORE" -eq 0 ]; then
    echo "Nada que hacer, el sistema ya está al día."
    exit 0
fi

echo
echo "Paquetes con actualización disponible:"
apt list --upgradable 2>/dev/null | tail -n +2

if [ "$DRY_RUN" -eq 1 ]; then
    echo
    echo "[dry-run, no se aplicó nada]"
    exit 0
fi

echo
echo "== Aplicando actualizaciones (apt-get upgrade -y) =="
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
UPGRADE_STATUS=$?

# Paquetes que "upgrade" dejó retenidos porque su actualización requería
# instalar un paquete nuevo (ver nota del kernel arriba). Se leen de
# "apt list --upgradable" (independiente del idioma del sistema) y se
# reintentan uno por uno con --only-upgrade, sin tocar nada más.
mapfile -t HELD_BACK_PKGS < <(apt list --upgradable 2>/dev/null | tail -n +2 | cut -d/ -f1)
if [ "${#HELD_BACK_PKGS[@]}" -gt 0 ]; then
    echo
    echo "== Paquetes retenidos, reintentando con apt-get install --only-upgrade =="
    printf '  - %s\n' "${HELD_BACK_PKGS[@]}"
    if DEBIAN_FRONTEND=noninteractive apt-get install --only-upgrade -y "${HELD_BACK_PKGS[@]}"; then
        :
    else
        echo "No se pudieron resolver todos los paquetes retenidos con --only-upgrade —" \
             "puede que necesiten un dist-upgrade/full-upgrade completo. Revísalos a mano con:" \
             "apt-get dist-upgrade" >&2
        UPGRADE_STATUS=1
    fi
fi

AFTER=$(upgradable_count)

echo
echo "Actualizaciones pendientes después: $AFTER (antes: $BEFORE)"

if [ "$UPGRADE_STATUS" -ne 0 ]; then
    echo "apt-get upgrade terminó con errores (código $UPGRADE_STATUS) — revisa los mensajes de arriba." >&2
fi

if [ "$AFTER" -gt 0 ]; then
    echo "Quedan $AFTER paquete(s) pendientes tras el reintento dirigido. Puede tratarse de" \
         "\"phased updates\" retenidos por Debian/Ubuntu (nada que instalar todavía), o de" \
         "cambios de dependencias que sí requieren un dist-upgrade/full-upgrade completo" \
         "— revísalos con: apt list --upgradable"
fi

if [ -f /var/run/reboot-required ]; then
    echo
    echo "[AVISO] El sistema requiere un reinicio para aplicar completamente las actualizaciones."
    [ -f /var/run/reboot-required.pkgs ] && { echo "Paquetes que lo requieren:"; cat /var/run/reboot-required.pkgs; }
fi

apt-get autoremove -y --purge >/dev/null
apt-get clean

exit "$UPGRADE_STATUS"
