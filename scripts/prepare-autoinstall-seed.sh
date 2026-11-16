#!/usr/bin/env bash
# Prepara la chiavetta USB CIDATA per l'autoinstall.
#
#   WSL:   bash scripts/prepare-autoinstall-seed.sh --wsl
#          trova in Windows il volume FAT32 con etichetta CIDATA, lo monta se
#          serve (chiede la password di sudo), costruisce il bundle Nexus H7 se
#          manca o non è aggiornato, copia i file e smonta la chiavetta.
#          Si può comunque indicare un punto di mount: --wsl /mnt/d
#   Linux: sudo bash scripts/prepare-autoinstall-seed.sh /mnt/cidata
#
# Il repository nexus-h7 viene cercato accanto a questo (../nexus-h7);
# per indicarne un altro: NEXUS_H7_DIR=/percorso/nexus-h7.
#
# SSH: se esiste la chiave pubblica ~/.ssh/nexus-hmi.pub (modificabile con
# HMI_SSH_PUBKEY=/percorso/chiave.pub), il sistema installato riceve il server
# SSH con quella chiave per l'account amministratore, senza accesso con password.
# Senza la chiave, SSH non viene installato.
set -Eeuo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
mounted_here=""
user_home=$(getent passwd "${SUDO_USER:-${USER:-$(id -un)}}" | cut -d: -f6)
ssh_pubkey=${HMI_SSH_PUBKEY:-${user_home}/.ssh/nexus-hmi.pub}

if [[ $# -ge 1 && $1 == --wsl ]]; then
	wsl_mode=true
	if [[ -z ${WSL_DISTRO_NAME:-} ]] || ! command -v powershell.exe >/dev/null 2>&1; then
		echo "--wsl works only inside WSL, with powershell.exe available." >&2
		exit 1
	fi
	if [[ $# -eq 2 ]]; then
		if [[ ! $2 =~ ^/mnt/[a-zA-Z]$ ]]; then
			echo "WSL usage: bash scripts/prepare-autoinstall-seed.sh --wsl [/mnt/e]" >&2
			exit 2
		fi
		drive_letter=${2##*/}
	elif [[ $# -eq 1 ]]; then
		# Cerca in Windows la chiavetta CIDATA: FAT32, rimovibile, etichetta CIDATA.
		mapfile -t letters < <(powershell.exe -NoProfile -NonInteractive -Command \
			'Get-Volume | Where-Object { $_.FileSystemLabel -eq "CIDATA" -and $_.FileSystem -eq "FAT32" -and $_.DriveLetter } | ForEach-Object { $_.DriveLetter }' \
			| tr -d '\r' | grep -E '^[A-Za-z]$' || true)
		if [[ ${#letters[@]} -eq 0 ]]; then
			echo "No FAT32 volume labeled CIDATA found in Windows." >&2
			echo "Plug in the stick, format it as FAT32 with label CIDATA and check it has a drive letter." >&2
			exit 1
		fi
		if [[ ${#letters[@]} -gt 1 ]]; then
			echo "More than one CIDATA volume found (${letters[*]}); give the one to use, e.g. --wsl /mnt/${letters[0],,}" >&2
			exit 1
		fi
		drive_letter=${letters[0]}
		echo "CIDATA stick found: ${drive_letter^^}:"
	else
		echo "WSL usage: bash scripts/prepare-autoinstall-seed.sh --wsl [/mnt/e]" >&2
		exit 2
	fi
	drive_letter=${drive_letter,,}
	seed_mount=/mnt/${drive_letter}

	volume_info=$(powershell.exe -NoProfile -NonInteractive -Command \
		'$v = Get-Volume -DriveLetter '"${drive_letter^^}"'; if ($null -eq $v) { exit 1 }; "$($v.FileSystem)|$($v.FileSystemLabel)"' \
		| tr -d '\r') || {
		echo "Windows has no volume ${drive_letter^^}:; check the stick in Windows." >&2
		exit 1
	}
	if [[ ${volume_info} != "FAT32|CIDATA" ]]; then
		echo "Expected FAT32 volume labeled CIDATA on ${drive_letter^^}:; Windows reports: ${volume_info}" >&2
		exit 1
	fi

	# WSL monta solo le unità presenti al suo avvio: se serve, la monta.
	if ! mountpoint -q "${seed_mount}"; then
		echo "Mounting ${drive_letter^^}: on ${seed_mount} (sudo password may be requested)..."
		sudo mkdir -p "${seed_mount}"
		sudo mount -t drvfs "${drive_letter^^}:" "${seed_mount}" -o "uid=$(id -u),gid=$(id -g)"
		mounted_here=${seed_mount}
	fi
	if [[ ! -w ${seed_mount} ]]; then
		echo "The CIDATA stick is mounted on ${seed_mount} but is not writable." >&2
		exit 1
	fi
elif [[ $# -eq 1 && $1 != -* ]]; then
	wsl_mode=false
	seed_mount=$(realpath "$1")
	if ! mountpoint -q "${seed_mount}"; then
		echo "Mount the CIDATA USB partition before continuing." >&2
		exit 1
	fi

	seed_source=$(findmnt -nro SOURCE --target "${seed_mount}")
	seed_fstype=$(findmnt -nro FSTYPE --target "${seed_mount}")
	seed_label=$(blkid -s LABEL -o value "${seed_source}" || true)
	if [[ ${seed_label} != CIDATA || ${seed_fstype} != vfat ]]; then
		echo "The mounted partition must be FAT32 and labeled CIDATA." >&2
		exit 1
	fi
else
	echo "Usage: bash scripts/prepare-autoinstall-seed.sh --wsl [/mnt/e]" >&2
	echo "   or: sudo bash scripts/prepare-autoinstall-seed.sh /path/to/CIDATA-mount" >&2
	exit 2
fi

if [[ ! -w ${seed_mount} ]]; then
	echo "The CIDATA volume is not writable: ${seed_mount}" >&2
	exit 1
fi

cleanup() {
	rm -f "${payload_tmp:-}" "${user_data_tmp:-}"
	if [[ -n ${mounted_here} ]]; then
		sync
		sudo umount "${mounted_here}" || echo "Could not unmount ${mounted_here}; run: sudo umount ${mounted_here}" >&2
	fi
}
trap cleanup EXIT

# L'immagine nexus-h7 non è in un registry: il payload deve contenere il bundle
# costruito esattamente per questo compose.yaml. Lo costruisce se manca o non è
# aggiornato.
bundle=${repo_root}/deployment/bundle
if [[ ! -f ${bundle}/images.tar.gz ]] \
	|| ! cmp -s "${repo_root}/deployment/compose.yaml" "${bundle}/compose.yaml"; then
	nexus_dir=${NEXUS_H7_DIR:-$(dirname "${repo_root}")/nexus-h7}
	if [[ ! -f ${nexus_dir}/Dockerfile ]]; then
		echo "The Nexus H7 bundle is missing or out of date and ${nexus_dir} was not found." >&2
		echo "Build it with: bash scripts/build-nexus-bundle.sh /path/to/nexus-h7" >&2
		exit 1
	fi
	echo "Building the Nexus H7 bundle from ${nexus_dir}..."
	bash "${repo_root}/scripts/build-nexus-bundle.sh" "${nexus_dir}"
fi

# user-data per la chiavetta, con la chiave SSH se presente.
user_data_tmp=$(mktemp)
cp "${repo_root}/autoinstall/user-data" "${user_data_tmp}"
if [[ -f ${ssh_pubkey} ]]; then
	key=$(grep -m1 -E '^(ssh-ed25519|ecdsa-sha2-nistp(256|384|521)|ssh-rsa) [A-Za-z0-9+/=]+( [^"\\|]*)?$' "${ssh_pubkey}" || true)
	if [[ -z ${key} || $(grep -c . "${ssh_pubkey}") -ne 1 ]]; then
		echo "${ssh_pubkey} is not a single valid public key." >&2
		exit 1
	fi
	if grep -q -- '-----BEGIN' "${ssh_pubkey}"; then
		echo "${ssh_pubkey} looks like a PRIVATE key; use the .pub file." >&2
		exit 1
	fi
	sed -i \
		-e 's|^    install-server: false$|    install-server: true|' \
		-e "s|^    authorized-keys: \[\]$|    authorized-keys: [\"${key}\"]|" \
		"${user_data_tmp}"
	if ! grep -q '^    install-server: true$' "${user_data_tmp}" \
		|| ! grep -qF "authorized-keys: [\"${key}\"]" "${user_data_tmp}"; then
		echo "Could not add the SSH key to user-data (unexpected layout)." >&2
		exit 1
	fi
	echo "SSH: enabled, key-only, with $(awk '{print $1, $3}' <<<"${key}") from ${ssh_pubkey}"
else
	echo "SSH: not installed (no public key at ${ssh_pubkey})."
	echo "     To enable it: ssh-keygen -t ed25519 -f ~/.ssh/nexus-hmi -C nexus-hmi, then rerun."
fi

echo "Copying files to the CIDATA stick (${seed_mount})..."
payload_tmp=$(mktemp "${seed_mount}/payload.tar.gz.XXXXXX")

tar -czf "${payload_tmp}" -C "${repo_root}" \
	autoinstall/hmi-firstboot.service \
	deployment/compose.yaml \
	deployment/hmi.env.example \
	deployment/bundle/images.tar.gz \
	deployment/bundle/compose.yaml \
	deployment/bundle/SHA256SUMS \
	plymouth/fabbri-hmi/fabbri-hmi.plymouth \
	plymouth/fabbri-hmi/fabbri-hmi.script \
	plymouth/fabbri-hmi/logo.png \
	plymouth/fabbri-hmi/text-0.png \
	plymouth/fabbri-hmi/text-1.png \
	plymouth/fabbri-hmi/text-2.png \
	plymouth/fabbri-hmi/text-3.png \
	kiosk/background.png \
	scripts/apply-stack.sh \
	scripts/build-nexus-bundle.sh \
	scripts/export-images.sh \
	scripts/firstboot-setup.sh \
	scripts/hmi-rootfs.sh \
	scripts/import-images.sh \
	scripts/install-docker.sh \
	scripts/install-kiosk.sh \
	scripts/install-plymouth-splash.sh \
	scripts/setup-readonly-root.sh \
	scripts/slim-system.sh \
	scripts/tune-system.sh

if [[ ${wsl_mode} == true ]]; then
	cp "${user_data_tmp}" "${seed_mount}/user-data"
	cp "${repo_root}/autoinstall/meta-data" "${seed_mount}/meta-data"
	cp "${payload_tmp}" "${seed_mount}/payload.tar.gz"
else
	install -m 0644 "${user_data_tmp}" "${seed_mount}/user-data"
	install -m 0644 "${repo_root}/autoinstall/meta-data" "${seed_mount}/meta-data"
	install -m 0644 "${payload_tmp}" "${seed_mount}/payload.tar.gz"
fi
rm -f "${payload_tmp}"
sync
ls -lh "${seed_mount}/user-data" "${seed_mount}/meta-data" "${seed_mount}/payload.tar.gz"

echo "CIDATA stick ready. No disk was partitioned or formatted."
if [[ ${wsl_mode} == true ]]; then
	echo "Eject it safely from Windows before unplugging it."
fi