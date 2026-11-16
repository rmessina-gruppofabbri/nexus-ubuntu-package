#!/usr/bin/env bash
# Controllo della partizione di sistema in sola lettura (overlayroot).
# Installato come /usr/local/sbin/hmi-rootfs.
#
#   hmi-rootfs status                 modalità attuale e del prossimo avvio
#   hmi-rootfs disable [--reboot]     prossimo avvio: sistema scrivibile (manutenzione)
#   hmi-rootfs enable  [--reboot]     prossimo avvio: sistema in sola lettura (produzione)
#   hmi-rootfs upgrade                in manutenzione: aggiorna il SO, fa pulizia,
#                                     riattiva la sola lettura e riavvia
#   hmi-rootfs check-initramfs        verifica che ogni initramfs contenga overlayroot
#
# In sola lettura ogni modifica a / resta in RAM e si perde al riavvio.
# /data (Docker, PostgreSQL, progetto Compose, journal) è sempre scrivibile.
# Emergenza: nel menu di GRUB premere e, aggiungere overlayroot=disabled alla
# riga linux e avviare: una volta sola il sistema sarà scrivibile.
set -Eeuo pipefail

readonly_value='tmpfs:swap=1,recurse=0'
lower=/media/root-ro

usage() {
	awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0" >&2
	exit 2
}

if [[ ${EUID} -ne 0 ]]; then
	echo "Run with sudo: sudo hmi-rootfs $*" >&2
	exit 1
fi

overlay_active() {
	[[ $(findmnt -no FSTYPE /) == overlay ]]
}

# Cartella che contiene la /etc reale della partizione di sistema.
config_root() {
	local found
	if overlay_active; then
		if ! mountpoint -q "${lower}"; then
			# Ripiego: etichetta della partizione di sistema impostata dall'installer.
			found=$(findmnt -rno TARGET -S LABEL=hmi-root | head -n 1)
			if [[ -z ${found} ]]; then
				echo "Overlay active but the real system partition is not mounted; cannot reach it." >&2
				exit 1
			fi
			lower=${found}
		fi
		echo "${lower}"
	fi
}

conf_value() {
	local file
	file="$(config_root)/etc/overlayroot.conf"
	[[ -f ${file} ]] || { echo "(overlayroot not installed)"; return; }
	sed -n 's/^overlayroot="\{0,1\}\([^"]*\)"\{0,1\}[[:space:]]*$/\1/p' "${file}" | tail -n 1
}

set_conf() {
	local value=$1 root file
	root=$(config_root)
	file="${root}/etc/overlayroot.conf"
	if [[ ! -f ${file} ]]; then
		echo "${file} not found; install overlayroot first (scripts/setup-readonly-root.sh)." >&2
		exit 1
	fi
	if [[ -n ${root} ]]; then
		mount -o remount,rw "${root}"
	fi
	if grep -q '^overlayroot=' "${file}"; then
		sed -i "s|^overlayroot=.*|overlayroot=\"${value}\"|" "${file}"
	else
		printf 'overlayroot="%s"\n' "${value}" >> "${file}"
	fi
	sync
	if [[ -n ${root} ]]; then
		mount -o remount,ro "${root}" || echo "Warning: could not remount ${root} read-only; it will be at reboot." >&2
	fi
}

# /etc/overlayroot.conf viene letto solo dallo script di overlayroot per
# initramfs-tools. Con dracut (predefinito su Ubuntu 26.04) il file è ignorato e
# il sistema resterebbe scrivibile qualunque cosa dica la configurazione.
# Stampa gli initramfs che non vanno bene; esce con 1 se ce n'è almeno uno.
initramfs_problems() {
	local initrd contents bad=0
	for initrd in /boot/initrd.img-*; do
		[[ -e ${initrd} ]] || continue
		contents=$(lsinitramfs "${initrd}" 2>/dev/null) || contents=
		if ! grep -q 'scripts/init-bottom/overlayroot$' <<<"${contents}"; then
			if grep -q 'var/lib/dracut' <<<"${contents}"; then
				echo "${initrd}: built by dracut, /etc/overlayroot.conf is ignored"
			else
				echo "${initrd}: overlayroot script missing"
			fi
			bad=1
		fi
	done
	return "${bad}"
}

initramfs_fix_hint() {
	echo "Fix (in maintenance mode): sudo apt install initramfs-tools overlayroot && sudo update-initramfs -u -k all" >&2
}

check_initramfs() {
	local problems
	if problems=$(initramfs_problems); then
		return 0
	fi
	echo "The read-only mode would NOT start at boot:" >&2
	sed 's/^/  /' <<<"${problems}" >&2
	initramfs_fix_hint
	return 1
}

maybe_reboot() {
	if [[ ${1:-} == --reboot ]]; then
		echo "Rebooting..."
		systemctl reboot
	else
		echo "Takes effect at the next reboot (sudo reboot)."
	fi
}

status() {
	local next problems
	if overlay_active; then
		echo "Now:        READ-ONLY (changes to / are in RAM and lost at reboot)"
		df -h / | awk 'NR==2{print "RAM overlay: " $3 " used of " $2}'
	else
		echo "Now:        WRITABLE (maintenance mode)"
	fi
	next=$(conf_value)
	if [[ -n ${next} && ${next} != disabled && ${next} != "(overlayroot not installed)" ]]; then
		if problems=$(initramfs_problems); then
			echo "Next boot:  READ-ONLY (overlayroot=\"${next}\")"
		else
			echo "Next boot:  WRITABLE (configured read-only, but the initramfs cannot apply it)"
			sed 's/^/            /' <<<"${problems}"
			initramfs_fix_hint
		fi
	else
		echo "Next boot:  WRITABLE"
	fi
	findmnt -no SOURCE,FSTYPE,OPTIONS /data | awk '{print "/data:      " $1 " " $2 " " $3}'
}

case ${1:-} in
	status) status ;;
	check-initramfs) check_initramfs ;;
	enable)
		if ! mountpoint -q /data; then
			echo "/data is not mounted; refusing to make the system read-only." >&2
			exit 1
		fi
		check_initramfs
		set_conf "${readonly_value}"
		echo "Read-only system enabled."
		maybe_reboot "${2:-}"
		;;
	disable)
		set_conf ""
		echo "Read-only system disabled (maintenance mode)."
		maybe_reboot "${2:-}"
		;;
	upgrade)
		if overlay_active; then
			echo "The system is read-only now. First run: sudo hmi-rootfs disable --reboot" >&2
			exit 1
		fi
		export DEBIAN_FRONTEND=noninteractive
		apt-get update
		apt-get -y -o Dpkg::Options::=--force-confold full-upgrade
		apt-get -y autoremove --purge
		apt-get clean
		df -h /
		# Un aggiornamento non deve riportare dracut: senza overlayroot
		# nell'initramfs la sola lettura non ripartirebbe.
		check_initramfs
		set_conf "${readonly_value}"
		echo "System updated; read-only mode re-enabled."
		maybe_reboot --reboot
		;;
	*) usage ;;
esac
