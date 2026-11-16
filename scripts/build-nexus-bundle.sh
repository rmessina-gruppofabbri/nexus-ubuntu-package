#!/usr/bin/env bash
# Da eseguire sul PC di sviluppo (WSL con Docker), prima di prepare-autoinstall-seed.sh
# e per ogni nuova release:
#
#   bash scripts/build-nexus-bundle.sh ~/repo/nexus-h7
#
# Costruisce l'immagine nexus-h7 con il tag scritto in deployment/compose.yaml
# e crea il bundle offline in deployment/bundle/ (immagini + manifest), che il
# payload dell'installer porta sulla HMI. Lo stesso bundle copiato su una
# chiavetta USB aggiorna una macchina già in servizio:
#   sudo hmi-import-images /mnt/usb/bundle/images.tar.gz
#   sudo hmi-apply-stack /mnt/usb/bundle/compose.yaml
set -Eeuo pipefail

if [[ $# -ne 1 || ! -f $1/Dockerfile ]]; then
	echo "Usage: bash scripts/build-nexus-bundle.sh /path/to/nexus-h7" >&2
	exit 2
fi

source_dir=$(realpath "$1")
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
compose_file=${repo_root}/deployment/compose.yaml

image=$(docker compose -f "${compose_file}" config --images | grep -m1 '/nexus-h7:' || true)
if [[ -z ${image} ]]; then
	echo "No nexus-h7 image found in ${compose_file}." >&2
	exit 1
fi

if docker image inspect "${image}" >/dev/null 2>&1; then
	echo "Note: ${image} already exists locally and will be rebuilt."
	echo "      For a new release, change the tag in deployment/compose.yaml first."
fi

revision=$(git -C "${source_dir}" rev-parse --short HEAD 2>/dev/null || echo unknown)
dirty=$(git -C "${source_dir}" status --porcelain 2>/dev/null | head -n 1 || true)
[[ -n ${dirty} ]] && revision="${revision}-dirty"

echo "Building ${image} from ${source_dir} (revision ${revision})"
docker build --platform linux/amd64 \
	--label "org.opencontainers.image.revision=${revision}" \
	--label "org.opencontainers.image.source=nexus-h7" \
	-t "${image}" "${source_dir}"

rm -rf "${repo_root}/deployment/bundle"
bash "${repo_root}/scripts/export-images.sh" "${compose_file}" "${repo_root}/deployment/bundle"
