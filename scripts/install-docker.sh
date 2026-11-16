#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID} -ne 0 ]]; then
	echo "Run this script with sudo: sudo bash scripts/install-docker.sh" >&2
	exit 1
fi

if [[ ! -r /etc/os-release ]]; then
	echo "Cannot identify the operating system." >&2
	exit 1
fi

source /etc/os-release
if [[ ${VERSION_ID:-} != "26.04" ]]; then
	echo "This installer targets Ubuntu 26.04 LTS; detected ${PRETTY_NAME:-unknown}." >&2
	exit 1
fi

# /data è la partizione dati scrivibile; la partizione di sistema diventa in sola
# lettura (overlayroot), quindi nulla di ciò che Docker scrive può stare su /.
if ! mountpoint -q /data; then
	echo "/data must be the separate data partition (see docs/architettura.md)." >&2
	exit 1
fi

if [[ -d /var/lib/docker ]] && find /var/lib/docker -mindepth 1 -print -quit | grep -q .; then
	echo "Existing Docker data found in /var/lib/docker; migrate it deliberately before continuing." >&2
	exit 1
fi

# containerd tiene in /var/lib/containerd il proprio stato e, con l'image store di
# containerd (predefinito nelle nuove installazioni di Docker 29+), i layer delle
# immagini. Lo si collega (bind) a /data così le immagini sopravvivono ai riavvii
# invece di riempire l'overlay in RAM.
install -d -m 0711 /data/containerd /var/lib/containerd
if ! mountpoint -q /var/lib/containerd; then
	if find /var/lib/containerd -mindepth 1 -print -quit | grep -q .; then
		echo "Existing containerd data in /var/lib/containerd; migrate it deliberately before continuing." >&2
		exit 1
	fi
	if ! grep -qE '^[^#]*[[:space:]]/var/lib/containerd[[:space:]]' /etc/fstab; then
		cp -a /etc/fstab "/etc/fstab.bak.$(date +%Y%m%d%H%M%S)"
		echo '/data/containerd /var/lib/containerd none bind,x-systemd.requires-mounts-for=/data 0 0' >> /etc/fstab
		systemctl daemon-reload
	fi
	mount /var/lib/containerd
fi

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends jq

# Scrive daemon.json prima di installare Docker, mettendo i suoi dati sotto /data.
install -d -m 0755 /etc/docker
daemon_config=/etc/docker/daemon.json
if [[ -e ${daemon_config} ]]; then
	jq empty "${daemon_config}"
else
	printf '{}\n' > "${daemon_config}"
fi

# Log dei container: driver "local" (compresso) con rotazione, al massimo
# 3 x 10 MB per container, per proteggere il piccolo SSD.
config_tmp=$(mktemp /etc/docker/daemon.json.XXXXXX)
trap 'rm -f "${config_tmp}"' EXIT
jq '. + {
	"data-root": "/data/docker",
	"log-driver": "local",
	"log-opts": {"max-size": "10m", "max-file": "3"}
}' "${daemon_config}" > "${config_tmp}"
chmod 0644 "${config_tmp}"
mv "${config_tmp}" "${daemon_config}"
trap - EXIT

install -d -m 0711 /data/docker

DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
	docker.io \
	docker-compose-v2

install -d -m 0755 /etc/systemd/system/docker.service.d
cat > /etc/systemd/system/docker.service.d/data-mount.conf <<'EOF'
[Unit]
RequiresMountsFor=/data /var/lib/containerd
EOF
install -d -m 0755 /etc/systemd/system/containerd.service.d
cat > /etc/systemd/system/containerd.service.d/data-mount.conf <<'EOF'
[Unit]
RequiresMountsFor=/var/lib/containerd
EOF

systemctl daemon-reload
systemctl enable docker.service
systemctl restart docker.service

if [[ $(docker info --format '{{.DockerRootDir}}') != "/data/docker" ]]; then
	echo "Docker did not start with /data/docker as its data root." >&2
	exit 1
fi

echo "Docker Engine and Compose are ready; data in /data/docker and /data/containerd"
