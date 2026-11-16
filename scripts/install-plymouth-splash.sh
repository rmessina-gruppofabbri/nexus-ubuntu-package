#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID} -ne 0 ]]; then
	echo "Run this script with sudo: sudo bash scripts/install-plymouth-splash.sh" >&2
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

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
theme_source=${repo_root}/plymouth/fabbri-hmi
theme_target=/usr/share/plymouth/themes/fabbri-hmi

theme_files=(fabbri-hmi.plymouth fabbri-hmi.script logo.png text-0.png text-1.png text-2.png text-3.png)
for file in "${theme_files[@]}"; do
	if [[ ! -s ${theme_source}/${file} ]]; then
		echo "Missing Plymouth theme asset: ${theme_source}/${file}" >&2
		exit 1
	fi
done

apt-get update
# plymouth-label + fontconfig-config: per i temi grafici l'hook dell'initramfs
# copia il plugin label e /etc/fonts, e senza di essi fallisce.
# initramfs-tools: Ubuntu 26.04 genera l'initramfs con dracut, ma questo script
# (/etc/initramfs-tools/modules) e overlayroot (setup-readonly-root.sh) richiedono
# initramfs-tools. Installarlo rimuove dracut; va fatto prima di creare
# l'initramfs con il tema, altrimenti il tema finirebbe in quello di dracut.
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
	initramfs-tools plymouth plymouth-label fontconfig-config

install -d -m 0755 "${theme_target}"
for file in "${theme_files[@]}"; do
	install -m 0644 "${theme_source}/${file}" "${theme_target}/${file}"
done

# L'hook dell'initramfs di Ubuntu sceglie il tema SOLO dall'alternativa
# default.plymouth, non da plymouthd.conf. Con --no-install-recommends nessun
# pacchetto di temi la registra e l'hook esclude del tutto Plymouth
# dall'initramfs: nessuno splash all'avvio. Il nostro tema viene quindi
# registrato e selezionato esplicitamente.
theme_file=${theme_target}/fabbri-hmi.plymouth
update-alternatives --install /usr/share/plymouth/themes/default.plymouth \
	default.plymouth "${theme_file}" 200
update-alternatives --set default.plymouth "${theme_file}"

plymouth_config=/etc/plymouth/plymouthd.conf
install -d -m 0755 /etc/plymouth
if [[ -f ${plymouth_config} ]]; then
	config_tmp=$(mktemp /etc/plymouth/plymouthd.conf.XXXXXX)
	awk '
BEGIN { in_daemon = 0; found_section = 0; found_theme = 0 }
/^\[Daemon\][[:space:]]*$/ {
	in_daemon = 1
	found_section = 1
	print
	if (!found_theme) {
		print "Theme=fabbri-hmi"
		found_theme = 1
	}
	next
}
(/^\[/ && in_daemon) { in_daemon = 0 }
in_daemon && /^Theme=/ {
	if (!found_theme) print "Theme=fabbri-hmi"
	found_theme = 1
	next
}
{ print }
END {
	if (!found_section) {
		print "[Daemon]"
		print "Theme=fabbri-hmi"
	} else if (!found_theme && in_daemon) {
		print "Theme=fabbri-hmi"
	}
}
' "${plymouth_config}" > "${config_tmp}"
	chmod 0644 "${config_tmp}"
	mv "${config_tmp}" "${plymouth_config}"
else
	cat > "${plymouth_config}" <<'EOF'
[Daemon]
Theme=fabbri-hmi
ShowDelay=0
DeviceTimeout=8
EOF
	chmod 0644 "${plymouth_config}"
fi

if ! command -v update-initramfs >/dev/null 2>&1; then
	echo "update-initramfs is not available; cannot embed the Plymouth theme." >&2
	exit 1
fi
# GPU Intel (Celeron N3350): carica i915 già nell'initramfs, così lo splash
# parte subito alla risoluzione nativa invece di attendere il filesystem root.
# Fino ad allora simpledrm, integrato nel kernel, usa il framebuffer del
# firmware (UEFI GOP, o la modalità VESA mantenuta da GRUB, vedi sotto).
has_intel_gpu=false
for dev in /sys/bus/pci/devices/*; do
	[[ -r ${dev}/class && -r ${dev}/vendor ]] || continue
	if [[ $(<"${dev}/vendor") == 0x8086 && $(<"${dev}/class") == 0x03* ]]; then
		has_intel_gpu=true
	fi
done
modules_file=/etc/initramfs-tools/modules
if [[ ${has_intel_gpu} == true ]] && ! grep -qx 'i915' "${modules_file}" 2>/dev/null; then
	echo 'i915' >> "${modules_file}"
	echo "Added i915 to ${modules_file}"
fi

update-initramfs -u -k all

# Verifica che ogni initramfs contenga davvero il tema e un modo per disegnarlo.
for initrd in /boot/initrd.img-*; do
	[[ -e ${initrd} ]] || continue
	version=${initrd#/boot/initrd.img-}
	contents=$(lsinitramfs "${initrd}")
	if ! grep -q 'plymouth/themes/fabbri-hmi/logo.png$' <<<"${contents}" \
		|| ! grep -q 'plymouth/themes/fabbri-hmi/text-3.png$' <<<"${contents}" \
		|| ! grep -q 'plymouth/script\.so$' <<<"${contents}"; then
		echo "The Plymouth theme is missing from ${initrd}; the splash would not appear." >&2
		exit 1
	fi
	if ! grep -q 'drivers/gpu/drm/i915/' <<<"${contents}" \
		&& ! grep -qx 'CONFIG_DRM_SIMPLEDRM=y' "/boot/config-${version}" 2>/dev/null; then
		echo "Warning: no i915 module and no built-in simpledrm for ${version}; the splash may not appear." >&2
	fi
	echo "Plymouth theme embedded in ${initrd}"
done

# Impostazioni di GRUB in un file a parte in /etc/default/grub.d: update-grub lo
# legge dopo /etc/default/grub, che su Ubuntu 26.04 può anche non esistere.
# - quiet splash: senza splash Plymouth non mostra il logo ma i messaggi di avvio;
# - menu GRUB nascosto e nessuna attesa: senza /etc/default/grub GRUB mostrerebbe
#   il menu per 5 s a ogni avvio. Il menu si apre premendo Esc mentre parte GRUB;
# - GRUB_GFXPAYLOAD_LINUX=keep: passa al kernel la modalità grafica di GRUB.
#   Serve con l'avvio legacy BIOS, dove altrimenti il kernel parte in modalità
#   testo e non c'è un framebuffer per lo splash; con UEFI non ha effetti negativi.
install -d -m 0755 /etc/default/grub.d
cat > /etc/default/grub.d/80-hmi-splash.cfg <<'CFG'
# hmi: logo di avvio (scripts/install-plymouth-splash.sh)
for hmi_opt in quiet splash; do
	case " ${GRUB_CMDLINE_LINUX_DEFAULT:-} " in
		*" ${hmi_opt} "*) ;;
		*) GRUB_CMDLINE_LINUX_DEFAULT="${GRUB_CMDLINE_LINUX_DEFAULT:+${GRUB_CMDLINE_LINUX_DEFAULT} }${hmi_opt}" ;;
	esac
done
unset hmi_opt
GRUB_TIMEOUT_STYLE=hidden
GRUB_TIMEOUT=0
GRUB_GFXPAYLOAD_LINUX=keep
CFG
chmod 0644 /etc/default/grub.d/80-hmi-splash.cfg

update-grub
if ! grep -qE '^[[:space:]]*linux[[:space:]].*[[:space:]]splash([[:space:]]|$)' /boot/grub/grub.cfg; then
	echo "Warning: 'splash' is not on the kernel command line in /boot/grub/grub.cfg; the logo may not appear." >&2
fi
echo "Fabbri Group Plymouth splash installed. It will appear on the next boot."