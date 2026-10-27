# WordPress su VPS: siti isolati dietro un unico proxy

```text
Cloudflare (Full strict) ──443──> edge (nginx)
                                    │  rete <sito>_edge, interna, una per sito
                                    ▼
                    nginx del sito ── wordpress (PHP-FPM) ── db (MariaDB)
                    (rate limit,           │                  redis
                     regole, cache)     Internet (rete egress)

timer systemd sull'host: wp-cron ogni 5 minuti, backup alle 02:00 UTC,
aggiornamenti alle 03:00 UTC (updater lanciato come job, poi rimosso)
```

- **`edge`**: l'unico container con una porta pubblicata. Fa TLS con il certificato Origin
  di ogni dominio, Authenticated Origin Pulls e accetta solo gli IP Cloudflare.
- **Stack di ogni sito**: separato dagli altri. I siti non si vedono tra loro.
- **Immagini**: le stesse per tutti i siti (wordpress, nginx, edge). Si costruiscono in
  locale, vanno su GHCR, e la VPS fa solo pull per digest (`images.env`).
- **File di ogni sito**: in `sites/<sito>/html`; impostazioni in `sites/<sito>/.env`,
  segreti in `sites/<sito>/secrets/`.
- **Rete di ogni sito**: un blocco fisso `10.200.<SITE_NET>.0/24` diviso in quattro reti
  (edge, web, data, egress). `new-site.sh` sceglie il primo `SITE_NET` libero: gli indirizzi
  non dipendono dai pool di Docker, quindi non si sovrappongono alla LAN e non finiscono.
- **Container identificabili**: `<sito>-nginx`, `<sito>-wordpress`, `<sito>-db`,
  `<sito>-redis`, con le etichette `wp.site`, `wp.domain` e `wp.service`.

Requisiti sulla VPS: Docker con il plugin Compose, `bash`, `openssl`.

## 1. Build delle immagini (in locale)

```bash
# una volta: REGISTRY=ghcr.io/<organizzazione> in build.local.env (non versionato)
docker login ghcr.io
./build.sh                # build, push, scrive images.env con i digest
```

## 2. Copia sulla VPS

```bash
rsync -a --exclude sites/ --exclude edge/conf.d/ --exclude edge/sites.yaml ./ root@<vps>:/srv/wp/
```

Una volta sulla VPS:

```bash
cd /srv/wp
docker login ghcr.io      # token con permesso read:packages
# CA di Authenticated Origin Pulls di Cloudflare (la stessa per tutte le zone)
curl -fsSo edge/origin-pull-ca.pem https://developers.cloudflare.com/ssl/static/authenticated_origin_pull_ca.pem

# wp-cron e aggiornamenti pianificati
cp systemd/wp-cron.* systemd/wp-update.* /etc/systemd/system/
systemctl daemon-reload && systemctl enable --now wp-cron.timer wp-update.timer
```

Dopo ogni `./build.sh`, ricopia `images.env` sulla VPS, poi riavvia i siti con
`./site.sh <sito> up -d` e l'edge con `./edge.sh`.

## 3. Migrare un sito

1. Esporta il database da phpMyAdmin: solo le tabelle, SQL, anche compresso `.gz`.
   Copialo sulla VPS.
2. Lancia, sulla VPS:

   ```bash
   ./migrate-site.sh esempio esempio.it --host ftp.example.net --user utente \
       --path /public_html --dump /root/esempio.sql.gz
   ```

   La password FTP viene chiesta al prompt. Le altre opzioni:
   - `--proto ftp|sftp`: protocollo, il default è FTPS esplicito;
   - `--insecure-tls`: per gli hosting con un certificato FTP generico;
   - `--test`: certificato autofirmato e nessun controllo Cloudflare.

   Lo script si ferma prima di avviare il sito se manca il certificato Origin.
   - Crealo in Cloudflare: SSL/TLS → Origin Server.
   - Salvalo in `sites/esempio/secrets/origin_cert.pem` e `origin_key.pem`, modo 0644.
   - Rilancia lo stesso comando: lo script riprende, e il download scarica solo ciò che manca.

3. Al primo avvio il sito importa il dump, riscrive gli URL sul nuovo dominio e
   azzera le password degli amministratori. Imposta quella nuova:

   ```bash
   ./site.sh esempio exec wordpress wp --allow-root user update <login> --prompt=user_pass --skip-email
   ```

4. Su Cloudflare:
   - record DNS del dominio e del `www` verso l'IP della VPS, con il proxy attivo;
   - SSL/TLS in **Full (strict)**;
   - **Authenticated Origin Pulls** attivo.

   Posta: non toccare MX, SPF e DKIM.

Se lo script segnala file PHP in `wp-content/uploads`, controllali e cancellali.
nginx comunque non li esegue mai.

Dopo la verifica, `sites/esempio/import/` si può svuotare per recuperare spazio.

## 4. Sito nuovo, da zero

```bash
./new-site.sh esempio esempio.it   # poi il certificato Origin in sites/esempio/secrets/
./site.sh esempio up -d --wait && ./edge.sh
```

## Backup

Ogni giorno alle 02:00 UTC, prima degli aggiornamenti, `backup.sh` fa uno snapshot restic
cifrato per ogni sito sulla Storage Box Hetzner. Ogni snapshot contiene il dump del DB,
`html/`, `.env` e `secrets/`. La conservazione è di 7 giornalieri, 4 settimanali e 6 mensili.

Una volta sulla VPS:

1. Su Hetzner Robot, nella Storage Box, attiva **SSH support**.
2. Prepara la configurazione e inizializza il repository:

   ```bash
   cp backup.env.example backup.env   # RESTIC_REPOSITORY con utente e host della Storage Box
   ./backup.sh init
   ```

   `init` genera chiave e password, poi mostra la chiave pubblica.
3. Caricala da un'altra shell:

   ```bash
   ssh-copy-id -p 23 -s -f -i backup/id_ed25519.pub u123456@u123456.your-storagebox.de
   ```

   Poi torna a `init` e premi Invio.
4. **Copia `backup/restic_password` nel password manager**: senza quella i backup non si leggono.
5. Attiva il timer e fai subito una prima prova:

   ```bash
   cp systemd/wp-backup.* /etc/systemd/system/
   systemctl daemon-reload && systemctl enable --now wp-backup.timer
   ./backup.sh run                    # prima prova subito
   ```

Per controllare e ripristinare:

```bash
./backup.sh restic snapshots --tag site:esempio
./backup.sh restic restore latest --tag site:esempio --target /restore   # in backup/restore/

# database
./site.sh esempio exec -T wordpress wp --allow-root db import - < backup/restore/dumps/esempio.sql
./site.sh esempio exec -T wordpress wp --allow-root cache flush

# file
rsync -a --delete backup/restore/sites/esempio/html/ sites/esempio/html/
```

## Gestione

```bash
./site.sh esempio ps                          # stato
./site.sh esempio logs -f wordpress           # log
docker ps --filter label=wp.domain=esempio.it # container di un dominio
./jobs.sh update esempio                      # aggiornamento subito (backup, verifiche, rollback)
./jobs.sh cron esempio                        # wp-cron subito
./site.sh esempio exec wordpress wp --allow-root plugin list
./edge.sh                                     # rigenera i vhost dopo un cambio di siti
./edge.sh --recreate                          # dopo aver sostituito un certificato
./remove-site.sh esempio                      # elimina sito, database e file (chiede conferma)
```

- **Risorse di ogni sito** (CPU, RAM, worker PHP, buffer di MariaDB): si impostano in
  `sites/<sito>/.env`, poi `./site.sh <sito> up -d`. I worker PHP partono solo quando
  arrivano richieste e si chiudono dopo 10 s di inattività.
- **Aggiornamenti**: ogni giorno alle 03:00 UTC, un sito alla volta (`wp-update.timer`).
- **Controllo vulnerabilità**: serve la chiave Wordfence Intelligence in
  `sites/<sito>/secrets/wordfence_api_key`.
