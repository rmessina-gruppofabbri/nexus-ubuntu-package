#!/usr/bin/env bash
# Ottimizzazione per 2 GB di RAM e un piccolo SSD iSLC: swap compresso in RAM (zram),
# nessun file di swap su disco e limite di dimensione al journal di systemd.
set -Eeuo pipefail

if [[ ${EUID} -ne 0 ]]; then
	echo "Run this script with sudo: sudo bash scripts/tune-system.sh" >&2
	exit 1
fi

if [[ ! -r /etc/os-release ]]; then
	echo "Cannot identify the operating system." >&2
	exit 1
fi

source /etc/os-release
if [[ ${VERSION_ID:-} != "26.04" ]]; then
	echo "This script targets Ubuntu 26.04 LTS; detected ${PRETTY_NAME:-unknown}." >&2
	exit 1
fi

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends zram-tools

# zram: metà della RAM come swap compresso, preferito a qualsiasi swap su disco.
cat > /etc/default/zramswap <<'EOF'
ALGO=zstd
PERCENT=50
PRIORITY=100
EOF
systemctl enable zramswap.service
systemctl restart zramswap.service

# Con lo swap in RAM usarlo presto costa poco; il read-ahead non porta benefici.
cat > /etc/sysctl.d/60-zram.conf <<'EOF'
vm.swappiness=100
vm.page-cluster=0
EOF
sysctl --system >/dev/null

# L'installer di Ubuntu crea /swap.img sul filesystem root se non esiste una
# partizione di swap. Lo rimuoviamo: occupa ~2 GB dei 16 GB dell'SSD e lo usura.
if grep -qE '^[[:space:]]*/swap\.img[[:space:]]' /etc/fstab; then
	cp -a /etc/fstab "/etc/fstab.bak.$(date +%Y%m%d%H%M%S)"
	if swapon --show=NAME --noheadings | grep -qx /swap.img; then
		swapoff /swap.img
	fi
	sed -i -E 's|^([[:space:]]*/swap\.img[[:space:]].*)$|# disattivato da tune-system.sh (zram in uso): \1|' /etc/fstab
	rm -f /swap.img
	systemctl daemon-reload
fi

# Rete: per default systemd-networkd-wait-online aspetta che TUTTE le interfacce
# configurate da netplan siano online, fino a 120 s. Una porta senza cavo o senza
# risposta DHCP blocca così Docker (che richiede network-online.target), quindi
# HMI e kiosk, per due minuti a ogni avvio. Basta un'interfaccia, al massimo 15 s.
# Il nome del file viene dopo il 10-netplan.conf generato da netplan e lo sostituisce.
install -d -m 0755 /etc/systemd/system/systemd-networkd-wait-online.service.d
cat > /etc/systemd/system/systemd-networkd-wait-online.service.d/90-hmi.conf <<'EOF'
[Service]
ExecStart=
ExecStart=/usr/lib/systemd/systemd-networkd-wait-online --any --timeout=15
EOF
systemctl daemon-reload

# Le porte Ethernet senza cavo durante il provisioning (es. la seconda porta per
# la rete di fabbrica) diventano optional in netplan: restano configurate, ma
# l'avvio non le aspetta. La porta usata per l'installazione ha il cavo e resta
# obbligatoria. Vale dal prossimo avvio (netplan generate, nessun apply).
if command -v netplan >/dev/null 2>&1; then
	netplan_changed=false
	for iface in $(netplan get ethernets 2>/dev/null | grep -oE '^[A-Za-z0-9_.-]+(:)' | tr -d ':'); do
		[[ -r /sys/class/net/${iface}/carrier ]] || continue
		[[ $(cat "/sys/class/net/${iface}/carrier" 2>/dev/null) == 1 ]] && continue
		[[ $(netplan get "ethernets.${iface}.optional" 2>/dev/null) == true ]] && continue
		netplan set "ethernets.${iface}.optional=true"
		netplan_changed=true
		echo "netplan: ${iface} has no cable, marked optional (boot will not wait for it)"
	done
	if [[ ${netplan_changed} == true ]]; then
		netplan generate
	fi
fi

# Journal: persistente (utile dopo un guasto) ma con un limite di dimensione.
install -d -m 0755 /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/50-size-limit.conf <<'EOF'
[Journal]
SystemMaxUse=50M
SystemKeepFree=500M
RuntimeMaxUse=30M
EOF
systemctl restart systemd-journald.service

echo
swapon --show
echo
echo "zram swap enabled, disk swap file removed, journal capped at 50 MB."
