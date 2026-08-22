# Simulador Debian 13 (Docker) para `system-command`

Simulador aislado, **solo para pruebas**, que levanta un contenedor Debian
13 (trixie) con systemd real y ejecuta ahí `security_check.sh` y
`fix_security.sh` para validar que:

1. En un sistema recién aprovisionado, `security_check.sh` reporta varios
   `[WARNING]`.
2. Tras correr `fix_security.sh`, un segundo `security_check.sh` confirma
   que los apartados arreglables (`ssh`, `perms`, y `fail2ban`/`clamav`/`ntp`
   si el contenedor tiene salida a internet) quedan en `[ OK ]`.
3. El bug documentado en el README principal — un `nft -f
   /etc/nftables.conf` (`flush ruleset`) borra por completo la tabla que
   contiene `DOCKER-USER`, y `docker-user-firewall.service` no se reactiva
   solo — se reproduce y se repara en el mismo orden que en producción:
   primero "reiniciar Docker" (recrear la cadena), luego relanzar
   `docker-user-firewall.sh` / `fix_security.sh firewall`.

### Hallazgo real de paso: `docker-user-firewall.sh` no reporta bien sus fallos

Ejecutando el simulador salió a la luz que `docker-user-firewall.sh` no
tiene `set -e` y su última instrucción es un `echo` que siempre sale con
éxito — así que si la cadena `DOCKER-USER` no existe (justo el caso del
bug), **todos** sus `iptables` fallan pero el script igualmente termina con
código de salida 0, y `fix_security.sh` lo reporta como `[ + ] arreglado`
aunque no haya arreglado nada. `run-simulation.sh` no se fía de ese mensaje:
comprueba el estado real de `DOCKER-USER` con `iptables -S` antes y después
de cada intento.

## Uso

```bash
cd /opt/code/system-command/docker/debian
./run-simulation.sh --reset
```

Esto construye la imagen, levanta el contenedor, espera a que systemd/ssh/
nftables estén listos, aprovisiona el estado roto, corre
`security_check.sh` (antes), corre `fix_security.sh`, hace la recuperación
en dos pasos del bug de `DOCKER-USER`, corre `security_check.sh` (después)
y termina con un resumen `PASS`/`FAIL`. Los logs de cada paso quedan en
`./logs/`. Al terminar apaga el contenedor (`docker compose down`); usa
`--keep-up` para dejarlo arriba y explorar a mano.

Si en tu host los contenedores no tienen salida a internet por el motivo
descrito más abajo (el propio `DOCKER-USER` bloqueándola), añade
`--allow-egress`:

```bash
./run-simulation.sh --reset --allow-egress
```

Esto inserta TEMPORALMENTE, en el `DOCKER-USER` del **host real** (no del
contenedor), una regla que permite salida nueva desde cualquier contenedor
Docker del host — no solo el del simulador — mientras corren
`fail2ban`/`clamav`/`ntp`, y la quita justo después (con un `trap`, así que
se quita también si el script falla a mitad). Con esto, esos tres apartados
pasan a exigirse igual que el resto en el resumen final. Necesita `sudo`
sin contraseña para `iptables -I/-D DOCKER-USER ...`; si no lo tienes,
avisa y sigue sin la regla.

Para explorar el contenedor directamente:

```bash
docker compose up -d --build
docker compose exec debian bash
```

## Qué NO simula (limitaciones deliberadas)

- **No hay Docker real dentro del contenedor** (nada de Docker-in-Docker):
  la cadena `DOCKER-USER` se crea a mano con `iptables`, igual que lo
  haría `dockerd` al arrancar. Consecuencia: la sección "Docker: puertos
  reenviados" de `security_check.sh` siempre sale `OK: no aplica` (no
  detecta el comando `docker` activo) — el bug de `DOCKER-USER` se valida
  inspeccionando `iptables` directamente en `run-simulation.sh`, no por esa
  sección.
- **fail2ban, ClamAV y la sincronización NTP real necesitan que el
  CONTENEDOR YA ARRANCADO tenga salida a internet** (`apt-get install`, y el
  chequeo de offset NTP). El contenedor corre en la red bridge normal de
  Docker (nunca `network_mode: host`, por seguridad — ver más abajo).
  **Causa confirmada en este host** (no es una generalidad de "algunos
  sandboxes", se verificó con contadores de `nft`): el propio
  `docker-user-firewall.sh` de este repo, ya desplegado y gestionando
  `DOCKER_ALLOWED_PORTS`, deja la cadena `DOCKER-USER` con un `DROP`
  incondicional al final — y esa cadena la invoca Docker para **todo** el
  tráfico `FORWARD`, no solo el entrante hacia puertos publicados, así que
  también atrapa la salida a internet de cualquier contenedor del host
  (bridge). Ver la limitación documentada en el README principal
  (`../../README.md`, sección `docker-user-firewall.sh`) para el detalle y
  la regla que la resolvería si se decide aplicarla. El *build* de la
  imagen sí usa `network: host` explícitamente en el compose para no
  depender de esto. La parte de configuración de NTP (activar
  `systemd-timesyncd`, escribir `NTP_SERVER` en `timesyncd.conf`) es 100%
  determinista y se prueba igual, tenga o no red el contenedor. Aparte del
  `DROP` de `DOCKER-USER`, en este host concreto el DNS embebido de Docker
  (`127.0.0.11`, al que apuntaría el `/etc/resolv.conf` que Docker genera
  por defecto) tampoco respondía — confirmado con un contenedor `busybox`
  aparte, nada específico de este repo. `docker-compose.yml` monta
  `resolv.conf.simulator` directo a DNS público para saltárselo; si en tu
  host el DNS embebido de Docker sí funciona, ese mount es inofensivo.
- **`systemd-timesyncd` no arranca dentro de un contenedor** —
  `ConditionVirtualization=!container` viene así en el `.service` de
  fábrica (asume que un contenedor debe heredar la hora del host), así que
  `timedatectl timesync-status` nunca tiene servidor que mostrar aquí,
  aunque `fix_security.sh ntp` esté aplicado correctamente.
  `security_check.sh` ya lo detecta (`systemd-detect-virt --container`) y
  lo marca `OK: no aplica` en vez de un `WARNING` engañoso — la
  sincronización real se valida por separado con una consulta NTP directa
  (necesita salida a internet, ver punto anterior).
- **Actualizaciones de apt pendientes**: best-effort, depende de si el
  mirror de Debian tiene paquetes más nuevos que la imagen en el momento
  del build.
- Requiere que el **kernel del host** Docker soporte `nf_tables` y los
  namespaces necesarios — responsabilidad del host, no de este compose.
  El contenedor corre `privileged: true` (systemd real + nftables/iptables
  reales) — válido solo para este simulador de pruebas, nunca como patrón
  de despliegue de servicios reales (para eso está la convención del skill
  `docker-install`, en `/opt/docker/<servicio>/`).

## Archivos

- `Dockerfile` — Debian 13 + systemd + paquetes base (sin fail2ban/clamav a
  propósito).
- `docker-compose.yml` — contenedor privilegiado con el repo montado de
  solo lectura en `/opt/code/system-command` (la ruta que hardcodean los
  `.service` de firewall) y un `.env` de prueba propio montado encima,
  **sin tocar nunca** el `.env` real del repo en el host.
- `nftables.conf` — baseline mínima que el README principal exige como
  prerrequisito (tabla `inet filter`, cadena `input` DROP + rate-limit SSH).
- `.env.simulator` — valores de prueba (`EXPECTED_PORTS`,
  `DOCKER_ALLOWED_PORTS`, `HOST_ALLOWED_PORTS`, `NTP_SERVER`).
- `provision-broken-state.sh` — dentro del contenedor, deja el estado
  inicial roto de forma reproducible.
- `run-simulation.sh` — orquestador end-to-end con resumen `PASS`/`FAIL`.
