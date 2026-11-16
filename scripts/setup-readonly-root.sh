#!/usr/bin/env bash
# Prepara la partizione di sistema in sola lettura (overlayroot) e la attiva dal
# prossimo avvio. Va eseguito per ultimo nel provisioning, dopo aver installato
# tutti i pacchetti.
#
# Variabili d'ambiente:
#   HMI_READONLY_ROOT=0   installa tutto ma lascia il sistema scrivibile
set -Eeuo pipefail

if [[ ${EUID} -ne 0 ]]; then
	echo "Run this script with sudo: sudo bash scripts/setup-readonly-root.sh" >&2
	exit 1
fi

if ! mountpoint -q /data; then
	echo "/data must be the separate data partition before enabling a read-only system." >&2
	exit 1
fi

if [[ $(findmnt -no FSTYPE /) == overlay ]]; then
	echo "The system is already read-only; run this in maintenance mode (hmi-rootfs disable)." >&2
	exit 1
fi

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

apt-get update
# Con dracut (predefinito su Ubuntu 26.04) overlayroot legge solo il parametro
# overlayroot= della riga di comando del kernel e ignora /etc/overlayroot.conf:
# hmi-rootfs enable non avrebbe effetto. Con initramfs-tools (che rimuove dracut)
# il file viene letto dalla partizione di sistema a ogni avvio.
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
	initramfs-tools overlayroot
if dpkg-query -W -f '${db:Status-Abbrev}' dracut 2>/dev/null | grep -q '^ii'; then
	echo "dracut is still installed; overlayroot would ignore /etc/overlayroot.conf." >&2
	exit 1
fi
update-initramfs -u -k all

# GRUB segna recordfail=1 in /boot/grub/grubenv a ogni avvio; a sistema avviato
# grub-common lo azzera, ma con la root in sola lettura la scrittura finisce
# nell'overlay in RAM e si perde. Al riavvio GRUB crederebbe sempre che l'avvio
# precedente sia fallito e mostrerebbe il menu per GRUB_RECORDFAIL_TIMEOUT
# (30 s su Ubuntu) a ogni accensione. Il menu resta raggiungibile con Esc.
install -d -m 0755 /etc/default/grub.d
cat > /etc/default/grub.d/90-hmi-readonly.cfg <<'EOF'
# hmi: con overlayroot recordfail non viene mai azzerato su disco (vedi setup-readonly-root.sh)
GRUB_RECORDFAIL_TIMEOUT=0
EOF
chmod 0644 /etc/default/grub.d/90-hmi-readonly.cfg
update-grub
grub-editenv /boot/grub/grubenv unset recordfail 2>/dev/null || true
# I servizi che azzerano recordfail/initrdfail in grubenv falliscono sull'overlay
# (grub-editenv non riconosce il filesystem) e comunque scriverebbero solo in RAM:
# con la sola lettura attiva (/media/root-ro montato) vengono saltati.
for unit in grub-common.service grub-initrd-fallback.service; do
	install -d -m 0755 "/etc/systemd/system/${unit}.d"
	cat > "/etc/systemd/system/${unit}.d/90-hmi-readonly.conf" <<'EOF'
[Unit]
ConditionPathIsMountPoint=!/media/root-ro
EOF
done
systemctl daemon-reload

# Journal persistente su /data: i log sopravvivono a riavvii e guasti anche se
# / è in sola lettura. I limiti di dimensione vengono da tune-system.sh (journald.conf.d).
install -d -m 2755 -g systemd-journal /data/log/journal
if ! mountpoint -q /var/log/journal; then
	install -d -m 2755 -g systemd-journal /var/log/journal
	cp -a /var/log/journal/. /data/log/journal/
	if ! grep -qE '^[^#]*[[:space:]]/var/log/journal[[:space:]]' /etc/fstab; then
		cp -a /etc/fstab "/etc/fstab.bak.$(date +%Y%m%d%H%M%S)"
		echo '/data/log/journal /var/log/journal none bind,x-systemd.requires-mounts-for=/data 0 0' >> /etc/fstab
		systemctl daemon-reload
	fi
	mount /var/log/journal
	systemd-tmpfiles --create --prefix /var/log/journal >/dev/null 2>&1 || true
	systemctl restart systemd-journald.service
fi

install -m 0755 "${script_dir}/hmi-rootfs.sh" /usr/local/sbin/hmi-rootfs
# Si ferma qui se un initramfs non contiene lo script di overlayroot.
hmi-rootfs check-initramfs

if [[ ${HMI_READONLY_ROOT:-1} == 0 ]]; then
	hmi-rootfs disable
	echo "HMI_READONLY_ROOT=0: system left writable. Enable later with: sudo hmi-rootfs enable --reboot"
else
	hmi-rootfs enable
fi
hmi-rootfs status
