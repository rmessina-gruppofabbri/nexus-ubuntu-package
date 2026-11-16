#!/usr/bin/env bash
# Carica le immagini dei container da un bundle offline creato da export-images.sh.
#   sudo hmi-import-images /media/usb/hmi-update/images.tar.gz
# Poi applicare il manifest con hmi-apply-stack: non scarica nulla di ciò che è
# già presente, quindi non serve accesso a Internet.
set -Eeuo pipefail

if [[ ${EUID} -ne 0 ]]; then
	echo "Run this script with sudo." >&2
	exit 1
fi

if [[ $# -ne 1 || ! -f $1 ]]; then
	echo "Usage: sudo hmi-import-images /path/to/images.tar.gz" >&2
	exit 2
fi

archive=$(realpath "$1")
sums=$(dirname "${archive}")/SHA256SUMS
if [[ -f ${sums} ]]; then
	echo "Verifying checksums..."
	(cd "$(dirname "${archive}")" && sha256sum --check --ignore-missing SHA256SUMS)
else
	echo "Warning: no SHA256SUMS next to the archive; integrity not verified." >&2
fi

# Controllo approssimativo dello spazio: le immagini estratte occupano circa 2-3 volte l'archivio.
needed_kb=$(( $(stat -c %s "${archive}") * 3 / 1024 ))
free_kb=$(df --output=avail -k /data | tail -n 1)
if (( free_kb < needed_kb )); then
	echo "Not enough space on /data (free $((free_kb / 1024)) MB, need ~$((needed_kb / 1024)) MB)." >&2
	echo "Remove unused images first: docker image prune -a" >&2
	exit 1
fi

docker load -i "${archive}"
echo "Images loaded. Now run: sudo hmi-apply-stack /path/to/compose.yaml"
