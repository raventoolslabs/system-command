# system-command

Scripts de administración del host: auditoría de seguridad y recursos,
firewall (host y Docker) y mantenimiento de paquetes.

## Requisitos previos

- **`/etc/nftables.conf`** debe existir y ya definir, en `table inet filter`,
  la cadena `input` con política `drop` por defecto, reglas base (loopback,
  conntrack, ICMP, SSH con rate-limit) y un `DROP` final. Ninguno de estos
  scripts crea esa configuración base — `host-firewall.sh` la asume y solo
  añade/retira reglas ACCEPT por puerto sobre ella.
- **`.env`** en la raíz del repo (usa [.env.example](.env.example) como
  plantilla) con `EXPECTED_PORTS`, `DOCKER_ALLOWED_PORTS`,
  `HOST_ALLOWED_PORTS` y `NTP_SERVER`.
- Docker, si se usa, debe instalarse siguiendo la convención del skill
  `docker-install` (compose file + bind mounts en `/opt/docker/<servicio>/`).

## scripts/check/

### `security_check.sh`
Auditoría de seguridad de solo lectura: SSH (`sshd -T`), firewall (política
DROP de `input`, rate-limit SSH, puertos públicos inesperados, fail2ban),
puertos publicados por Docker sin regla en `DOCKER-USER`, actualizaciones de
paquetes pendientes, sincronización horaria (NTP y contra el servidor
declarado en `NTP_SERVER`), antivirus (ClamAV), archivos world-writable,
binarios SUID/SGID inesperados, permisos de `~/.ssh` y home, y sudo
`NOPASSWD:ALL`. No modifica nada.

```bash
sudo ./scripts/check/security_check.sh
```

**No requiere nada adicional** más allá del `.env` — lee `EXPECTED_PORTS`,
`DOCKER_ALLOWED_PORTS` y `HOST_ALLOWED_PORTS` para saber qué puertos
públicos son esperados, y `NTP_SERVER` para saber contra qué servidor NTP
verificar la sincronización horaria (si no está definido, avisa en vez de
asumir uno por defecto).

Cada `[WARNING]` va seguido de una línea `-> ...` con el apartado exacto de
`fix_security.sh` que lo arregla (p.ej. `sudo ./scripts/maintenance/fix_security.sh ssh`),
o con `revisión manual` cuando ese hallazgo no tiene arreglo automático.

### `resource_check.sh`
Chequeo de CPU, RAM/swap y disco, con top 5 procesos por CPU/RAM. No
requiere root ni `.env`.

```bash
./scripts/check/resource_check.sh [--cpu-warn N] [--ram-warn N] [--disk-warn N]
```

## scripts/firewall/

Ambos scripts son **reconciliadores**: en cada ejecución dejan el estado
(reglas ACCEPT) exactamente igual a lo declarado en `.env`, añadiendo lo que
falta y retirando lo que sobra. Se pueden ejecutar tantas veces como se
quiera.

### `host-firewall.sh` — puertos del propio host
Gestiona la cadena `input` (`inet filter`) de nftables: añade/retira reglas
ACCEPT por puerto marcadas con el comentario `"host-firewall"`, sin tocar
nada más de esa cadena (ni siquiera SSH, que tiene su regla fija en
`/etc/nftables.conf` fuera del alcance de este script).

```bash
sudo ./scripts/firewall/host-firewall.sh [--dry-run]
```

Lee `HOST_ALLOWED_PORTS` del `.env`.

### `docker-user-firewall.sh` — puertos publicados por contenedores
Los puertos publicados por Docker (`-p host:cont`) se reenvían vía DNAT +
`FORWARD`/`DOCKER`, que **no pasan por `input`**, así que la política DROP
de arriba no los protege. Este script convierte `DOCKER-USER` (la única
cadena que Docker garantiza no tocar) en una allowlist explícita, con un
`DROP` final.

```bash
sudo ./scripts/firewall/docker-user-firewall.sh
```

Lee `DOCKER_ALLOWED_PORTS` del `.env`.

### ⚠️ Limitación conocida: el `DROP` final también bloquea la salida a internet de los contenedores

`DOCKER-USER` no distingue dirección: Docker la invoca para **todo** el
tráfico que pasa por `FORWARD`, tanto el que entra hacia un puerto
publicado como el que **sale** de un contenedor hacia internet (por
ejemplo, un `apt-get install` dentro de un contenedor). El `DROP`
incondicional que este script deja al final de la cadena solo tenía en
mente el caso de entrada (proteger puertos publicados no autorizados), pero
como efecto secundario también bloquea cualquier conexión *nueva* que un
contenedor intente abrir hacia fuera si su puerto de destino no está en
`DOCKER_ALLOWED_PORTS` — confirmado en producción: con este `DROP` activo,
ningún contenedor del host (en red bridge) tiene salida a internet salvo
los que corran con `network: host`.

Si se quiere permitir la salida de los contenedores sin abrir entrada no
deseada, la solución típica es añadir, **antes** del `DROP` final, una
regla que acepte conexiones nuevas cuyo origen sea una subred de
contenedor Docker y cuyo destino NO sea otra subred de contenedor:

```bash
iptables -A DOCKER-USER -m conntrack --ctstate NEW \
    -s 172.16.0.0/12 ! -d 172.16.0.0/12 -j ACCEPT
```

Esto no está aplicado todavía en `docker-user-firewall.sh` — es una
decisión de postura de seguridad (¿deben los contenedores tener salida
libre a internet por defecto?) que requiere decidirse caso por caso, no
algo que este script deba asumir por su cuenta.

### ⚠️ Configuración adicional obligatoria: instalar los `.service`

Los `.sh` de firewall **no se ejecutan solos en cada arranque** solo por
tener un `.service` en este repo — hay que instalarlos en systemd
explícitamente, una vez, en cada máquina:

```bash
sudo cp scripts/firewall/host-firewall.service /etc/systemd/system/
sudo cp scripts/firewall/docker-user-firewall.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now host-firewall.service
sudo systemctl enable --now docker-user-firewall.service
```

Verifica que quedaron activos:

```bash
systemctl status host-firewall.service docker-user-firewall.service
```

Si `systemctl status <servicio>` responde `Unit ... could not be found`,
no está instalado y **no se ejecutará tras un reinicio** — hay que repetir
los pasos de arriba.

**Cuándo volver a ejecutar el `.sh` a mano**, aunque el `.service` esté
instalado:
- Después de editar `HOST_ALLOWED_PORTS` o `DOCKER_ALLOWED_PORTS` en `.env`
  (los `.service` no se disparan solos con cambios en `.env`).
- Después de publicar/quitar puertos en un contenedor (`docker-user-firewall.sh`).
- **Después de recargar nftables manualmente** (`sudo nft -f /etc/nftables.conf`
  o `systemctl restart nftables`): eso ejecuta `flush ruleset`, que vacía
  también `DOCKER-USER` y las reglas `host-firewall`. `host-firewall.service`
  sí se reactiva solo en este caso (`PartOf=nftables.service`), pero
  `docker-user-firewall.service` no (`PartOf=docker.service`) — hay que
  correr `docker-user-firewall.sh` a mano o `systemctl restart
  docker-user-firewall.service`.

## scripts/maintenance/

### `update_packages.sh`
Aplica actualizaciones de paquetes pendientes (`apt-get upgrade`, nunca
`dist-upgrade`) y resuelve paquetes retenidos por dependencias nuevas
(típicamente el kernel) con `apt-get install --only-upgrade` dirigido.
Corrige el warning "actualizaciones de paquetes pendientes" de
`security_check.sh`.

```bash
sudo ./scripts/maintenance/update_packages.sh [--dry-run]
```

Si al final avisa de que el sistema requiere reinicio
(`/var/run/reboot-required`), recuerda que tras reiniciar hay que volver a
comprobar que `host-firewall.service` y `docker-user-firewall.service`
sigan activos (ver arriba).

### `fix_security.sh`
Auto-remediación de los hallazgos de `security_check.sh` que son mecánicos
y no requieren analizar el caso ni implican riesgo de bloqueo remoto,
organizada en **apartados independientes**:

| Apartado    | Arregla |
|-------------|---------|
| `firewall`  | Relanza `host-firewall.sh` y `docker-user-firewall.sh` — arregla el caso típico de un `nft -f /etc/nftables.conf` que vació `DOCKER-USER` |
| `fail2ban`  | Instala/activa fail2ban |
| `updates`   | Actualizaciones de paquetes pendientes (delega en `update_packages.sh`) |
| `clamav`    | ClamAV: instalación, actualización de firmas (freshclam) y de versión |
| `ntp`       | Activa NTP y lo apunta al servidor de `NTP_SERVER` (si está definido en `.env`) |
| `ssh`       | Directivas que nunca pueden bloquear una sesión legítima: `PermitEmptyPasswords`, `MaxAuthTries`, vía `/etc/ssh/sshd_config.d/99-fix-security.conf` (validado con `sshd -t` antes de recargar) |
| `perms`     | Permisos de `~/.ssh`, `authorized_keys` y directorios home |

```bash
sudo ./scripts/maintenance/fix_security.sh [--dry-run]            # todos los apartados
sudo ./scripts/maintenance/fix_security.sh [--dry-run] ssh perms  # solo estos dos
```

Cada `[WARNING]` de `security_check.sh` indica qué apartado lo arregla (o
si requiere revisión manual), así que lo habitual es lanzar solo el
apartado señalado en vez de todos.

**No toca** `PermitRootLogin`/`PasswordAuthentication`/`AllowUsers`, la
política DROP/rate-limit base de nftables, puertos públicos inesperados,
archivos world-writable, binarios SUID/SGID, sudo `NOPASSWD:ALL`, ni elige
un `NTP_SERVER` si no está definido — todo eso requiere una decisión
humana caso por caso, y el script lo recuerda explícitamente al final (solo
cuando se ejecutan todos los apartados) en vez de tocarlo. Reutiliza
`host-firewall.sh`, `docker-user-firewall.sh` y `update_packages.sh` en vez
de duplicar su lógica, así que sus mismos requisitos previos (`.env`,
`/etc/nftables.conf` base) tienen que estar cumplidos.

## Flujo típico

```bash
cp .env.example .env        # una sola vez, y editar los puertos y NTP_SERVER
sudo ./scripts/firewall/host-firewall.sh
sudo ./scripts/firewall/docker-user-firewall.sh
# instalar los .service (una sola vez por máquina, ver arriba)
sudo ./scripts/check/security_check.sh
sudo ./scripts/maintenance/fix_security.sh --dry-run   # revisar qué cambiaría
sudo ./scripts/maintenance/fix_security.sh             # aplicar lo mecánico
sudo ./scripts/check/security_check.sh                 # confirmar
./scripts/check/resource_check.sh
```
