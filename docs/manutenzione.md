# Manutenzione

Operazioni su un PC HMI già installato. I comandi si lanciano via SSH o dalla
console locale (vedere [installazione.md](installazione.md#4-collegarsi-e-verificare)).

## Comandi rapidi

| Cosa | Comando |
| --- | --- |
| Stato del sistema (sola lettura o manutenzione) | `sudo hmi-rootfs status` |
| Applicare una modifica a `/data/hmi/.env` | `sudo hmi-apply-stack /data/hmi/compose.yaml` |
| Aggiornare l'HMI da chiavetta | `sudo hmi-import-images /mnt/usb/bundle/images.tar.gz` poi `sudo hmi-apply-stack /mnt/usb/bundle/compose.yaml` |
| Tornare alla versione precedente dell'HMI | `sudo hmi-apply-stack --rollback` |
| Aggiornare Ubuntu | `sudo hmi-rootfs disable --reboot` poi `sudo hmi-rootfs upgrade` |
| Tornare in sola lettura senza aggiornare | `sudo hmi-rootfs enable --reboot` |
| Stato dei container | `sudo docker ps` |

## Sola lettura e modalità manutenzione

In esercizio il sistema è in sola lettura: ogni modifica a `/` (pacchetti,
file di configurazione) **sparisce al riavvio**. `/data` resta sempre
scrivibile, quindi impostazioni e aggiornamenti dell'HMI non richiedono la
manutenzione.

Per modificare il sistema in modo permanente:

```sh
sudo hmi-rootfs disable --reboot    # riavvia con il sistema scrivibile
# ... modifiche ...
sudo hmi-rootfs enable --reboot     # torna in sola lettura
```

Gli script di installazione si rifiutano di partire se il sistema è in sola
lettura.

Se dopo `hmi-rootfs enable --reboot` lo stato è ancora `Now: WRITABLE`,
probabilmente l'initramfs è stato creato con dracut, che ignora
`/etc/overlayroot.conf` (vedere [architettura.md](architettura.md#sistema-in-sola-lettura)).
`sudo hmi-rootfs check-initramfs` lo conferma. Per correggerlo, in modalità
manutenzione:

```sh
sudo apt install initramfs-tools overlayroot   # rimuove dracut
cd /opt/hmi-installer && sudo bash scripts/install-plymouth-splash.sh   # rigenera l'initramfs con il logo
sudo hmi-rootfs check-initramfs
sudo hmi-rootfs enable --reboot
```

## Montare una chiavetta

Ubuntu Server non monta in automatico le chiavette USB:

```sh
sudo lsblk -o NAME,TRAN,SIZE,FSTYPE,LABEL,MOUNTPOINTS,MODEL
sudo mkdir -p /mnt/usb
sudo mount -o ro /dev/sdX1 /mnt/usb
```

Sostituire `/dev/sdX1` con la partizione della chiavetta, non con il disco
interno. Al termine: `sudo umount /mnt/usb`.

## Aggiornare Nexus H7

### Preparare la nuova versione (PC di sviluppo)

1. In `deployment/compose.yaml` cambiare il tag dell'immagine, per esempio
   `localhost/nexus-h7:1.1.0`.
2. Costruire il bundle:

   ```sh
   bash scripts/build-nexus-bundle.sh ~/repo/nexus-h7
   ```

   Crea `deployment/bundle/` con `images.tar.gz`, `compose.yaml` e
   `SHA256SUMS`. Va rilanciato a mano anche quando cambia `nexus-h7` senza
   cambiare il tag; altrimenti ci pensa `prepare-autoinstall-seed.sh`.
3. Copiare `deployment/bundle/` su una chiavetta. Per le nuove installazioni
   basta ripreparare la chiavetta `CIDATA`.

### Installarla sul PC HMI

Con la chiavetta montata in `/mnt/usb`:

```sh
sudo hmi-import-images /mnt/usb/bundle/images.tar.gz
sudo hmi-apply-stack /mnt/usb/bundle/compose.yaml
```

`hmi-import-images` verifica i checksum e lo spazio libero. Se la nuova versione
non diventa sana, `hmi-apply-stack` torna da solo a quella precedente; per
tornare indietro a mano: `sudo hmi-apply-stack --rollback`. Il funzionamento è
descritto in [architettura.md](architettura.md#aggiornamenti-con-hmi-apply-stack).

## Aggiornare Ubuntu

```sh
sudo hmi-rootfs disable --reboot    # riavvia con il sistema scrivibile
sudo hmi-rootfs upgrade             # apt full-upgrade, pulizia, sola lettura, riavvio
```

## Riapplicare il setup completo

Serve se il primo avvio non è andato a buon fine o per applicare una nuova
versione degli script a un PC già installato.

1. Passare in manutenzione: `sudo hmi-rootfs disable --reboot`.
2. Ripreparare la chiavetta `CIDATA` sul PC di sviluppo
   ([installazione.md](installazione.md#copiare-i-file-sulla-chiavetta-cidata)),
   montarla sul PC HMI e lanciare:

   ```sh
   sudo mkdir -p /opt/hmi-installer
   sudo tar -xzf /mnt/usb/payload.tar.gz -C /opt/hmi-installer
   sudo bash /opt/hmi-installer/scripts/firstboot-setup.sh --reconfigure
   ```

Lo script riapplica tutto il setup, conserva `/data/hmi/.env`, riattiva la sola
lettura e riavvia.

Lo script non scrive nulla sul terminale: tutto l'output, errori compresi, va in
`/var/log/hmi-firstboot.log`. Seguirlo da una seconda sessione:

```sh
sudo tail -f /var/log/hmi-firstboot.log
```

Se il terminale torna al prompt e il PC non si riavvia, lo script si è fermato:
la causa è nelle ultime righe del log. Il sistema resta scrivibile; dopo la
correzione basta rilanciare `firstboot-setup.sh --reconfigure`.

La procedura **non tocca le partizioni**: richiede che `/data` sia già montata
e si ferma se non lo è.

- `/data` resta com'è: immagini Docker, database, journal e `/data/hmi/.env`.
- Vengono riscritti i file di sistema e del progetto: pacchetti, configurazioni,
  `/data/hmi/compose.yaml`, logo di avvio e i comandi `hmi-*`.

Le partizioni vengono create solo all'installazione, quando il PC si avvia
dalla chiavetta di installazione di Ubuntu: non avviare il PC da quella
chiavetta, perché può cancellare il disco. La chiavetta `CIDATA` invece si monta solo
per copiare il payload, a sistema già avviato.

Per aggiornare solo il logo di avvio, in manutenzione e dopo aver estratto il
payload:

```sh
sudo bash /opt/hmi-installer/scripts/install-plymouth-splash.sh
sudo hmi-rootfs enable --reboot
```

## Ricalibrare il touch

La calibrazione è un file di sistema: passare prima in manutenzione
(`sudo hmi-rootfs disable --reboot`). Lanciare i comandi via SSH, così la
sessione del kiosk resta sullo schermo.

```sh
sudo apt install xinput xinput-calibrator
x() { sudo -u kiosk env DISPLAY=:0 XAUTHORITY=/home/kiosk/.Xauthority "$@"; }
x xinput set-prop "PenMount PenMount USB" "libinput Calibration Matrix" 1 0 0 0 1 0 0 0 1
x xinput_calibrator -v --device "PenMount PenMount USB" | tee ~/calib.txt
```

`xinput_calibrator` stampa una configurazione per `evdev`: non installarla,
perché il driver attivo è `libinput`. Convertire i valori `MinX MaxX MinY MaxY`
(intervallo 0-65535) in una matrice:

```sh
read minx maxx miny maxy <<< "1536 62207 63501 1948"   # valori da calib.txt
awk -v a=$minx -v b=$maxx -v c=$miny -v d=$maxy -v R=65535 'BEGIN{
  printf "%.6f 0 %.6f 0 %.6f %.6f 0 0 1\n", R/(b-a), -a/(b-a), R/(d-c), -c/(d-c) }'
```

1. Provarla subito con
   `x xinput set-prop "PenMount PenMount USB" "libinput Calibration Matrix" <9 valori>`
   e controllare i quattro angoli e il centro.
2. Scrivere gli stessi valori in
   `/etc/X11/xorg.conf.d/99-penmount-calibration.conf`.
3. Riavviare LightDM (`sudo systemctl restart lightdm`) e verificare.
4. Tornare in sola lettura: `sudo hmi-rootfs enable --reboot`.

Se viene segnalato che serve `SwapXY`, la matrice deve anche scambiare gli assi.
Da una console locale (`Ctrl`+`Alt`+`F2`) Xorg sospende i dispositivi di input:
in quel caso avviare il calibratore in background con un ritardo e tornare al
kiosk con `sudo chvt`.

## Accesso di emergenza

Se il sistema non si avvia o il kiosk impedisce di aprire una console:

1. riavviare e, **appena sparisce il logo del firmware**, premere `Esc` più
   volte finché compare il menu GRUB (normalmente è nascosto e non aspetta).
   Se invece si apre il menu di avvio del firmware (`Esc` premuto troppo presto),
   scegliere la voce del disco interno/Ubuntu e continuare a premere `Esc`.
   Poi scegliere **Advanced options for Ubuntu**;
2. evidenziare **recovery mode**, premere `e` e aggiungere
   `overlayroot=disabled` alla riga `linux`, così le modifiche vengono scritte
   sul disco e non in RAM; avviare con `Ctrl`+`X`;
3. nel menu recovery scegliere **Enable networking**, poi
   **root - Drop to root shell prompt**;
4. rendere scrivibile la radice con `mount -o remount,rw /` ed eseguire i
   comandi necessari, senza `sudo`.

`overlayroot=disabled` vale solo per quell'avvio.

## Controlli periodici

- Spazio libero: `df -h /data` e `sudo docker system df`; tenere almeno il 20%
  libero su `/data`.
- Log persistenti: `journalctl -b -1` mostra l'avvio precedente, anche dopo un
  riavvio con il sistema in sola lettura.
