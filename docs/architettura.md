# Architettura

Come è fatto il sistema installato e perché. Le procedure sono in
[installazione.md](installazione.md) e [manutenzione.md](manutenzione.md).

## Disco

Il PC HMI (Celeron N3350, 2 GB di RAM) usa un SSD mSATA iSLC da 16 GB, circa
14,9 GiB utilizzabili:

| Partizione | Dimensione | Filesystem | Mount point | Contenuto | In esercizio |
| --- | ---: | --- | --- | --- | --- |
| EFI | 512 MiB | FAT32 | `/boot/efi` | file di avvio UEFI | scrivibile, usata solo dagli aggiornamenti |
| `hmi-root` | 6 GiB | ext4 | `/` | Ubuntu, Chrome, kiosk, Docker Engine | **sola lettura** |
| `hmi-data` | resto (circa 8,4 GiB) | ext4 | `/data` | immagini Docker, configurazione Nexus H7, journal | scrivibile |

Contenuto di `/data`:

```
/data/docker/              data-root di Docker
/data/containerd/          montato su /var/lib/containerd (archivio immagini di containerd)
/data/hmi/                 progetto Compose: compose.yaml e .env (impostazioni della macchina)
/data/hmi/gateway-data/    configurazione salvata dal pannello Nexus H7
/data/hmi/opcua-pki/       certificati OPC UA
/data/hmi/.deploy/         last-good.yaml, previous.yaml, manifest falliti o sostituiti
/data/log/journal/         montato su /var/log/journal (log persistenti)
```

Dopo la pulizia il sistema occupa indicativamente 3,5 GiB: i 6 GiB lasciano
margine per gli aggiornamenti del kernel e dei pacchetti. Lo swap è zram,
compresso in RAM (metà della RAM, zstd): non ci sono partizione di swap né
`/swap.img`. Il journal di systemd è limitato a 50 MB.

Il layout è definito in `autoinstall/user-data` e Subiquity lo applica senza
chiedere conferma, sul più piccolo disco interno SATA/mSATA (o, in mancanza,
NVMe), scelto dal suo `ID_PATH`: le chiavette USB non vengono mai scelte. La
sezione storage non è interattiva perché, quando lo è, Subiquity mostra la sua
schermata senza precompilare il layout. Con lo spazio disponibile il margine è
ridotto:
controllare `df -h /data` e `sudo docker system df`. Per la produzione è
consigliato un SSD industriale da 64-128 GB.

## Sistema in sola lettura

L'ultimo passo del primo avvio (`scripts/setup-readonly-root.sh`) installa
`overlayroot` con `overlayroot="tmpfs:swap=1,recurse=0"`:

- la partizione di sistema è montata in sola lettura; le scritture su `/` vanno
  in RAM e **spariscono al riavvio**, quindi il sistema riparte sempre pulito,
  anche dopo un'interruzione di corrente;
- `recurse=0` lascia `/data` e `/boot/efi` montate normalmente, scrivibili;
- Docker, containerd e il journal scrivono solo su `/data`;
- gli aggiornamenti automatici (`unattended-upgrades`, timer di apt) sono
  disattivati: il sistema si aggiorna solo in manutenzione.

`overlayroot` legge `/etc/overlayroot.conf` dalla partizione di sistema a ogni
avvio, quindi `hmi-rootfs enable/disable` vale dal riavvio successivo senza
rigenerare l'initramfs.

Questo vale solo con **initramfs-tools**. Ubuntu 26.04 crea l'initramfs con
dracut, e con dracut overlayroot legge solo il parametro `overlayroot=` della
riga di comando del kernel: `/etc/overlayroot.conf` viene ignorato e il sistema
resta scrivibile. Per questo `install-plymouth-splash.sh` e
`setup-readonly-root.sh` installano `initramfs-tools`, che rimuove dracut.
`setup-readonly-root.sh` si ferma con un errore se un initramfs non contiene lo
script di overlayroot. `hmi-rootfs enable` fa lo stesso controllo, e
`hmi-rootfs status` segnala il problema.

Con la radice in sola lettura GRUB non riesce più a sapere che l'avvio
precedente è andato bene: il flag `recordfail` che scrive in
`/boot/grub/grubenv` viene azzerato da Ubuntu solo nell'overlay in RAM. Senza
correzione GRUB mostrerebbe il menu per 30 secondi a ogni accensione.
`setup-readonly-root.sh` imposta quindi `GRUB_RECORDFAIL_TIMEOUT=0`
(`/etc/default/grub.d/90-hmi-readonly.cfg`): il PC parte sempre subito e il
menu GRUB si apre premendo `Esc` all'accensione. Per lo stesso motivo
`grub-common.service` e `grub-initrd-fallback.service`, che falliscono
sull'overlay, vengono saltati quando la sola lettura è attiva.

### Attesa della rete all'avvio

Docker parte dopo `network-online.target`. Per default
`systemd-networkd-wait-online` aspetta che tutte le interfacce configurate siano
online, fino a 120 s: una porta senza cavo bloccherebbe HMI e kiosk per due
minuti. `tune-system.sh` lo riduce a "almeno un'interfaccia, al massimo 15 s"
(`/etc/systemd/system/systemd-networkd-wait-online.service.d/90-hmi.conf`).
Inoltre le porte Ethernet senza cavo durante il primo avvio vengono segnate
`optional: true` in netplan (`netplan set`): restano configurate, ma l'avvio non
le aspetta. Per cambiarlo in seguito, in manutenzione:
`sudo netplan set ethernets.enp2s0.optional=false`.

Prima di attivare la sola lettura, `scripts/slim-system.sh` rimuove servizi,
pacchetti e firmware che su questo PC non servono (snapd, rsyslog, apport,
firmware di hardware assente, header del kernel, ...). Un pacchetto viene
rimosso solo se apt conferma che non porta via nient'altro.

## Nexus H7

[deployment/compose.yaml](../deployment/compose.yaml) avvia una sola immagine,
`localhost/nexus-h7:<versione>`, costruita dal repository `nexus-h7` con il suo
`Dockerfile`. Il gateway (protocollo TIM verso la CPU, WebSocket e OPC UA)
serve anche il pannello operatore compilato, quindi non c'è un container
separato per il frontend. Il kiosk apre `http://127.0.0.1:3001/`.

| Servizio | Funzione | Limite di memoria |
| --- | --- | --- |
| `gateway` | collegamento TIM con la CPU H7 sulla seriale `/dev/ttyS4` (38400 8N1), pannello e WebSocket sulla porta 3001, OPC UA sulla 4841 | 384 MB (circa 100 MB misurati) |
| `simulator` | CPU H7 simulata per le prove; commentato nel manifest | 128 MB |

L'immagine non è pubblicata su un registry (`localhost/` non viene mai
scaricato): viaggia in un bundle offline (`deployment/bundle/`), copiato sulla
chiavetta `CIDATA` per le nuove installazioni o su una chiavetta qualsiasi per
gli aggiornamenti.

### Impostazioni della macchina

Le impostazioni della singola macchina stanno in `/data/hmi/.env`, creato al
primo avvio da [deployment/hmi.env.example](../deployment/hmi.env.example) e mai
sovrascritto in seguito.

| Collegamento | Impostazioni |
| --- | --- |
| Seriale diretta (default) | `MACHINE_TRANSPORT=serial`, `SERIAL_PATH=/dev/ttyS4`, `SERIAL_BAUD=38400`. La porta è passata al container con il gruppo `dialout`; se non esiste, il container non parte |
| Convertitore seriale/Ethernet | `MACHINE_TRANSPORT=tcp`, `MACHINE_HOST`, `MACHINE_PORT`; togliere i blocchi `devices` e `group_add` dal manifest |
| Simulatore (prove senza macchina) | togliere il commento al servizio `simulator` e seguire le istruzioni nel modello `.env` |

### Rete e sicurezza

- Per default le porte sono pubblicate solo su `127.0.0.1`.
- `OPCUA_BIND` pubblica OPC UA sull'indirizzo del PC nella rete di fabbrica;
  `OPCUA_HOSTNAME` deve contenere l'indirizzo che usano i client, altrimenti il
  server pubblica il nome del container.
- `HMI_BIND` rende il pannello raggiungibile dai tablet.
- Le porte pubblicate da Docker scavalcano le regole di `ufw`: legarle a un
  indirizzo di interfaccia specifico e aggiungere una regola firewall limitata a
  quella sottorete.
- Il nome host del container è fisso (`nexus-h7`), perché il certificato OPC UA
  è legato a quel nome: così resta lo stesso quando un aggiornamento ricrea il
  container.
- Il container gira con un utente senza privilegi, filesystem in sola lettura e
  senza capability.
- Non montare il socket di Docker nei container e non aggiungere l'utente
  `kiosk` al gruppo `docker`: l'accesso a Docker equivale ad accesso root.
- SSH è installato solo se alla preparazione della chiavetta esiste la chiave
  pubblica, e accetta solo l'accesso con chiave.

### Aggiornamenti con hmi-apply-stack

`scripts/apply-stack.sh`, installato come `hmi-apply-stack`:

- copia il manifest in `/data/hmi/compose.yaml`, così i percorsi relativi
  (`./gateway-data`, `./opcua-pki`) e `.env` si risolvono sempre in
  `/data/hmi`;
- valida il manifest e i tag delle immagini: serve una versione precisa o un
  digest sha256, mentre `latest` o un tag mancante vengono rifiutati;
- scarica solo le immagini mancanti e aggiorna i container;
- aspetta che siano tutti attivi e sani (180 s, modificabile con
  `HMI_HEALTH_TIMEOUT`) e, se non lo diventano, **ripristina da solo l'ultimo
  manifest funzionante**;
- conserva le immagini della versione attuale e di quella precedente, così il
  ritorno indietro (`--rollback`) funziona anche senza Internet, ed elimina le
  altre;
- usa un lock per impedire due aggiornamenti contemporanei.

Lo storico in `.deploy/` conserva solo il YAML: un rollback non annulla le
modifiche a `.env`.

Lo stesso comando applica un manifest consegnato in `/data/hmi/compose.yaml` da
un sistema di gestione remoto. Il canale remoto e la sua autenticazione non
fanno parte di questo progetto: usare un canale autenticato, verificare chi è
autorizzato a cambiare il manifest e conservare una copia tracciabile di ogni
versione approvata. Aggiornare il YAML equivale a distribuire codice da remoto.
Non usare aggiornatori automatici delle immagini: scavalcherebbero approvazione
e validazione delle versioni.

## Kiosk

LightDM esegue l'accesso automatico dell'utente `kiosk`, che avvia Openbox e
Google Chrome a schermo intero.

- Openbox non ha scorciatoie da tastiera né azioni del mouse: niente Alt+F4,
  niente menu con il tasto destro, niente cambio di desktop. Le finestre sono
  senza bordi e massimizzate.
- Xorg consente il cambio di console (`Ctrl`+`Alt`+`F1`..`F6`) per la
  manutenzione, blocca `Ctrl`+`Alt`+`Backspace` e disattiva lo spegnimento
  dello schermo.
- Le policy di Chrome in `/etc/opt/chrome/policies/managed/kiosk.json`
  disattivano DevTools, finestre di scelta file, stampa, download, profili
  ospite e in incognito, sincronizzazione, gestore password e traduzione, e
  consentono solo l'origine dell'HMI. Per aprire un altro servizio dal kiosk,
  aggiungerne l'origine a `URLAllowlist`.
- Le scorciatoie di Chrome che chiudono la finestra (`Ctrl`+`Shift`+`W`,
  `Ctrl`+`Shift`+`Q`) non si possono disattivare con le policy: il ciclo di
  avvio fa ripartire Chrome dopo 2 s. Su un pannello solo touch non sono
  raggiungibili.
- Chrome parte solo quando l'HMI risponde, così l'operatore non vede pagine di
  errore durante l'avvio. Il profilo riparte pulito a ogni avvio (cache limitata
  a 32 MB).

### Schermo e touch

Il server X usa la modalità dichiarata dallo schermo (EDID), quindi si può
cambiare monitor senza modificare l'installer. Se il pannello non dichiara
correttamente le sue modalità, impostarne una in modo esplicito.

Il pannello resistivo è un touchscreen USB PenMount (ID USB `14e1:6000`) gestito
dal driver standard `libinput`. L'asse Y risulta invertito, quindi
`install-kiosk.sh` scrive una calibrazione per il pannello 1024x768 in
`/etc/X11/xorg.conf.d/99-penmount-calibration.conf`:

```
Option "CalibrationMatrix" "1.080170 0 -0.025317 0 -1.064692 1.031648 0 0 1"
```

Se il file esiste già viene conservato, così una calibrazione fatta a mano non
viene sovrascritta. La procedura di ricalibrazione è in
[manutenzione.md](manutenzione.md#ricalibrare-il-touch).

## Logo di avvio (Plymouth)

`scripts/install-plymouth-splash.sh`:

- installa il tema `fabbri-hmi` e lo registra come alternativa
  `default.plymouth`: l'hook dell'initramfs di Ubuntu sceglie il tema solo da
  lì, non da `plymouthd.conf`;
- installa `plymouth-label` e `fontconfig-config`, senza i quali la creazione
  dell'initramfs fallisce;
- con una GPU Intel aggiunge `i915` all'initramfs, così il logo compare subito
  alla risoluzione nativa;
- scrive `/etc/default/grub.d/80-hmi-splash.cfg` (non modifica
  `/etc/default/grub`, che su Ubuntu 26.04 può mancare): aggiunge `quiet splash`
  al kernel, nasconde il menu GRUB senza attesa (`GRUB_TIMEOUT_STYLE=hidden`,
  `GRUB_TIMEOUT=0`; si apre con `Esc`, vedi
  [manutenzione.md](manutenzione.md#accesso-di-emergenza)) e imposta
  `GRUB_GFXPAYLOAD_LINUX=keep`, necessario con l'avvio BIOS legacy;
- al termine verifica che ogni initramfs contenga il tema e si ferma con un
  errore se manca.

Il logo compare solo nella parte di avvio gestita da Plymouth: il firmware e la
schermata UEFI precedenti al caricamento di Ubuntu non sono personalizzabili.

Sotto il logo compare la scritta **System starting up** con i puntini animati
(`text-0.png` … `text-3.png`, alternate ogni mezzo secondo da
`fabbri-hmi.script`). Quando Plymouth termina e parte Openbox, lo sfondo del
desktop (`kiosk/background.png`, installato in `/usr/share/hmi-kiosk/` e
impostato con `hsetroot`) mostra lo stesso logo nella stessa posizione con la
scritta fissa **Loading HMI...**. Resta visibile finché il servizio HMI non
risponde e Chrome si apre a schermo intero: lo schermo non diventa mai nero, e
se l'HMI non parte la scritta indica che il sistema è avviato ma manca l'HMI.

Per cambiare i testi (`TEXT`, `KIOSK_TEXT`), il font o il logo modificare `plymouth/make-text-images.py`,
rigenerare le immagini (richiede Pillow, istruzioni nel file) e reinstallare
logo e kiosk in manutenzione.

## Primo avvio

`autoinstall/user-data` copia il payload della chiavetta in `/opt/hmi-installer`
e abilita `hmi-firstboot.service`, che esegue `scripts/firstboot-setup.sh`:

| Passo | Script |
| --- | --- |
| zram, journal | `tune-system.sh` |
| logo di avvio | `install-plymouth-splash.sh` |
| Docker con i dati su `/data` | `install-docker.sh` |
| immagine e container Nexus H7 | `import-images.sh`, `apply-stack.sh` |
| kiosk | `install-kiosk.sh` |
| pulizia | `slim-system.sh` |
| sola lettura | `setup-readonly-root.sh` |

`firstboot-setup.sh --reconfigure` riesegue tutti i passi su un sistema già
installato, in modalità manutenzione.
