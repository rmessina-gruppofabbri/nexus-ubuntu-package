#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID} -ne 0 ]]; then
	echo "Run this setup with sudo: sudo bash scripts/firstboot-setup.sh [--reconfigure]" >&2
	exit 1
fi

reconfigure_mode=false
case ${1:-} in
	"") ;;
	--reconfigure) reconfigure_mode=true ;;
	*)
		echo "Usage: sudo bash scripts/firstboot-setup.sh [--reconfigure]" >&2
		exit 2
		;;
esac

payload_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
state_dir=/var/lib/hmi-provision
log_file=/var/log/hmi-firstboot.log
kiosk_url=${KIOSK_URL:-http://127.0.0.1:3001/}

install -d -m 0755 "${state_dir}"
if [[ -e ${state_dir}/complete && ${reconfigure_mode} != true ]]; then
	exit 0
fi

exec >>"${log_file}" 2>&1
echo "Starting HMI provisioning at $(date --iso-8601=seconds)"

if [[ $(findmnt -no FSTYPE /) == overlay ]]; then
	echo "The system is read-only: changes would be lost at reboot." >&2
	echo "Run 'sudo hmi-rootfs disable --reboot' first, then repeat this command." >&2
	exit 1
fi

if ! mountpoint -q /data; then
	echo "/data must be the separate data partition (see docs/architettura.md)." >&2
	exit 1
fi

# Al primo avvio i job apt di Ubuntu (apt-daily, unattended-upgrades) possono
# tenere il lock di dpkg: ogni apt-get negli script di provisioning fallirebbe con
# "Could not get lock". Si fa attendere ad apt il lock e si aspetta che i job apt
# in corso finiscano prima di iniziare.
cat > /etc/apt/apt.conf.d/90hmi-lock-timeout <<'EOF'
// Attende fino a 10 minuti il lock di dpkg invece di fallire (provisioning HMI)
DPkg::Lock::Timeout "600";
EOF
# Non "pgrep unattended-upgr": unattended-upgrade-shutdown è un processo di
# supporto sempre attivo che non tocca apt; si cerca solo l'aggiornamento vero.
apt_busy() {
	pgrep -x 'apt|apt-get|dpkg' >/dev/null \
		|| pgrep -f '^/usr/bin/python3 /usr/bin/unattended-upgrade( |$)' >/dev/null
}
for _ in $(seq 1 180); do
	if ! apt_busy; then
		break
	fi
	echo "Waiting for running apt/dpkg jobs to finish..."
	sleep 5
done

cd "${payload_dir}"
bash scripts/tune-system.sh
bash scripts/install-plymouth-splash.sh

# Progetto Compose di Nexus H7. Le impostazioni della macchina (.env) sono create
# una sola volta dal modello e mai sovrascritte: una riconfigurazione le mantiene.
install -d -m 0750 /data/hmi
install -m 0644 deployment/compose.yaml /data/hmi/compose.yaml
install -m 0644 deployment/hmi.env.example /data/hmi/hmi.env.example
if [[ ! -e /data/hmi/.env ]]; then
	install -m 0640 deployment/hmi.env.example /data/hmi/.env
fi
# Scrivibili dall'utente del container (node, uid 1000).
install -d -m 0750 -o 1000 -g 1000 /data/hmi/gateway-data /data/hmi/opcua-pki

bash scripts/install-docker.sh

# Comandi di manutenzione disponibili sul dispositivo.
install -m 0755 scripts/apply-stack.sh /usr/local/sbin/hmi-apply-stack
install -m 0755 scripts/import-images.sh /usr/local/sbin/hmi-import-images

# L'immagine nexus-h7 non è in un registry: arriva nel bundle del payload.
if [[ -f deployment/bundle/images.tar.gz ]]; then
	bash scripts/import-images.sh deployment/bundle/images.tar.gz
fi

bash scripts/apply-stack.sh /data/hmi/compose.yaml
bash scripts/install-kiosk.sh "${kiosk_url}"
bash scripts/slim-system.sh

# Ultimo passo: dal prossimo avvio la partizione di sistema è in sola lettura.
# Entrambi i file sono ancora scritti sul disco reale: l'overlay parte al riavvio.
bash scripts/setup-readonly-root.sh
touch "${state_dir}/complete"
echo "HMI provisioning completed at $(date --iso-8601=seconds); rebooting."
systemctl reboot