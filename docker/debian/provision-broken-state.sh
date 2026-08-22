#!/usr/bin/env bash
# docker/debian/provision-broken-state.sh
#
# Se ejecuta UNA VEZ dentro del contenedor (como root, vía
# `docker compose exec`), tras confirmar que systemd está listo. Deja el
# contenedor en un estado "recién instalado y roto" reproducible:
#
#   - Firewall: se deja en buen estado y LUEGO se rompe deliberadamente con
#     "systemctl restart nftables" (no "nft -f" a pelo — dispara de verdad
#     PartOf=nftables.service en host-firewall.service), reproduciendo el
#     bug documentado en el README: la tabla que contiene DOCKER-USER
#     desaparece por completo (nft flush ruleset borra tablas, no solo
#     reglas), mientras que host-firewall.service SÍ se auto-repara solo.
#   - Usuario de prueba con ~/.ssh y home con permisos inseguros.
#   - NTP desactivado explícitamente (determinista, sin depender de red).
#   - fail2ban y clamav siguen sin instalar (el Dockerfile ya los omite).
#   - SSH sin tocar: los valores compilados por defecto de OpenSSH/Debian
#     (PermitRootLogin prohibit-password, PasswordAuthentication yes,
#     MaxAuthTries 6, sin AllowUsers) ya hacen fallar esos checks solos — no
#     hace falta forzar nada. PermitEmptyPasswords sí sale OK de fábrica
#     (compilado en "no"), tal y como se esperaba.
set -euo pipefail

REPO=/opt/code/system-command
TESTUSER=testuser

echo "== 1/6: confirmando que nftables.service cargó la baseline =="
systemctl is-active --quiet nftables || systemctl restart nftables
# IMPORTANTE: nunca "nft list ruleset | grep -q ..." con pipefail activo —
# grep -q sale en cuanto encuentra la primera coincidencia y cierra el
# pipe; si nft todavía está escribiendo, recibe SIGPIPE y termina con
# estado no-cero, y con pipefail eso hace fallar la tubería entera aunque
# grep SÍ haya encontrado el texto. Por eso se captura primero en una
# variable y se hace grep sobre ella.
RULESET="$(nft list ruleset)"
grep -q 'hook input' <<< "$RULESET" \
    || { echo "FALLO: no se cargó /etc/nftables.conf" >&2; exit 1; }

echo "== 2/6: simulando la cadena DOCKER-USER que crearía dockerd al arrancar =="
iptables -N DOCKER-USER 2>/dev/null || true
iptables -C DOCKER-USER -j DROP 2>/dev/null || iptables -A DOCKER-USER -j DROP

echo "== 3/6: dejando el firewall en estado CORRECTO (una pasada limpia) =="
"$REPO/scripts/firewall/host-firewall.sh"
"$REPO/scripts/firewall/docker-user-firewall.sh"

echo "== instalando y activando los .service (para probar PartOf de verdad) =="
cp "$REPO/scripts/firewall/host-firewall.service" /etc/systemd/system/
cp "$REPO/scripts/firewall/docker-user-firewall.service" /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now host-firewall.service docker-user-firewall.service

echo "--- DOCKER-USER antes del bug ---"
iptables -S DOCKER-USER

echo "== 4/6: reproduciendo el bug documentado =="
systemctl restart nftables
sleep 2

echo "--- input (inet filter) tras el flush + reload de la baseline ---"
nft list chain inet filter input
echo "(las reglas host-firewall deberían haber vuelto solas por PartOf)"

echo "--- DOCKER-USER tras el flush ---"
if iptables -S DOCKER-USER 2>/dev/null; then
    echo "INESPERADO: DOCKER-USER sigue existiendo"
else
    echo "(esperado) DOCKER-USER ya no existe: 'flush ruleset' borra tablas enteras, no solo reglas"
fi

echo "== 5/6: usuario de prueba con permisos inseguros =="
id "$TESTUSER" &>/dev/null || useradd -m -s /bin/bash "$TESTUSER"
install -d -m 777 -o "$TESTUSER" -g "$TESTUSER" "/home/$TESTUSER/.ssh"
printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIsimuladornousar simulador\n' \
    > "/home/$TESTUSER/.ssh/authorized_keys"
chown "$TESTUSER:$TESTUSER" "/home/$TESTUSER/.ssh/authorized_keys"
chmod 644 "/home/$TESTUSER/.ssh/authorized_keys"
chmod 755 "/home/$TESTUSER"

echo "== 6/6: NTP desactivado explícitamente (determinista, sin depender de red) =="
timedatectl set-ntp false

echo
echo "Estado inicial aprovisionado. Puntos deliberadamente rotos:"
echo "  - DOCKER-USER SIN TABLA (bug del flush): fix_security.sh firewall NO"
echo "    la recrea sola — hace falta simular 'reiniciar Docker' (iptables -N"
echo "    DOCKER-USER) antes, exactamente como pide el README en producción."
echo "  - fail2ban / ClamAV no instalados."
echo "  - NTP desactivado."
echo "  - ~/.ssh de $TESTUSER en 777, authorized_keys en 644, home en 755."
echo "  - SSH con los valores compilados por defecto (no tocado)."
