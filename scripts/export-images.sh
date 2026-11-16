#!/usr/bin/env bash
# Da eseguire su un PC con Docker e accesso a Internet (non sulla HMI). Produce
# un bundle di aggiornamento offline per una chiavetta USB:
#
#   bash scripts/export-images.sh deployment/compose.yaml /media/usb/hmi-update
#
# La cartella di destinazione riceve compose.yaml e images.tar.gz. Sulla HMI:
#   sudo hmi-import-images /media/usb/hmi-update/images.tar.gz
#   sudo hmi-apply-stack /media/usb/hmi-update/compose.yaml
set -Eeuo pipefail

if [[ $# -ne 2 || ! -f $1 ]]; then
	echo "Usage: bash scripts/export-images.sh /path/to/compose.yaml /output/dir" >&2
	exit 2
fi

compose_file=$(realpath "$1")
out_dir=$2
install -d "${out_dir}"

mapfile -t images < <(docker compose -f "${compose_file}" config --images | sort -u)
if [[ ${#images[@]} -eq 0 ]]; then
	echo "No images found in ${compose_file}." >&2
	exit 1
fi

for image in "${images[@]}"; do
	if docker image inspect "${image}" >/dev/null 2>&1; then
		echo "Using local ${image}"
	elif [[ ${image} == localhost/* ]]; then
		echo "${image} is built locally and not present: run scripts/build-nexus-bundle.sh" >&2
		exit 1
	else
		echo "Pulling ${image} (linux/amd64)"
		docker pull --platform linux/amd64 "${image}"
	fi
done

echo "Saving ${#images[@]} images to ${out_dir}/images.tar.gz"
docker save "${images[@]}" | gzip -1 > "${out_dir}/images.tar.gz.tmp"
mv "${out_dir}/images.tar.gz.tmp" "${out_dir}/images.tar.gz"
cp "${compose_file}" "${out_dir}/compose.yaml"
(cd "${out_dir}" && sha256sum images.tar.gz compose.yaml > SHA256SUMS)

echo "Bundle ready in ${out_dir}:"
ls -lh "${out_dir}"
