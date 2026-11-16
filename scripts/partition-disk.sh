#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID} -ne 0 ]]; then
	echo "Run as root: sudo bash scripts/partition-disk.sh /dev/sdX" >&2
	exit 1
fi

if [[ $# -ne 1 ]]; then
	echo "Usage: sudo bash scripts/partition-disk.sh /dev/DISK" >&2
	exit 2
fi

for command_name in lsblk blockdev parted mkfs.vfat mkfs.ext4 udevadm; do
	if ! command -v "${command_name}" >/dev/null 2>&1; then
		echo "Required command not found: ${command_name}" >&2
		exit 1
	fi
done

if [[ ! -d /sys/firmware/efi ]]; then
	echo "Boot the USB environment in UEFI mode before partitioning." >&2
	exit 1
fi

disk=$(realpath "$1")
if [[ ! -b ${disk} ]]; then
	echo "Not a block device: ${disk}" >&2
	exit 1
fi

if [[ $(lsblk -dnro TYPE "${disk}") != "disk" ]]; then
	echo "Select a whole disk, not a partition: ${disk}" >&2
	exit 1
fi

# 512 MiB ESP + 6 GiB sistema + almeno 3,5 GiB dati.
size_bytes=$(blockdev --getsize64 "${disk}")
minimum_bytes=$((10 * 1024 * 1024 * 1024))
if (( size_bytes < minimum_bytes )); then
	echo "Disk is smaller than the 10 GiB minimum for this partition layout." >&2
	exit 1
fi

if lsblk -nrpo MOUNTPOINT "${disk}" | grep -q '[^[:space:]]'; then
	echo "The selected disk or one of its partitions is mounted; refusing to continue." >&2
	lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS,MODEL "${disk}" >&2
	exit 1
fi

echo "Selected disk (ALL DATA WILL BE ERASED):"
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS,MODEL "${disk}"
echo
echo "Layout: GPT, 512 MiB EFI, 6 GiB system (/), remaining space as data (/data)."
read -r -p "Type 'ERASE ${disk}' to continue: " confirmation
if [[ ${confirmation} != "ERASE ${disk}" ]]; then
	echo "Confirmation did not match; no changes made."
	exit 1
fi

disk_name=$(basename "${disk}")
if [[ ${disk_name} =~ [0-9]$ ]]; then
	partition_prefix="${disk}p"
else
	partition_prefix="${disk}"
fi

parted --script --align optimal "${disk}" \
	mklabel gpt \
	mkpart ESP fat32 1MiB 513MiB \
	set 1 esp on \
	mkpart hmi-root ext4 513MiB 6657MiB \
	mkpart hmi-data ext4 6657MiB 100%

udevadm settle
mkfs.vfat -F 32 -n EFI "${partition_prefix}1"
mkfs.ext4 -F -L hmi-root "${partition_prefix}2"
mkfs.ext4 -F -L hmi-data "${partition_prefix}3"

echo
echo "Partitioning complete. Review the filesystems before starting the installer:"
lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,UUID,MOUNTPOINTS "${disk}"
echo
echo "Assign EFI to /boot/efi, hmi-root to / and hmi-data to /data (all formatted)."
