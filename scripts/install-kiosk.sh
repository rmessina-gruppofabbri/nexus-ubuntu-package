#!/usr/bin/env bash
# Kiosk: autologin LightDM -> Openbox (senza menu/scorciatoie) -> Google Chrome.
# Uso: sudo bash scripts/install-kiosk.sh [URL]
set -Eeuo pipefail

if [[ ${EUID} -ne 0 ]]; then
	echo "Run this script with sudo: sudo bash scripts/install-kiosk.sh [URL]" >&2
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

if [[ $(dpkg --print-architecture) != amd64 ]]; then
	echo "Google Chrome is only available for amd64." >&2
	exit 1
fi

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
default_url=http://127.0.0.1:3001/
if [[ $# -ge 1 ]]; then
	kiosk_url=$1
elif [[ -t 0 ]]; then
	read -r -p "Local HMI URL [${default_url}]: " kiosk_url
else
	kiosk_url=
	echo "No URL given and no terminal available; using ${default_url}"
fi
kiosk_url=${kiosk_url:-${default_url}}

# Niente spazi, virgolette, backslash o parentesi angolari: l'URL viene scritto
# in un file shell e in una policy JSON.
url_re='^https?://[^][:space:]"\\<>]+$'
origin_re='^(https?://[^/?#]+)'
if [[ ! ${kiosk_url} =~ ${url_re} || ! ${kiosk_url} =~ ${origin_re} ]]; then
	echo "Enter a valid http:// or https:// URL without spaces or quotes." >&2
	exit 1
fi
kiosk_origin=${BASH_REMATCH[1]}

echo "Installing the kiosk stack for ${kiosk_url}..."
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
	ca-certificates \
	curl

# Repository di Google Chrome. /etc/default/google-chrome impedisce al pacchetto
# Chrome di aggiungere una seconda copia del repository, in conflitto con questa.
install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://dl.google.com/linux/linux_signing_key.pub -o /etc/apt/keyrings/google-chrome.asc
chmod 0644 /etc/apt/keyrings/google-chrome.asc
cat > /etc/default/google-chrome <<'EOF'
repo_add_once="false"
repo_reenable_on_distupgrade="false"
EOF
cat > /etc/apt/sources.list.d/google-chrome.sources <<'EOF'
Types: deb
URIs: https://dl.google.com/linux/chrome/deb/
Suites: stable
Components: main
Architectures: amd64
Signed-By: /etc/apt/keyrings/google-chrome.asc
EOF

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
	fonts-dejavu-core \
	google-chrome-stable \
	hsetroot \
	lightdm \
	lightdm-gtk-greeter \
	openbox \
	x11-xserver-utils \
	xserver-xorg-core \
	xserver-xorg-input-libinput

if ! id kiosk >/dev/null 2>&1; then
	adduser --disabled-password --comment "" kiosk
fi

if ! getent group autologin >/dev/null 2>&1; then
	groupadd autologin
fi
usermod -aG autologin kiosk

install -d -m 0755 /etc/kiosk
printf 'KIOSK_URL=%q\n' "${kiosk_url}" > /etc/kiosk/kiosk.conf
chmod 0644 /etc/kiosk/kiosk.conf

# Prima .config: install -d assegna il proprietario solo all'ultima cartella.
install -d -o kiosk -g kiosk -m 0750 /home/kiosk/.config
install -d -o kiosk -g kiosk -m 0750 /home/kiosk/.config/openbox
install -d -o kiosk -g kiosk -m 0700 /home/kiosk/.config/chrome-kiosk

# Policy di Chrome: niente DevTools, finestre di selezione file, stampa,
# download, profili; si può aprire solo l'origine della HMI.
install -d -m 0755 /etc/opt/chrome/policies/managed
cat > /etc/opt/chrome/policies/managed/kiosk.json <<EOF
{
	"URLBlocklist": ["*"],
	"URLAllowlist": ["${kiosk_origin}"],
	"DeveloperToolsAvailability": 2,
	"AllowFileSelectionDialogs": false,
	"PrintingEnabled": false,
	"DownloadRestrictions": 3,
	"IncognitoModeAvailability": 1,
	"BrowserGuestModeEnabled": false,
	"BrowserAddPersonEnabled": false,
	"BrowserSignin": 0,
	"SyncDisabled": true,
	"PasswordManagerEnabled": false,
	"AutofillAddressEnabled": false,
	"AutofillCreditCardEnabled": false,
	"TranslateEnabled": false,
	"SearchSuggestEnabled": false,
	"BookmarkBarEnabled": false,
	"TaskManagerEndProcessEnabled": false,
	"BackgroundModeEnabled": false,
	"DefaultBrowserSettingEnabled": false,
	"MetricsReportingEnabled": false
}
EOF
chmod 0644 /etc/opt/chrome/policies/managed/kiosk.json

cat > /usr/local/bin/kiosk-browser-loop <<'EOF'
#!/usr/bin/env bash
set -u
source /etc/kiosk/kiosk.conf
profile=/home/kiosk/.config/chrome-kiosk

# Attende che la HMI risponda (qualsiasi stato HTTP sotto 500), così l'operatore
# non vede una pagina di errore all'avvio. -k vale solo per questa verifica.
wait_for_hmi() {
	local code
	while true; do
		code=$(curl -ks -o /dev/null -w '%{http_code}' --max-time 3 "${KIOSK_URL}" || true)
		if [[ ${code} =~ ^[1-4][0-9][0-9]$ ]]; then
			return
		fi
		sleep 2
	done
}

while true; do
	wait_for_hmi

	# Dopo una mancanza di corrente Chrome segna il profilo come chiuso in modo
	# anomalo e mostra l'avviso "Ripristina pagine". Prima di ogni avvio lo si
	# segna come chiuso correttamente.
	prefs=${profile}/Default/Preferences
	if [[ -f ${prefs} ]]; then
		sed -i \
			-e 's/"exit_type":"[A-Za-z]*"/"exit_type":"Normal"/' \
			-e 's/"exited_cleanly":false/"exited_cleanly":true/' \
			"${prefs}"
	fi

	/usr/bin/google-chrome-stable \
		--kiosk \
		--no-first-run \
		--no-default-browser-check \
		--noerrdialogs \
		--password-store=basic \
		--disable-features=Translate \
		--check-for-update-interval=31536000 \
		--disk-cache-size=33554432 \
		--user-data-dir="${profile}" \
		"${KIOSK_URL}" || true
	sleep 2
done
EOF
chmod 0755 /usr/local/bin/kiosk-browser-loop

# Sfondo di Openbox: logo e "System starting up..." nella stessa posizione dello
# splash di Plymouth, visibile finché Chrome (a schermo intero) non è aperto.
# Generato da plymouth/make-text-images.py.
install -d -m 0755 /usr/share/hmi-kiosk
if [[ -f ${repo_root}/kiosk/background.png ]]; then
	install -m 0644 "${repo_root}/kiosk/background.png" /usr/share/hmi-kiosk/background.png
else
	echo "Warning: ${repo_root}/kiosk/background.png not found; the kiosk background will be plain white." >&2
fi

cat > /home/kiosk/.config/openbox/autostart <<'EOF'
if [ -f /usr/share/hmi-kiosk/background.png ]; then
	hsetroot -solid '#ffffff' -center /usr/share/hmi-kiosk/background.png || xsetroot -solid white
else
	xsetroot -solid white
fi
xset s off
xset -dpms
xset s noblank
/usr/local/bin/kiosk-browser-loop &
EOF

# Openbox senza scorciatoie da tastiera né azioni del mouse (quindi niente menu
# principale, niente Alt+F4, niente cambio desktop) e finestre senza bordi,
# massimizzate.
cat > /home/kiosk/.config/openbox/rc.xml <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<openbox_config xmlns="http://openbox.org/3.4/rc">
	<desktops>
		<number>1</number>
	</desktops>
	<keyboard>
	</keyboard>
	<mouse>
	</mouse>
	<applications>
		<application class="*">
			<decor>no</decor>
			<maximized>yes</maximized>
		</application>
	</applications>
</openbox_config>
EOF
chown kiosk:kiosk /home/kiosk/.config/openbox/autostart /home/kiosk/.config/openbox/rc.xml
chmod 0644 /home/kiosk/.config/openbox/autostart /home/kiosk/.config/openbox/rc.xml

# Xorg: lascia disponibile il cambio console Ctrl+Alt+Fn per la manutenzione;
# blocca Ctrl+Alt+Backspace e lo spegnimento dello schermo.
install -d -m 0755 /etc/X11/xorg.conf.d
cat > /etc/X11/xorg.conf.d/10-kiosk.conf <<'EOF'
Section "ServerFlags"
	# Option "DontVTSwitch" "true"
	Option "DontZap" "true"
	Option "BlankTime" "0"
	Option "StandbyTime" "0"
	Option "SuspendTime" "0"
	Option "OffTime" "0"
EndSection
EOF
chmod 0644 /etc/X11/xorg.conf.d/10-kiosk.conf

# Touchscreen resistivo USB PenMount (14e1:6000), gestito da libinput.
# La matrice viene da xinput_calibrator sul pannello 1024x768: l'asse Y è
# invertito ed entrambi gli assi sono riscalati. Un file esistente viene
# mantenuto, così una calibrazione fatta a mano non viene sovrascritta se
# l'installer viene rieseguito.
penmount_conf=/etc/X11/xorg.conf.d/99-penmount-calibration.conf
if [[ ! -e ${penmount_conf} ]]; then
	cat > "${penmount_conf}" <<'EOF'
Section "InputClass"
	Identifier "PenMount calibration"
	MatchIsTouchscreen "on"
	MatchUSBID "14e1:6000"
	Driver "libinput"
	Option "CalibrationMatrix" "1.080170 0 -0.025317 0 -1.064692 1.031648 0 0 1"
EndSection
EOF
	chmod 0644 "${penmount_conf}"
else
	echo "Keeping existing touchscreen calibration in ${penmount_conf}"
fi

# Il greeter GTK è solo un ripiego se l'autologin fallisce; non elenca gli utenti.
install -d -m 0755 /etc/lightdm/lightdm.conf.d
cat > /etc/lightdm/lightdm.conf.d/50-kiosk.conf <<'EOF'
[Seat:*]
autologin-user=kiosk
autologin-user-timeout=0
autologin-session=openbox
user-session=openbox
greeter-session=lightdm-gtk-greeter
greeter-hide-users=true
allow-guest=false
EOF
chmod 0644 /etc/lightdm/lightdm.conf.d/50-kiosk.conf

systemctl set-default graphical.target
systemctl enable lightdm.service

cat <<EOF

Kiosk setup is installed. Reboot to start it.
HMI URL: ${kiosk_url}
Allowed origin in Chrome: ${kiosk_origin}

The HMI application itself is not installed by this script. Ensure its local
web service starts independently and listens at the configured URL.
SSH and firewall settings were not changed.
EOF
