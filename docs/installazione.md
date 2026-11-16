# Installazione

Procedura completa per installare un PC HMI nuovo. **L'installazione cancella il
disco selezionato:** verificare con attenzione modello e capacità e fare un
backup prima di proseguire.

Per sapere come è fatto il sistema installato vedere
[architettura.md](architettura.md); per le operazioni successive
[manutenzione.md](manutenzione.md).

## Cosa serve

- Il PC HMI, con avvio **UEFI** abilitato nel firmware: il layout prevede una
  partizione EFI e non funziona con l'avvio BIOS legacy.
- Due chiavette USB: una da almeno 8 GB per la ISO di Ubuntu, una da almeno
  1 GB per i dati dell'installazione (`CIDATA`).
- Il PC di sviluppo con WSL (o Linux) e Docker, con i repository `ubuntu-nexus`
  e `nexus-h7` uno accanto all'altro (per esempio `~/repo/ubuntu-nexus` e
  `~/repo/nexus-h7`).
- Cavo Ethernet con DHCP e accesso a Internet per il PC HMI durante
  l'installazione.

## 1. Preparare le chiavette (PC di sviluppo)

### Chiavetta Ubuntu

Scaricare l'immagine ufficiale **Ubuntu Server 26.04 LTS**, verificarne il
checksum SHA256 pubblicato da Ubuntu e scriverla sulla prima chiavetta con Rufus
o balenaEtcher. Usare la ISO originale, senza modificarla.

### Chiavetta CIDATA

Formattare la seconda chiavetta in **FAT32** con etichetta **`CIDATA`**. La
formattazione ne cancella il contenuto: scegliere con attenzione la chiavetta.

- Windows: Esplora file › clic destro sulla chiavetta › Formatta, file system
  FAT32, etichetta `CIDATA`.
- Linux: `sudo mkfs.vfat -F 32 -n CIDATA /dev/sdY1`, dove `/dev/sdY1` è la
  partizione della chiavetta verificata con
  `lsblk -o NAME,SIZE,MODEL,FSTYPE,LABEL`.

### Chiave SSH (solo la prima volta)

Creare la chiave dedicata ai PC HMI, scegliendo una passphrase quando viene
chiesta:

```sh
ssh-keygen -t ed25519 -f ~/.ssh/nexus-hmi -C "nexus-hmi"
```

La chiave privata `~/.ssh/nexus-hmi` non va mai copiata altrove. La chiave
pubblica `~/.ssh/nexus-hmi.pub` viene inserita in automatico nella
configurazione: il PC HMI avrà il server SSH con accesso **solo tramite
chiave**, senza password, per l'utente amministratore. Senza questo file il PC
viene installato senza SSH. Per usare un'altra chiave pubblica:
`HMI_SSH_PUBKEY=/percorso/chiave.pub`.

### Copiare i file sulla chiavetta CIDATA

Con la chiavetta collegata, **da WSL**:

```sh
cd ~/repo/ubuntu-nexus
bash scripts/prepare-autoinstall-seed.sh --wsl
```

Lo script:

- chiede a Windows quale unità è la chiavetta FAT32 con etichetta `CIDATA`;
- la monta in WSL se serve (può chiedere la password di `sudo`): WSL vede da
  solo solo le unità collegate prima del suo avvio;
- costruisce l'immagine Nexus H7 e il bundle offline se mancano o se
  `deployment/compose.yaml` è cambiato dall'ultima volta. Se `nexus-h7` non è
  accanto a `ubuntu-nexus`, indicarlo con `NEXUS_H7_DIR=/percorso/nexus-h7`;
- aggiunge la chiave SSH pubblica, se esiste, e dice se SSH sarà attivo;
- copia `user-data`, `meta-data` e `payload.tar.gz` e mostra i file copiati;
- smonta la chiavetta se l'aveva montata lui.

Alla fine espellere la chiavetta da Windows prima di scollegarla. Se ci sono più
chiavette `CIDATA`, indicare quella da usare con `--wsl /mnt/e`. Se Windows non
assegna una lettera alla chiavetta, assegnarla da Gestione disco.

**Da Linux** montare prima la chiavetta:

```sh
sudo mkdir -p /mnt/cidata
sudo mount /dev/sdY1 /mnt/cidata
sudo bash scripts/prepare-autoinstall-seed.sh /mnt/cidata
sudo umount /mnt/cidata
```

Il preparatore scrive solo sulla chiavetta `CIDATA` e non tocca altri dischi.

## 2. Installare Ubuntu (PC HMI)

**Il partizionamento è automatico e cancella il disco interno senza chiedere
conferma.** Prima di iniziare scollegare dischi interni o esterni che non devono
essere cancellati: restano collegati solo l'SSD del PC e le due chiavette.

1. Collegare entrambe le chiavette e il cavo Ethernet, accendere il PC e
   premere più volte **`Esc`**. Nel *Boot Manager* scegliere, sotto
   **EFI Boot Devices**, la voce **`EFI USB Device (USB)`** e premere `Invio`.

   Non scegliere le voci sotto *Legacy USB* o *Legacy Hard Drive*: avviano in
   modalità BIOS legacy e l'installazione si ferma con il messaggio
   `HMI: installer started in legacy BIOS mode`.
2. Nel menu GRUB evidenziare l'installazione di Ubuntu e premere `e`. Alla fine
   della riga che contiene `/casper/vmlinuz` aggiungere uno spazio e
   `autoinstall`, poi avviare con `Ctrl`+`X` o `F10`. Lingua e tastiera non
   vengono chieste (sono impostate a italiano): se l'installer le chiede, non
   ha letto la chiavetta `CIDATA`.
3. Creare l'utente amministratore e configurare la rete. La password non viene
   salvata in nessun file: serve per la console del PC e per `sudo`, mentre via
   SSH si entra solo con la chiave.
4. Il disco viene partizionato senza altre schermate:

   | Uso | Dimensione | Filesystem | Mount point |
   | --- | ---: | --- | --- |
   | Partizione EFI | 512 MiB | FAT32 | `/boot/efi` |
   | Sistema (`hmi-root`) | 6 GiB | ext4 | `/` |
   | Dati (`hmi-data`) | spazio rimanente | ext4 | `/data` |

   Il disco scelto è il più piccolo disco interno **SATA/mSATA**; se non ce ne
   sono, il più piccolo **NVMe**. Le chiavette USB non vengono mai scelte. Se
   nessun disco corrisponde, l'installazione si ferma con un errore senza
   cancellare nulla.
5. Lasciare completare l'installazione: il contenuto della chiavetta `CIDATA`
   viene copiato in `/opt/hmi-installer`. Al riavvio togliere entrambe le
   chiavette.

   Se al riavvio Ubuntu non parte, premere `Esc` e scegliere la voce
   **ubuntu** sotto *EFI Boot Devices*. Per renderlo definitivo, nel setup del
   firmware mettere **ubuntu** al primo posto nell'ordine di avvio o
   disattivare *CSM/Legacy*.

Per controllare quale disco verrà scelto prima di avviare l'installazione, al
punto 2 aprire una console con `Ctrl`+`Alt`+`F2` e verificare che solo il disco
interno abbia `ata` (o `nvme`) nel percorso:

```sh
lsblk -d -o NAME,MODEL,SIZE,TRAN
for d in /dev/sd? /dev/nvme?n?; do [ -b "$d" ] && echo "$d $(udevadm info -q property -n "$d" | grep ^ID_PATH=)"; done
```

## 3. Primo avvio (automatico)

Lasciare collegata la rete e non togliere alimentazione. Il servizio
`hmi-firstboot.service` esegue, nell'ordine:

1. zram e limiti del journal;
2. logo di avvio Plymouth;
3. Docker, con i dati su `/data`;
4. caricamento dell'immagine Nexus H7 dal bundle e avvio del container;
5. kiosk: LightDM con accesso automatico, Openbox, Google Chrome;
6. rimozione di pacchetti, servizi e firmware non necessari;
7. attivazione del sistema in sola lettura;
8. riavvio.

Internet serve per i pacchetti apt e Google Chrome; l'immagine Nexus H7 arriva
dal bundle. L'avanzamento è in `/var/log/hmi-firstboot.log`, lo stato si vede
con `systemctl status hmi-firstboot.service`. Se un passo fallisce, il servizio
riprova dopo 60 secondi. Per seguire l'avanzamento in diretta (via SSH o da
console locale, `Ctrl`+`C` per uscire):

```sh
sudo tail -f /var/log/hmi-firstboot.log
```

Dal riavvio successivo compare il logo durante l'avvio, poi Chrome si apre a
schermo intero sul pannello Nexus H7.

## 4. Collegarsi e verificare

Dal PC di sviluppo, indicando la chiave con `-i`, l'utente amministratore
creato durante l'installazione e l'indirizzo IP del PC HMI. Per esempio, con
utente `gfv` e indirizzo `10.1.30.106`:

```sh
ssh -i ~/.ssh/nexus-hmi gfv@10.1.30.106
```

`-i` è necessario: SSH prova da solo solo le chiavi con i nomi standard
(`id_ed25519`, `id_rsa`), quindi senza `-i` risponde
`Permission denied (publickey)`. `nexus-hmi` è il nome della chiave, non
dell'utente.

Per non ripetere chiave e utente, aggiungere a `~/.ssh/config`:

```
Host hmi-*
    User gfv
    IdentityFile ~/.ssh/nexus-hmi
    IdentitiesOnly yes
Host hmi-linea1
    HostName 10.1.30.106
```

e collegarsi con `ssh hmi-linea1`. Senza rete, con una tastiera collegata al
PC: `Ctrl`+`Alt`+`F2` apre una console, `Ctrl`+`Alt`+`F7` torna al kiosk.

```sh
sudo hmi-rootfs status          # deve risultare in sola lettura
findmnt / /data /var/lib/containerd /var/log/journal
sudo docker ps                  # il container gateway deve essere "healthy"
df -h / /data
```

`/` deve risultare `overlay` e `/data` una partizione ext4 separata.

## 5. Collegare la macchina

Il gateway legge la seriale `/dev/ttyS4` a 38400 8N1. Verificare che la porta
esista e sia una UART reale, altrimenti il container non parte:

```sh
ls -l /dev/ttyS4
sudo dmesg | grep ttyS4         # deve indicare una UART, per esempio 16550A
```

Per cambiare porta, usare il convertitore seriale/Ethernet o pubblicare OPC UA
sulla rete di fabbrica, modificare `/data/hmi/.env` (le istruzioni sono nel
file; le opzioni sono descritte in [architettura.md](architettura.md#impostazioni-della-macchina))
e applicare:

```sh
sudo nano /data/hmi/.env
sudo hmi-apply-stack /data/hmi/compose.yaml
```

`/data` è scrivibile anche con il sistema in sola lettura: non serve la modalità
manutenzione.

## 6. Collaudo prima della produzione

- Il PC deve riaccendersi da solo dopo una mancanza di corrente (impostazione
  del BIOS/UEFI).
- Provare avvio a freddo, spegnimenti ripetuti, ripartenza di Chrome dopo un
  crash, HMI con il cavo di rete scollegato.
- Verificare risoluzione, grafica, precisione del touch, seriale macchina e ogni
  interfaccia di rete necessaria.
- Misurare RAM e disco con l'HMI reale (`free -h`, `zramctl`, `sudo docker stats`,
  `df -h / /data`): 2 GB di RAM e 16 GB di disco lasciano poco margine. Per la
  produzione è consigliato un SSD industriale da 64-128 GB.
- Limitare SSH alla rete di manutenzione e configurare il firewall (ancora da
  fare) quando sono note la sottorete e le porte esposte.
- Arresti di emergenza, interblocchi e sicurezze della macchina devono restare
  indipendenti dal kiosk.
- Definire periodo di supporto, gestione delle vulnerabilità, inventario del
  software e validazione degli aggiornamenti: una release LTS di Ubuntu da sola
  non garantisce la conformità al CRA.

## Appendice: installazione senza partizionamento automatico

Serve solo se il partizionamento automatico non trova il disco (per esempio un
controller che non risulta né SATA né NVMe). In quel caso avviare la chiavetta
Ubuntu **senza** il parametro `autoinstall`, così l'installer è interattivo.

Prima preparare il disco da un ambiente Linux avviato in UEFI: identificarlo con
`lsblk -o NAME,SIZE,MODEL,TYPE` e lanciare:

```sh
sudo bash scripts/partition-disk.sh /dev/sdX
```

Lo script rifiuta partizioni, dischi montati e dispositivi sotto i 10 GiB,
mostra modello e capacità e chiede di digitare `ERASE` seguito dal nome del
dispositivo. **Cancella tutti i dati sul disco confermato.** Poi, nella
schermata dello storage dell'installer, scegliere **Custom storage layout** (non
"Use an entire disk", che applica il layout predefinito di Ubuntu senza
`/data`) e assegnare la partizione EFI a `/boot/efi`, `hmi-root` a `/` e
`hmi-data` a `/data`, formattandole tutte e tre. Al termine copiare il payload e
lanciare il setup a mano, come in
[manutenzione.md](manutenzione.md#riapplicare-il-setup-completo).
