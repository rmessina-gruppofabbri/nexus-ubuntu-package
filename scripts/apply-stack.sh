#!/usr/bin/env bash
# Applica un manifest Compose con controllo di salute e rollback automatico.
#
#   sudo hmi-apply-stack /data/hmi/compose.yaml   applica (modifica locale, consegna via USB o cloud)
#   sudo hmi-apply-stack --rollback               torna al manifest funzionante precedente
#
# Stato conservato in /data/hmi/.deploy:
#   last-good.yaml   manifest del deployment attualmente in esecuzione e sano
#   previous.yaml    il manifest funzionante precedente (destinazione di --rollback)
#   failed-*.yaml    manifest annullati con rollback automatico
# Le immagini di last-good e previous restano su disco, così il rollback funziona
# offline; tutte le altre vengono rimosse dopo un deployment riuscito.
set -Eeuo pipefail

usage() {
	echo "Usage: sudo bash scripts/apply-stack.sh /data/hmi/compose.yaml" >&2
	echo "       sudo bash scripts/apply-stack.sh --rollback" >&2
	exit 2
}

if [[ ${EUID} -ne 0 ]]; then
	echo "Run this script with sudo." >&2
	exit 1
fi

project_dir=/data/hmi
active_file=${project_dir}/compose.yaml
state_dir=${project_dir}/.deploy
last_good=${state_dir}/last-good.yaml
previous=${state_dir}/previous.yaml
health_timeout=${HMI_HEALTH_TIMEOUT:-180}

rollback_mode=false
case $# in
	1)
		if [[ $1 == --rollback ]]; then
			rollback_mode=true
		elif [[ -f $1 ]]; then
			compose_file=$(realpath "$1")
		else
			usage
		fi
		;;
	*) usage ;;
esac

if ! mountpoint -q /data; then
	echo "/data must be the separate data partition." >&2
	exit 1
fi

if ! docker info >/dev/null 2>&1; then
	echo "Docker is not available; install and start Docker first." >&2
	exit 1
fi

# Un solo deployment alla volta (es. consegna dal cloud ed esecuzione manuale).
exec 9>/run/hmi-apply-stack.lock
if ! flock -n 9; then
	echo "Another deployment is already running." >&2
	exit 1
fi

install -d -m 0750 "${state_dir}"
timestamp=$(date +%Y%m%d-%H%M%S)

if [[ ${rollback_mode} == true ]]; then
	if [[ ! -f ${previous} ]]; then
		echo "No previous manifest in ${previous}; nothing to roll back to." >&2
		exit 1
	fi
	[[ -f ${active_file} ]] && cp -a "${active_file}" "${state_dir}/rolled-back-${timestamp}.yaml"
	install -m 0644 "${previous}" "${active_file}"
	compose_file=${active_file}
	echo "Rolling back to ${previous}"
elif [[ ${compose_file} != "${active_file}" ]]; then
	# I percorsi relativi nel manifest (./server.js, ./postgres, secrets) sono
	# risolti rispetto a /data/hmi, quindi il manifest attivo sta sempre lì.
	echo "Copying ${compose_file} to ${active_file}"
	[[ -f ${active_file} ]] && cp -a "${active_file}" "${state_dir}/replaced-${timestamp}.yaml"
	install -m 0644 "${compose_file}" "${active_file}"
	compose_file=${active_file}
fi

compose_for() {
	docker compose --project-directory "${project_dir}" -f "$1" "${@:2}"
}

# Ogni immagine deve avere un digest sha256 o un tag di versione preciso come
# 17.6-alpine3.22 o 1.27.4-alpine. I tag mobili (latest, 17-alpine, alpine,
# nessun tag) vengono rifiutati.
validate() {
	local file=$1 image name tag images
	compose_for "${file}" config --quiet || return 1
	images=$(compose_for "${file}" config --images) || return 1
	while IFS= read -r image; do
		[[ -z ${image} || ${image} == *@sha256:* ]] && continue
		name=${image##*/}
		tag=
		[[ ${name} == *:* ]] && tag=${name##*:}
		if [[ ! ${tag} =~ ^v?[0-9]+\.[0-9]+ ]]; then
			echo "Use a precise version tag (e.g. 17.6-alpine3.22) or a sha256 digest: ${image}" >&2
			return 1
		fi
	done <<<"${images}"
}

# Tutti i container in esecuzione, e sani dove è definito un healthcheck.
wait_healthy() {
	local file=$1 deadline=$((SECONDS + health_timeout)) states ok service state health
	while true; do
		states=$(compose_for "${file}" ps -a --format '{{.Service}} {{.State}} {{.Health}}') || states=
		ok=true
		[[ -z ${states} ]] && ok=false
		while read -r service state health; do
			[[ -z ${service} ]] && continue
			[[ ${state} != running ]] && ok=false
			[[ -n ${health} && ${health} != healthy ]] && ok=false
		done <<<"${states}"
		if [[ ${ok} == true ]]; then
			return 0
		fi
		if (( SECONDS >= deadline )); then
			echo "Stack not healthy after ${health_timeout}s:" >&2
			echo "${states}" >&2
			return 1
		fi
		sleep 5
	done
}

# --pull missing: le versioni fissate non cambiano mai, quindi si scaricano solo
# le immagini mancanti. Le immagini caricate da USB (hmi-import-images) funzionano
# offline.
deploy() {
	local file=$1
	validate "${file}" || return 1
	compose_for "${file}" up -d --pull missing --remove-orphans || return 1
	wait_healthy "${file}"
}

prune_images() {
	local file image id keep=" "
	for file in "${last_good}" "${previous}"; do
		[[ -f ${file} ]] || continue
		while IFS= read -r image; do
			[[ -z ${image} ]] && continue
			if id=$(docker image inspect --format '{{.Id}}' "${image}" 2>/dev/null); then
				keep+="${id} "
			fi
		done < <(compose_for "${file}" config --images 2>/dev/null || true)
	done
	while IFS= read -r id; do
		[[ ${keep} == *" ${id} "* ]] && continue
		docker image rm "${id}" >/dev/null 2>&1 || true
	done < <(docker image ls -q --no-trunc | sort -u)
	docker image prune -f >/dev/null || true
}

if deploy "${compose_file}"; then
	if [[ ! -f ${last_good} ]] || ! cmp -s "${compose_file}" "${last_good}"; then
		[[ -f ${last_good} ]] && mv -f "${last_good}" "${previous}"
		install -m 0640 "${compose_file}" "${last_good}"
	fi
	prune_images
	echo "Deployment applied and healthy: ${compose_file}"
	exit 0
fi

echo "Deployment FAILED." >&2
if [[ -f ${last_good} ]] && ! cmp -s "${compose_file}" "${last_good}"; then
	cp -a "${compose_file}" "${state_dir}/failed-${timestamp}.yaml"
	install -m 0644 "${last_good}" "${active_file}"
	echo "Restoring the last working manifest (failed one saved as failed-${timestamp}.yaml)..." >&2
	if deploy "${active_file}"; then
		echo "Rollback completed; the previous version is running." >&2
	else
		echo "Rollback did not reach a healthy state either; manual intervention needed." >&2
	fi
fi
exit 1
