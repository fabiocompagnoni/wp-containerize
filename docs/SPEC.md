# SPEC — wp-containerize

Tool CLI open source per migrare siti **WordPress** da hosting condivisi (cPanel,
CloudPanel, Plesk o qualunque hosting raggiungibile via FTP/SFTP) a stack Docker isolati
su una VPS, ripulendoli e aggiornandoli lungo la strada. Dopo il rilascio i siti migrati
vengono mantenuti aggiornati in automatico (§4.6): tutto è parametrico e configurabile.

Pensato in particolare per i siti **potenzialmente compromessi** (PHP fuori supporto,
falle sfruttate attivamente): nessun sito arriva in produzione senza essere stato
analizzato e ripulito.

## 0. Ambito

**Dentro**: pipeline automatica per WordPress; hosting di siti statici HTML con un
template dedicato (estrazione + scansione + build/deploy, niente upgrade); bundle
portabile per sito, avviabile con `docker compose up` anche senza il tool (§5.1);
manutenzione automatica dei siti dopo il rilascio (§4.6).

**Fuori**: redirect di dominio, altri CMS, applicazioni PHP custom, posta (il tool non
tocca mai MX/SPF/DKIM), modifica automatica dei DNS, scelta del provider CDN (il tool
emette header compatibili con qualunque CDN).

## 1. Principi

- **Mai scrivere sulla sorgente.** Solo lettura via FTP/SFTP; il dump del DB lo fa
  l'operatore con gli strumenti del proprio hosting (phpMyAdmin, Adminer, `mysqldump`).
- **Codice estratto = dato non fidato.** Mai eseguito sull'host locale né sulla VPS:
  solo in container, e mai con rete libera.
- **Credenziali della sorgente considerate compromesse.** Password DB, salt, utenti admin
  e SMTP si rigenerano sempre.
- **Nessun sito va in produzione se non è pulito**: `scan` è `done` solo senza finding
  `high` aperti oppure con revisione manuale (`scan.reviewed_by`).
- **Fasi idempotenti e riprendibili**, stato nel manifest; una fase non parte se la
  precedente non è `done`; rilanciare una fase `done` non fa nulla senza `--force`.
- **Azioni irreversibili** (cutover, rimozione stack) chiedono conferma salvo `--yes`.

## 2. Configurazione

Il **progetto di lavoro** (dati dell'operatore e dei suoi clienti) è sempre separato dal
codice del tool. Tre livelli, nessun valore cablato nel codice:

| File | Contenuto | Da versionare? |
|---|---|---|
| `wp-containerize.yml` | registry, VPS, edge (TLS, IP della CDN), manutenzione, backup, default (PHP, limiti, cache, egress), AI review | sì, in un repo privato dell'operatore |
| `sites/<dominio>.yml` | manifest del sito: sorgente, inventario, target, sicurezza, stato | sì, privato |
| `.env` | **tutti** i segreti | **mai** (permessi 600) |

I template Jinja del tool si sovrascrivono copiandoli in `templates/` del progetto.

### 2.1 `.env`
- Chiavi globali: `REGISTRY_USER`, `REGISTRY_TOKEN`, `VPS_SSH_HOST`, `RESTIC_REPOSITORY`,
  `RESTIC_PASSWORD`, `COSIGN_PRIVATE_KEY`, `COSIGN_PASSWORD`, `MAINTENANCE_WEBHOOK_URL`, …
- Chiavi per sito: `<SLUG>__<NOME>`. Lo `slug` è **scritto nel manifest** (non ricavato
  dal dominio), così `a-b.com` e `a.b.com` non collidono. Esempi:
  `ESEMPIO_IT__FTP_HOST`, `…__FTP_USER`, `…__FTP_PASSWORD`, `…__FTP_PROTO`
  (`ftp|ftps|sftp`), `…__FTP_PORT`, `…__SMTP_PASSWORD`.
- Le credenziali **nuove** generate dal tool vanno in `<SLUG>__PROD_*`
  (`PROD_DB_PASSWORD`, `PROD_ADMIN_PASSWORD`, `PROD_WP_SALTS`, …).
- Il tool rifiuta un `.env` con permessi più larghi di 600 e maschera i valori nei log.
  I segreti non passano mai in argv dei processi figli (solo env o file temporanei 600).

## 3. Piattaforme e dipendenze

- Linux, macOS, Windows tramite **WSL**. Sull'host servono solo **Python 3.12+, Docker, ssh, git**.
- Installazione: `uv tool install wp-containerize` (o `pipx`). Pacchetto Python
  `wp_containerize`, comando `wp-containerize`.
- FTP/FTPS in Python (`ftplib` con riuso della sessione TLS sul canale dati, `MLSD`,
  connessioni parallele), SFTP con `paramiko`.
- Strumenti pesanti sempre in container: MariaDB, wp-cli, ClamAV, YARA, trivy, syft,
  cosign, restic.
- Claude Code CLI (`claude`) opzionale, per la fase `ai-review`.

## 4. Architettura di destinazione

### 4.1 VPS e reverse proxy nginx
Un IP per tutti i siti. **Tutto lo stack della VPS è in container**: nessun pannello e
nessun web server sull'host.

- Un unico container **`edge`** (nginx) ascolta su 80/443 e smista per `Host` ai
  container `app` dei siti, raggiunti tramite le reti per sito `<sito>_edge`, elencate nel
  suo `compose.yaml` generato dal tool (§4.2).
- Un file di vhost per sito, generato dal tool da un template Jinja in
  `/srv/infra/edge/conf.d/`, montato **read-only** nel container.
- Reload: `nginx -t` e poi `nginx -s reload` dentro il container. Se `nginx -t`
  fallisce, niente reload.
- I vhost risolvono l'upstream con il resolver DNS di Docker (`resolver 127.0.0.11`) e un
  upstream in variabile: nginx parte e si ricarica anche se il container `app` di un sito
  è fermo o la sua rete manca. Quel sito risponde 502, gli altri restano su.
- `docker compose up -d` su `edge` ricrea il container quando cambiano le sue reti: breve
  interruzione su 80/443 **per tutti i siti**. Succede solo al primo deploy e alla
  rimozione di un sito (§4.2), non ai deploy successivi.
- `edge` **non** ha accesso al socket Docker.
- `daemon.json` con `default-address-pools` (es. `10.200.0.0/16` in /24), perché ogni
  sito usa due reti.
- `wp-containerize infra up` genera `/srv/infra/*` dai template e avvia `edge`, `egress`
  e `maintainer` via ssh; `infra status` ne mostra lo stato.

**TLS gestito dalla CDN**: niente certificati automatici sulla VPS (né Let's Encrypt né
certbot). Due modalità (`edge.tls` in `wp-containerize.yml`):

- `origin-cert` (default): nginx termina TLS con il **certificato origin** rilasciato
  dalla CDN, fornito dall'operatore per dominio:
  `/srv/infra/edge/certs/<dominio>.crt` e `<dominio>.key`, permessi `0600`, mai nei log.
- `http`: nginx serve solo la porta 80 dietro la CDN. **Sconsigliato**: il tool lo
  segnala come tale.

In entrambi i casi:
- Accesso all'origine consentito **solo dagli IP della CDN** (`edge.trusted_proxies`,
  lista CIDR configurabile). Comportamento con lista vuota **[DA DEFINIRE]**.
- IP reale del client preso dall'header della CDN (`edge.real_ip_header`, es.
  `CF-Connecting-IP`) solo per richieste da quegli IP.
- `wp-config.php` fida di `X-Forwarded-Proto`/`X-Forwarded-For` solo da `edge`.
- Come si ottengono e si aggiornano le liste di IP dei principali CDN: **[DA VERIFICARE]**.

```
/srv/infra/
  edge/                      nginx: compose.yaml, conf.d/ (vhost, read-only), certs/ (0600)
  egress/                    proxy di egress condiviso, allowlist per sito (§4.2)
  maintainer/                manutenzione automatica (§4.6)
  backup/                    runner restic
/srv/sites/<sito>/           un sito = una cartella = il bundle di `build` (§5.1)
  compose.yaml               immagine per digest, rete <sito>_edge external
  compose.local.yaml         override per l'uso fuori dalla VPS (§5.1)
  .env                       generato da .env.example, 0600, owner root
  README
  data/uploads/              contenuti utente
  cache/                     page cache
  db/dump.sql.gz             importato solo al primo avvio, con db/data/ vuota
  db/data/                   dati MariaDB
```

### 4.2 Stack per sito (stesso template in locale e in produzione)
- `app`: immagine del sito (§5), Apache su 8080, UID/GID dedicato (range configurabile,
  default 20000+, assegnato in `site add`), `read_only: true`, `tmpfs` per `/tmp` e `/run`,
  `cap_drop: [ALL]`, `no-new-privileges`, limiti `cpus`/`mem_limit`/`pids_limit`.
  Scrivibili solo `uploads/`, `cache/` e i percorsi in `security.writable_paths`.
  PHP disabilitato in `uploads/` e `cache/`.
- `db`: **MariaDB dedicato**, volume `db/data/`, `my.cnf` tarato per bassi consumi, **nessuna porta**.
- `redis`: **dedicato**, senza persistenza, `maxmemory` configurabile.
- Reti: `<sito>_internal` (`internal: true`: app↔db↔redis) e `<sito>_edge` (app↔edge).
  - `<sito>_edge` è **per sito**: la crea il tool (`deploy`/`infra`) se manca. Il bundle
    la dichiara `external` con quel nome.
  - Collegamenti di `edge` persistenti, mai a runtime: il tool genera il `compose.yaml` di
    `edge` con le reti `<sito>_edge` dei siti con `status.deploy.state` in `running`
    (deploy in corso) o `done`, ricavate dai manifest e dichiarate `external`. Il sito del
    primo deploy è quindi già incluso al passo 6 (§7.10).
  - `deploy`, la rimozione di un sito e `infra up` rigenerano quel compose e applicano
    `docker compose up -d` su `edge`. Una ricreazione del container `edge` mantiene così
    tutti i collegamenti.
  - Rimozione di un sito, in ordine inverso al deploy:
    1. vhost rimosso, poi `nginx -t` e reload;
    2. `compose.yaml` di `edge` rigenerato senza la rete del sito e `docker compose up -d`
       su `edge`;
    3. solo alla fine, rete `<sito>_edge` eliminata.
  - Non esiste una rete `edge` condivisa: le app dei siti non si vedono tra loro.
- **Egress** chiuso di default. Uscite consentite solo via allowlist per sito
  (`security.egress.allow`), applicata da un unico container `egress` condiviso
  (`/srv/infra/egress/`) con ACL per rete di origine; l'email passa da `msmtp` nell'immagine verso l'SMTP
  configurato, unico host:porta consentito.

### 4.3 Accesso al DB
`wp-containerize db <sito>` apre un listener locale; ogni connessione esegue via ssh
`docker run -i --rm --network <sito>_internal alpine/socat STDIO TCP:db:3306`.
Nessuna porta pubblicata, il sidecar sparisce a fine connessione.

### 4.4 Cache e risorse
Obiettivo: quasi tutte le richieste servite da cache e CDN, container con risorse minime.
- Page cache su file servita da Apache **senza PHP** (plugin tipo Cache Enabler).
- `Cache-Control` adatti alla CDN; compressione e cache dei file statici.
- Redis object cache, OPcache con `validate_timestamps=0`.
- Plugin di cache legati al web server di origine (es. **LiteSpeed Cache**) vengono
  disattivati e rimossi in `upgrade`.
- `wp-containerize capacity` somma i limiti dei manifest e stima RAM e disco.

### 4.5 Backup
restic per sito verso qualunque repository restic (SFTP come Hetzner Storage Box, S3,
B2, …): dump giornaliero del DB + `data/`, retention configurabile, test di restore periodico.

### 4.6 Manutenzione automatica
Due momenti distinti: la **preparazione** (pipeline del §7, che porta il sito pulito e
aggiornato in produzione, §5) e la **manutenzione** dopo il rilascio, descritta qui.

Un container **`maintainer`** in `/srv/infra/maintainer` sulla VPS, con uno scheduler
interno (es. supercronic, **[DA VERIFICARE]**). A ogni esecuzione, per ogni sito con
`maintenance.enabled`:

1. Controlla se ci sono: una nuova patch PHP (digest dell'immagine base cambiato), una
   nuova versione del core WordPress, nuove versioni di plugin e temi **del repository
   ufficiale**. Se non c'è nessun aggiornamento, si ferma qui.
2. Backup del DB (restic) prima di qualunque modifica.
3. Aggiornamenti applicati in un container `dev` effimero sul codice del sito:
   - unica uscita il proxy `egress`, con allowlist `*.wordpress.org`;
   - il DB di produzione non viene toccato: `dev` lavora su una copia restaurata dal
     backup del passo 2, in un MariaDB effimero su una rete isolata;
   - wp-cli con `--skip-plugins --skip-themes`: il codice appena scaricato non gira prima
     dello scan del passo 4.
4. Scan dei file cambiati (checksum ufficiali + euristiche del §7.4): con finding `high`
   si ferma.
5. Build in un builder isolato (BuildKit in container, rootless **[DA VERIFICARE]**).
6. trivy, SBOM e firma (§5). trivy blocca con la regola del §5 e ferma il ciclo.
7. Push sul registry.
8. Deploy per digest (§7.10: non tocca `data/` né il DB), poi `wp core update-db` sul DB
   di produzione, che è la prima modifica a quel DB, poi `verify` (§7.11).
9. Se `verify` fallisce: **rollback automatico** al digest precedente, restore del DB
   dal backup del passo 2 e `git revert` del commit automatico.
10. Notifica all'operatore con l'esito (email via SMTP configurato e/o webhook).

Uno stop ai passi 4–7 (scan `high`, build, trivy, push) lascia la produzione intatta:
niente è stato deployato e il DB di produzione non è stato toccato. Si notifica e basta.

Il restore del passo 9 **perde i dati scritti** tra il backup e il rollback (ordini,
commenti).

Regole:
- Plugin e temi premium o custom **non** si aggiornano da soli: vengono segnalati nel
  report per un `upgrade` manuale.
- `maintainer` comanda Docker senza il socket grezzo: passa da un proxy dell'API Docker
  ristretto alle chiamate necessarie (es. `docker-socket-proxy`, **[DA VERIFICARE]**).
  Un filtro solo per endpoint **non basta**: `POST /containers/create` con bind di `/`,
  `privileged` o `cap_add` equivale a root sull'host. Serve un filtro anche sui parametri
  (bind, `privileged`, `cap_add`, network, devices) oppure un'alternativa (es. builder
  rootless separato).
- Il codice dei siti non gira mai nel container `maintainer`: solo nei container `dev`
  effimeri e nel builder.
- Il codice aggiornato viene registrato nel repo git del sito (commit automatico con
  l'elenco degli aggiornamenti), così la build resta riproducibile.
  **[DA DEFINIRE nel piano della milestone]**: dove vive il repo del sito sulla VPS e come
  si sincronizza con la macchina dell'operatore.
- Il `maintainer` firma con una chiave cosign **dedicata**, distinta da quella
  dell'operatore: una VPS compromessa potrebbe firmare immagini. Firma keyless
  **[DA DEFINIRE]**.
- Come arrivano al `maintainer` le credenziali di push sul registry e la sua chiave
  cosign **[DA DEFINIRE]**.
- `wp-containerize maintain <sito>|--all [--dry-run]` esegue lo stesso ciclo a mano dalla
  macchina dell'operatore. La sola ricostruzione per una patch PHP è un caso particolare
  di `maintain --all`.

Configurazione:
- `wp-containerize.yml`: `maintenance.enabled` (default `true`), `maintenance.schedule` in
  sintassi cron (default `"0 4 * * *"`), `maintenance.notify` con `email` (indirizzo,
  default nessuno) e `webhook` (`true`/`false`, default `false`).
- L'URL del webhook è un segreto: sta in `.env`, chiave globale `MAINTENANCE_WEBHOOK_URL`.
- SMTP usato per le notifiche (host, utente, password in `.env`): **[DA DEFINIRE]**.
- Manifest del sito: `maintenance.enabled` (default `true`), `maintenance.auto_plugins`
  (default `true`).
- Manutenzione attiva per un sito solo se `maintenance.enabled` è vero **sia** nel
  progetto **sia** nel manifest.
- `auto_plugins: false`: si aggiornano solo PHP/immagine base e core; plugin e temi
  vengono solo segnalati nel report.

## 5. Immagini Docker

**Preparazione prima del push.** Un'immagine arriva sul registry solo dopo la pipeline
completa: analisi dei file attuali della sorgente per compromissioni e codice malevolo
(`scan`), pulizia (`clean`), aggiornamento di core, plugin e temi **all'ultima versione**
e di PHP all'ultima patch (`upgrade`). Solo con `scan` e trivy puliti l'immagine viene
pubblicata. Dopo il rilascio subentra la manutenzione automatica (§4.6).

- Immagine propria, **non** `wordpress` ufficiale (il suo `VOLUME /var/www/html` rende
  il codice scrivibile e persistente tra gli aggiornamenti).
- `FROM php:<versione>-apache` pinnata per **digest**; versione PHP di default in
  `wp-containerize.yml` (oggi 8.5 con l'ultima patch), override per sito con `target.php`.
- Multi-stage: `base` (PHP + estensioni dal manifest + `redis` + OPcache + msmtp),
  `dev` (+ wp-cli, per il locale), `prod` (codice del sito, nessun tool di sviluppo).
- Docroot `/srv/app`. Core WordPress scaricato in build e verificato con i checksum
  ufficiali: **il core non viene mai preso dalla sorgente**. Plugin e temi puliti dal
  repo git del sito. `wp-config.php` generato da variabili d'ambiente.
- Utente non root, `HEALTHCHECK`, `.dockerignore`, label OCI (sorgente, commit, PHP, WP).
- Build riproducibile dal commit del repo git del sito; tag immutabile `<sha>`.
- `build` esegue **trivy** (blocca su CRITICAL/HIGH con fix disponibile), genera la SBOM
  (syft) e **firma** l'immagine con cosign; push su un **registry OCI privato**
  (es. GHCR). La VPS fa solo pull, **per digest**.
- Retention delle immagini configurabile. Quando esce una patch PHP le immagini si
  ricostruiscono con `maintain` (§4.6).
- Template `static`: `httpd:alpine` con i file del sito, read-only.

### 5.1 Bundle portabile
Oltre all'immagine sul registry, `build` produce `work/<sito>/bundle/`:

```
compose.yaml                 immagine referenziata per digest, rete `<sito>_edge` external
compose.local.yaml           override per l'uso fuori dalla VPS
.env.example                 solo i nomi delle variabili, senza valori
data/uploads/                ripulito, senza file PHP
db/dump.sql.gz               dump ripulito
README                       istruzioni
```

- Il bundle si avvia su qualunque host Docker, in locale o su una VPS, **anche senza il
  tool**. Serve l'accesso in pull al registry.
- Il dump si importa automaticamente **solo al primo avvio**, quando `db/data/` è vuota.
- Sulla VPS: `docker compose up`. `compose.yaml` dichiara la rete `<sito>_edge` come
  `external`, con quel nome; la rete esiste già (§4.2).
- Fuori dalla VPS: `docker compose -f compose.yaml -f compose.local.yaml up`.
  L'override:
  - pubblica `app` su `127.0.0.1:<porta>`;
  - non usa la rete external;
  - imposta `WP_HOME`/`WP_SITEURL` da env (`wp-config.php` è generato da env).
- `deploy` copia il bundle via ssh e lo avvia; `local up` usa lo stesso bundle.
- Non è una fase: il bundle è un artefatto di `build`.
- In locale gli URL assoluti nei contenuti restano quelli di produzione: se e come
  eseguire `wp search-replace` **[DA DEFINIRE]**.

## 6. Manifest per sito
`sites/<dominio>.yml`: identità (`site`, `slug`, `aliases`, `client`), sorgente,
inventario (popolato da `discover`), target, sicurezza, cache, verifica, cutover,
manutenzione (§4.6), stato.
Ogni fase scrive gli artefatti in `work/<sito>/<fase>/` e aggiorna `status.<fase>`
con `state`, `started_at`, `finished_at`, `artifacts` (SHA-256), `notes`.
Esempio in `docs/site.example.yml`.

## 7. Fasi

### 7.1 `site add` / `site import-csv`
Crea i manifest, anche in blocco da un CSV (colonne minime: `dominio`; opzionali:
`categoria`, `php`, `note`; formato documentato in `docs/`). Assegna `slug` e UID univoci.

### 7.2 `discover` (sola lettura, via FTP)
Versione WordPress (`wp-includes/version.php`), `table_prefix` e charset da
`wp-config.php`, plugin e temi con versione, `.htaccess`, `.user.ini`, `php.ini`,
dimensioni. Report `work/<sito>/discover/report.md` con ciò che **non** si migra in
automatico (cron, regole custom, servizi esterni, chiavi API da ruotare).

### 7.3 `extract`
- File: mirror FTP incrementale della docroot in `work/<sito>/extract/files/`
  (rilanci = solo differenze; serve anche al sync finale).
- DB: l'operatore esporta il database seguendo `docs/db-export.md` e salva
  `work/<sito>/extract/db.sql` più il risultato della **query di conteggio** fornita
  (tabelle e righe da `information_schema`).
- Verifica: charset, completezza, import di prova in MariaDB effimero, confronto con i
  conteggi.
- Snapshot in un repo git per sito (`work/<sito>/repo`, media esclusi) e SHA-256 di tutti i file.
- Nomi di file non validi o percorsi che escono dalla docroot vengono rifiutati e segnalati.

### 7.4 `scan` (senza eseguire codice)
- Checksum di core e plugin scaricati dal tool (api.wordpress.org /
  downloads.wordpress.org) e confrontati in Python sui file estratti. Plugin non presenti
  nel repository ufficiale → revisione.
- File PHP in uploads/cache/media → `high`. File modificati dopo `scan.modified_after`
  (data dell'incidente, da config) → elenco per revisione.
- ClamAV + YARA (regole per webshell) in container **senza rete**.
- Pattern sospetti: `eval(`, `base64_decode(` + `gzinflate`, `assert(` dinamico,
  `preg_replace` con `/e`, `create_function`, nomi casuali, `.htaccess` con
  `auto_prepend_file` o handler PHP su estensioni immagine.
- DB (sul MariaDB effimero): admin recenti o sconosciuti, `siteurl`/`home` alterati,
  `<script>`/iframe nei contenuti, cron WordPress sospetti.

### 7.5 `ai-review` (consultiva, disattivabile)
Analisi dei finding e dei file sospetti con Claude Code in modalità non interattiva:

```
claude -p --bare --strict-mcp-config --no-session-persistence \
  --tools Read,Grep,Glob --json-schema <schema> --output-format json
```

con cwd = copia read-only dello snapshot. Niente Bash, Web o MCP: un file malevolo che
tenta prompt injection può al massimo produrre un giudizio sbagliato, non agire.
L'output (file, riga, severità, motivazione, azione consigliata) entra nel report.
**Non porta mai `scan` a `done`**: serve sempre `scan.reviewed_by`.
Disattivata di default (`ai_review.enabled`), perché invia codice dei siti all'API
Anthropic: l'operatore la attiva consapevolmente.

### 7.6 `local up` / `wp`
Stack del sito in locale su `http://<sito>.localhost`, dati estratti. Dopo `build`,
`local up` avvia lo stesso bundle della produzione (§5.1); cosa avvia prima che esista
un bundle **[DA DEFINIRE]**.
`wp-containerize wp <sito> -- …` esegue wp-cli nel container `dev`; l'unica uscita è il
proxy `egress`, con l'allowlist del sito (`*.wordpress.org` + host dei plugin premium dichiarati),
configurato sia con `WP_PROXY_*` sia con `HTTP(S)_PROXY`. wp-cli non gira mai su codice
non ancora scansionato. Nella manutenzione (§4.6, passo 3) wp-cli scarica codice nuovo
prima dello scan, ma con `--skip-plugins --skip-themes` non lo carica: lo scan del passo 4
avviene prima che quel codice venga eseguito.

### 7.7 `clean`
Plugin e temi del repository ufficiale riscaricati puliti; premium/custom solo dopo
revisione; rimozione dei file confermati (lista nel report); nuovi salt, password DB,
password admin e SMTP. Le nuove credenziali vanno in `.env`, mai nei log.

### 7.8 `upgrade`
`wp core update`, `wp plugin update --all`, `wp theme update --all`, `wp core update-db`;
rimozione dei plugin di cache non compatibili; installazione redis object cache e page
cache; report di compatibilità PHP (phpcs + PHPCompatibility, con `ai-review` sui
temi/plugin custom). Siti non portabili in tempi ragionevoli:
`target.legacy_exception: true` con motivazione.

### 7.9 `build`
Genera Dockerfile/compose da template, build, trivy, SBOM, firma, push (§5); produce il
bundle portabile `work/<sito>/bundle/` (§5.1).

### 7.10 `deploy`
Via ssh, idempotente. Nessun DNS toccato.

- **Primo deploy**, in quest'ordine:
  1. UID/GID;
  2. copia del bundle (§5.1) in `/srv/sites/<sito>` (0750);
  3. rete `<sito>_edge` creata, se manca, prima di `docker compose up`;
  4. `.env` 0600 generato da `.env.example`;
  5. pull per digest e avvio (con `db/data/` vuota il DB importa il dump);
  6. `compose.yaml` di `edge` rigenerato e `docker compose up -d` su `edge` (§4.2);
  7. vhost nginx su `edge` (§4.1) con `nginx -t` e reload.
- **Deploy successivi**: aggiornano solo `compose.yaml`, README e `.env.example`, poi pull
  per digest e riavvio.
- I deploy successivi **non** toccano mai `data/` né il DB: nemmeno con `--force`, nemmeno
  al passo 8 della manutenzione (§4.6). Il deploy non sostituisce mai il DB: lo fanno solo
  l'import esplicito al cutover (§7.12, punto 3) e il restore automatico del passo 9 della
  manutenzione (§4.6).

### 7.11 `verify`
Via tunnel ssh con header `Host` (niente sottodomini pubblici di staging): status code
sulle URL del manifest e della sitemap, log PHP puliti, header di sicurezza, PHP bloccato
in uploads, nessun egress dal container, utente non root, page cache servita senza PHP.

### 7.12 `cutover`
1. TTL dei record web abbassato da almeno 24–48 h (il tool lo verifica).
2. Sync finale: delta FTP + nuovo dump → scan veloce dei delta.
3. Import esplicito del dump finale (il DB ha già dati, quindi niente import automatico):
   1. backup restic del DB di destinazione;
   2. import del nuovo dump pulito in un container effimero sulla rete `<sito>_internal`;
   3. `wp search-replace` se cambiano gli URL;
   4. `verify` (§7.11).
4. Vhost nginx del dominio attivo su `edge`: certificato origin presente (modalità
   `origin-cert`), accesso limitato agli IP della CDN.
5. **Checklist DNS solo dei record web, mai MX/SPF/DKIM**: il cambio lo fa l'operatore.
6. Verifica post-switch e certificato.
7. Sorgente intatta per `cutover.rollback_days`.

### 7.13 `backup`
Attivazione restic per il sito e primo test di restore.

## 8. Comandi

```
wp-containerize init
wp-containerize site add <dominio> | site import-csv <file.csv>
wp-containerize discover|extract|scan|ai-review|clean|upgrade|build|deploy|verify|cutover|backup <sito>
wp-containerize run <sito>|--all --until <fase>   # batch, si ferma ai punti di revisione manuale
wp-containerize local up|down <sito>
wp-containerize wp <sito> -- <argomenti wp-cli>
wp-containerize db <sito>
wp-containerize maintain <sito>|--all [--dry-run]   # manutenzione (§4.6), anche a mano
wp-containerize infra up|status                    # edge, egress, maintainer sulla VPS
wp-containerize status [--all] | report <sito> | capacity
```

## 9. Lingua
- **Italiano come lingua principale**: documentazione, messaggi della CLI, commenti, commit.
- **Traduzione inglese**: dopo la prima release stabile, la documentazione ha un albero
  parallelo completo in `docs/en/`; i messaggi della CLI sono tradotti con gettext (lingua
  scelta da `LANG` o `--lang`). Fino alla prima release stabile si traduce subito solo il
  README (`README.en.md`); le stringhe della CLI sono sempre dentro `_()`.
- Identificatori del codice (nomi di moduli, funzioni, variabili, chiavi di configurazione)
  in inglese, come da convenzione.

## 10. Qualità e sicurezza del codice
- Python 3.12+ con type hints completi; `ruff`, `mypy --strict`, `bandit`, `pip-audit`.
- `subprocess` sempre con liste di argomenti, mai `shell=True`; timeout espliciti.
- Validazione di domini, percorsi e nomi di file (niente path traversal dai file estratti).
- Log JSON per sito in `work/<sito>/logs/`, senza segreti.
- Test con `pytest`; FTP contro server di test locale (`pyftpdlib`); integrazione Docker
  marcata e opzionale; mai test contro server reali.

## 11. Flusso git
Branch per tipologia (`feat/`, `fix/`, `docs/`, `chore/`, `test/`, `refactor/`), commit
atomici con messaggi brevi in stile Conventional Commits, niente trailer di co-autore,
`main` sempre verde e merge `--no-ff` solo con test passati.

## 12. Da verificare
- Come ottenere e aggiornare le liste di IP dei principali CDN (`edge.trusted_proxies`).
- Scheduler interno del `maintainer` (es. supercronic).
- BuildKit in container in modalità rootless per il builder isolato della manutenzione.
- Proxy dell'API Docker per il `maintainer` (es. `docker-socket-proxy`): insieme minimo
  di chiamate e, soprattutto, filtro sui parametri di `POST /containers/create` (bind,
  `privileged`, `cap_add`, network, devices). Un filtro solo per endpoint non basta.
  In alternativa, builder rootless separato.
- Disponibilità del tag `php:8.5.<patch>-apache` con le ultime patch di sicurezza.
- Comportamento FTP degli hosting più diffusi (connessioni parallele, FTPS esplicito, `MLSD`).
