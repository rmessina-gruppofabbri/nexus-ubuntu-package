#!/usr/bin/env bash
# Rimuove pacchetti e servizi che non servono a un kiosk industriale in sola
# lettura: meno spazio sulla partizione di sistema da 6 GB, meno RAM, meno cose
# da aggiornare.
#
# Regola di sicurezza: un pacchetto viene rimosso solo se una simulazione mostra
# che apt non toglierebbe nulla oltre ai pacchetti richiesti (più i metapacchetti
# ammessi esplicitamente). Tutto il resto viene saltato e scritto nel log.
#
# Variabili d'ambiente:
#   HMI_KEEP_SNAPD=1   mantiene snapd e gli snap installati
set -Eeuo pipefail

if [[ ${EUID} -ne 0 ]]; then
	echo "Run this script with sudo: sudo bash scripts/slim-system.sh" >&2
	exit 1
fi

export DEBIAN_FRONTEND=noninteractive

installed() {
	dpkg-query -W -f '${db:Status-Abbrev}' "$1" 2>/dev/null | grep -q '^ii'
}

# safe_purge "rimozioni aggiuntive ammesse (regex)" pacchetto...
safe_purge() {
	local allowed=$1
	shift
	local wanted=() pkg removals extra
	for pkg in "$@"; do
		installed "${pkg}" && wanted+=("${pkg}")
	done
	[[ ${#wanted[@]} -eq 0 ]] && return 0

	removals=$(apt-get -s purge "${wanted[@]}" | awk '/^(Remv|Purg) /{print $2}')
	extra=$(printf '%s\n' "${removals}" | grep -vxF -f <(printf '%s\n' "${wanted[@]}") || true)
	if [[ -n ${allowed} ]]; then
		extra=$(printf '%s\n' "${extra}" | grep -vxE "${allowed}" || true)
	fi
	if [[ -n ${extra} ]]; then
		echo "Skipping ${wanted[*]}: would also remove: $(echo ${extra})"
		return 0
	fi
	echo "Purging ${wanted[*]}"
	apt-get purge -y "${wanted[@]}"
}

# È presente un produttore PCI (vendor[:prefisso di classe]) o USB?
has_pci_vendor() {
	local vendor=$1 class_prefix=${2:-} dev
	for dev in /sys/bus/pci/devices/*; do
		[[ -r ${dev}/vendor ]] || continue
		[[ $(<"${dev}/vendor") == "${vendor}" ]] || continue
		[[ -z ${class_prefix} || $(<"${dev}/class") == "${class_prefix}"* ]] && return 0
	done
	return 1
}
has_usb_vendor() {
	grep -qsx "$1" /sys/bus/usb/devices/*/idVendor
}

echo "== Services and tools not needed on a read-only kiosk"
# unattended-upgrades/timer di apt: con la root in sola lettura gli aggiornamenti
# andrebbero persi al riavvio e riempirebbero solo l'overlay in RAM. Si aggiorna
# nella manutenzione programmata (hmi-rootfs disable). rsyslog duplica il journal
# persistente.
safe_purge '' unattended-upgrades
safe_purge '' rsyslog
safe_purge '' bpftrace
safe_purge '' apport apport-symptoms whoopsie
safe_purge '' modemmanager
safe_purge '' udisks2
safe_purge '' multipath-tools
safe_purge '' fwupd
safe_purge '' packagekit
safe_purge '' landscape-common
safe_purge '' popularity-contest

if [[ ${HMI_KEEP_SNAPD:-0} != 1 ]] && installed snapd; then
	echo "Installed snaps (removed together with snapd):"
	snap list 2>/dev/null || true
	safe_purge '' snapd
	installed snapd || rm -rf /root/snap /home/*/snap /var/cache/snapd
fi
if installed snapd; then
	# Mantenuto (su richiesta o perché serve a un metapacchetto): blocca gli
	# aggiornamenti automatici, che scaricherebbero nell'overlay in RAM a ogni avvio.
	snap refresh --hold >/dev/null 2>&1 || true
	echo "snapd kept; automatic snap refreshes held."
fi
if installed unattended-upgrades; then
	systemctl disable --now unattended-upgrades.service >/dev/null 2>&1 || true
fi

for unit in apt-daily.timer apt-daily-upgrade.timer motd-news.timer \
	man-db.timer fwupd-refresh.timer update-notifier-download.timer \
	update-notifier-motd.timer; do
	if systemctl list-unit-files "${unit}" --no-legend 2>/dev/null | grep -q .; then
		systemctl disable --now "${unit}" >/dev/null 2>&1 || true
		systemctl mask "${unit}" >/dev/null 2>&1 || true
		echo "Disabled ${unit}"
	fi
done

# cloud-init serve solo per l'installazione; dopo non è più necessario.
if [[ -d /etc/cloud ]]; then
	touch /etc/cloud/cloud-init.disabled
fi

echo "== Firmware for hardware not present in this PC"
# Il metapacchetto linux-firmware si porta dietro i pacchetti di tutti i
# produttori. I rimanenti vengono segnati come installati manualmente, così
# autoremove li conserva, poi si consente la rimozione del metapacchetto stesso.
mapfile -t firmware_pkgs < <(dpkg-query -W -f '${db:Status-Abbrev} ${Package}\n' 'linux-firmware-*' 2>/dev/null | awk '/^ii/{print $2}')
if [[ ${#firmware_pkgs[@]} -gt 0 ]]; then
	apt-mark manual "${firmware_pkgs[@]}" >/dev/null
fi
firmware_remove=()
has_pci_vendor 0x10de || firmware_remove+=(linux-firmware-nvidia-graphics)
has_pci_vendor 0x15b3 || firmware_remove+=(linux-firmware-mellanox-spectrum)
if ! has_pci_vendor 0x17cb && ! has_pci_vendor 0x168c && ! has_usb_vendor 0cf3 && ! has_usb_vendor 05c6; then
	firmware_remove+=(linux-firmware-qualcomm-misc linux-firmware-qualcomm-wireless)
fi
# Il Wi-Fi Intel è un controller di rete PCI di classe 0x0280; il Bluetooth Intel è USB 8087.
if ! has_pci_vendor 0x8086 0x0280 && ! has_usb_vendor 8087; then
	firmware_remove+=(linux-firmware-intel-wireless)
fi
for pkg in "${firmware_remove[@]}"; do
	safe_purge 'linux-firmware' "${pkg}"
done

echo "== Kernel headers (only needed to build modules with DKMS)"
if ! installed dkms; then
	# Gli aggiornamenti del kernel continuano ad arrivare tramite linux-image-generic
	# anche dopo la rimozione del metapacchetto linux-generic (che porta gli header).
	installed linux-image-generic && apt-mark manual linux-image-generic >/dev/null
	mapfile -t header_pkgs < <(dpkg-query -W -f '${db:Status-Abbrev} ${Package}\n' 'linux-headers-*' 2>/dev/null | awk '/^ii/{print $2}')
	if [[ ${#header_pkgs[@]} -gt 0 ]]; then
		if installed linux-image-generic; then
			safe_purge 'linux-generic|linux-headers-.*' "${header_pkgs[@]}"
		else
			echo "Skipping headers: linux-image-generic is not installed."
		fi
	fi
fi

echo "== Cleanup"
apt-get autoremove --purge -y
mapfile -t residual < <(dpkg -l | awk '/^rc/{print $2}')
if [[ ${#residual[@]} -gt 0 ]]; then
	apt-get purge -y "${residual[@]}"
fi
# Cartelle dei moduli rimaste da kernel non più installati.
for dir in /usr/lib/modules/*; do
	[[ -d ${dir} ]] || continue
	version=${dir##*/}
	if [[ ! -e /boot/vmlinuz-${version} ]] && [[ ${version} != "$(uname -r)" ]]; then
		echo "Removing leftover ${dir}"
		rm -rf "${dir}"
	fi
done
apt-get clean
journalctl --vacuum-size=50M >/dev/null 2>&1 || true

echo
df -h /
echo "System slimmed down."
