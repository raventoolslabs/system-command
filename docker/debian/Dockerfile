# docker/debian/Dockerfile
#
# Debian 13 (trixie) "desde cero" con systemd real como PID 1, para poder
# ejecutar los scripts de /opt/code/system-command tal y como se comportan
# en un host real (systemctl, sshd -T, timedatectl, nft, iptables-nft).
#
# Deliberadamente NO se instalan fail2ban ni clamav aquí: así el estado
# recién aprovisionado falla esos checks de security_check.sh de forma
# natural, igual que en un Debian recién instalado — fix_security.sh es
# quien debe instalarlos.
FROM debian:trixie

ENV DEBIAN_FRONTEND=noninteractive \
    container=docker

RUN apt-get update && apt-get install -y --no-install-recommends \
        systemd \
        systemd-sysv \
        systemd-timesyncd \
        dbus \
        openssh-server \
        nftables \
        iptables \
        sudo \
        python3 \
        procps \
        iproute2 \
        findutils \
        gawk \
        ca-certificates \
        less \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Unidades que no tienen sentido (o fallan) dentro de un contenedor: no hay
# ttys reales, systemd-udevd no puede gestionar el /sys de un host
# compartido, y cargar módulos de kernel exige CAP_SYS_MODULE que no se
# concede aquí.
RUN systemctl mask \
        systemd-udevd.service \
        systemd-udevd-kernel.socket \
        systemd-udev-trigger.service \
        systemd-tmpfiles-setup-dev.service \
        systemd-modules-load.service \
        systemd-remount-fs.service \
        getty.target \
        console-getty.service \
        dev-hugepages.mount \
        sys-fs-fuse-connections.mount

# ssh y nftables deben arrancar solos al iniciar el contenedor, igual que en
# un host real tras "systemctl enable --now" (openssh-server ya generó las
# host keys en su postinst durante este mismo build).
RUN systemctl enable ssh nftables

STOPSIGNAL SIGRTMIN+3

CMD ["/lib/systemd/systemd"]
