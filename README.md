# Kiosk HMI industriale su Ubuntu Server 26.04 LTS

Installazione automatica di un PC fanless come kiosk per l'HMI **Nexus H7**
(gateway per la CPU ARMSTM32H7 e pannello operatore). Alla fine il PC si accende
direttamente sul pannello operatore, a schermo intero.

**Hardware di riferimento:** Intel Celeron N3350, 2 GB di RAM, SSD da 16 GB.

## Come è fatto il sistema

- **Disco diviso in due:** il sistema (`/`, 6 GiB) è in **sola lettura** e
  riparte pulito a ogni avvio; i dati (`/data`) restano sempre scrivibili.
- **L'HMI gira in un container Docker:** un solo container serve il pannello
  (porta 3001) e OPC UA (porta 4841) e legge la seriale macchina `/dev/ttyS4`.
- **Kiosk:** Chrome a schermo intero, senza menu né scorciatoie.
- **Accesso di manutenzione:** SSH solo con chiave, oppure console locale.

## Installazione in breve

1. **Sul PC di sviluppo (WSL):** scrivere la ISO di Ubuntu Server 26.04 su una
   chiavetta, formattarne un'altra in FAT32 con etichetta `CIDATA`, poi:

   ```sh
   ssh-keygen -t ed25519 -f ~/.ssh/nexus-hmi -C "nexus-hmi"   # solo la prima volta
   cd ~/repo/ubuntu-nexus
   bash scripts/prepare-autoinstall-seed.sh --wsl
   ```

2. **Sul PC HMI:** all'accensione premere `Esc` e scegliere
   **`EFI USB Device (USB)`** sotto *EFI Boot Devices* (non le voci *Legacy*),
   aggiungere
   `autoinstall` alla riga del kernel in GRUB, creare l'utente e configurare la
   rete. Il disco interno viene partizionato da solo (EFI, `/`, `/data`).
   ⚠️ Il disco interno viene cancellato **senza conferma**: scollegare prima
   ogni altro disco da conservare.
3. **Primo avvio:** automatico; installa tutto e riavvia sul pannello operatore.
4. **Verifica:** `ssh -i ~/.ssh/nexus-hmi gfv@10.1.30.106` (utente
   amministratore e IP del PC HMI; `-i` è necessario), poi
   `sudo hmi-rootfs status` e `sudo docker ps`.

Ogni passo è spiegato in dettaglio nella
[guida di installazione](docs/installazione.md).

## Documentazione

| Documento | Quando serve |
| --- | --- |
| [Installazione](docs/installazione.md) | preparare le chiavette, installare un PC nuovo, collegare la macchina, collaudo |
| [Manutenzione](docs/manutenzione.md) | aggiornare HMI e Ubuntu, tornare a una versione precedente, ricalibrare il touch, accesso di emergenza |
| [Architettura](docs/architettura.md) | come funzionano disco, sola lettura, container, rete, kiosk e logo di avvio |

## Struttura del repository

```
autoinstall/    configurazione di Subiquity (user-data) e servizio del primo avvio
deployment/     compose.yaml e modello .env di Nexus H7; bundle/ generato con l'immagine
plymouth/       tema del logo di avvio e generatore della scritta "System starting up"
kiosk/          sfondo di Openbox mostrato finché Chrome non è aperto
scripts/        preparazione della chiavetta, provisioning e comandi di manutenzione
docs/           documentazione
```
