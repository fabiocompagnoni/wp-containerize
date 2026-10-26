# SPEC — wp-containerize

Tool CLI open source per migrare siti **WordPress** da hosting condivisi (cPanel,
CloudPanel, Plesk o qualunque hosting raggiungibile via FTP/SFTP) a stack Docker isolati
su una VPS, ripulendoli e aggiornandoli lungo la strada. Resta lo strumento di
manutenzione dei siti migrati: tutto è parametrico e configurabile.

Pensato in particolare per i siti **potenzialmente compromessi** (PHP fuori supporto,
falle sfruttate attivamente): nessun sito arriva in produzione senza essere stato
analizzato e ripulito.

## 0. Ambito

**Dentro**: pipeline automatica per WordPress; hosting di siti statici HTML con un
template dedicato (estrazione + scansione + build/deploy, niente upgrade).

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
| `wp-containerize.yml` | registry, VPS, edge (TLS, IP della CDN), backup, default (PHP, limiti, cache, egress), AI review | sì, in un repo privato dell'operatore |
| `sites/<dominio>.yml` | manifest del sito: sorgente, inventario, target, sicurezza, stato | sì, privato |
| `.env` | **tutti** i segreti | **mai** (permessi 600) |

I template Jinja del tool si sovrascrivono copiandoli in `templates/` del progetto.

### 2.1 `.env`
- Chiavi globali: `REGISTRY_USER`, `REGISTRY_TOKEN`, `VPS_SSH_HOST`, `RESTIC_REPOSITORY`,
  `RESTIC_PASSWORD`, `COSIGN_PRIVATE_KEY`, `COSIGN_PASSWORD`, …
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
  container `app` dei siti.
- Un file di vhost per sito, generato dal tool da un template Jinja in
  `/srv/infra/edge/conf.d/`, montato **read-only** nel container.
- Reload: `nginx -t` e poi `nginx -s reload` dentro il container. Se `nginx -t`
  fallisce, niente reload.
- `edge` **non** ha accesso al socket Docker.
- `daemon.json` con `default-address-pools` (es. `10.200.0.0/16` in /24), perché ogni
  sito usa due reti.

**TLS gestito dalla CDN**: niente certificati automatici sulla VPS (né Let's Encrypt né
certbot). Due modalità (`edge.tls` in `wp-containerize.yml`):

- `origin-cert` (default): nginx termina TLS con il **certificato origin** rilasciato
  dalla CDN, fornito dall'operatore per dominio. Sta in `/srv/infra/edge/certs/`, permessi
  `0600`, mai nei log. Nomi dei file per dominio **[DA DEFINIRE]**.
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
  egress/                    proxy di egress con allowlist
  backup/                    runner restic
/srv/sites/<sito>/           un sito = una cartella (self-contained)
  compose.yaml
  .env                       generato, 0600, owner root
  data/uploads/              contenuti utente
  cache/                     page cache
  db/                        dati MariaDB
```

### 4.2 Stack per sito (stesso template in locale e in produzione)
- `app`: immagine del sito (§5), Apache su 8080, UID/GID dedicato (range configurabile,
  default 20000+, assegnato in `site add`), `read_only: true`, `tmpfs` per `/tmp` e `/run`,
  `cap_drop: [ALL]`, `no-new-privileges`, limiti `cpus`/`mem_limit`/`pids_limit`.
  Scrivibili solo `uploads/`, `cache/` e i percorsi in `security.writable_paths`.
  PHP disabilitato in `uploads/` e `cache/`.
- `db`: **MariaDB dedicato**, volume `db/`, `my.cnf` tarato per bassi consumi, **nessuna porta**.
- `redis`: **dedicato**, senza persistenza, `maxmemory` configurabile.
- Reti: `<sito>_internal` (`internal: true`: app↔db↔redis) e `<sito>_edge` (app↔edge).
  `edge` è collegato alle reti `<sito>_edge` di tutti i siti; i siti non si vedono tra loro.
- **Egress** chiuso di default. Uscite consentite solo via allowlist per sito
  (`security.egress.allow`); l'email passa da `msmtp` nell'immagine verso l'SMTP
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

## 5. Immagini Docker

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
- Retention delle immagini configurabile. `wp-containerize rebuild --all` ricostruisce
  tutto quando esce una patch PHP.
- Template `static`: `httpd:alpine` con i file del sito, read-only.

## 6. Manifest per sito
`sites/<dominio>.yml`: identità (`site`, `slug`, `aliases`, `client`), sorgente,
inventario (popolato da `discover`), target, sicurezza, cache, verifica, cutover, stato.
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
Stack del sito in locale su `http://<sito>.localhost`, dati estratti.
`wp-containerize wp <sito> -- …` esegue wp-cli nel container `dev`; l'unica uscita è un
proxy per sito con allowlist (`*.wordpress.org` + host dei plugin premium dichiarati),
configurato sia con `WP_PROXY_*` sia con `HTTP(S)_PROXY`. wp-cli non gira mai su codice
non ancora scansionato.

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
Genera Dockerfile/compose da template, build, trivy, SBOM, firma, push (§5).

### 7.10 `deploy`
Via ssh, idempotente: UID/GID, `/srv/sites/<sito>` (0750), `.env` 0600, rsync di `data/`,
creazione DB, import del dump pulito con `wp search-replace`, pull per digest, avvio, vhost
nginx su `edge` (§4.1) con `nginx -t` e reload. Nessun DNS toccato.

### 7.11 `verify`
Via tunnel ssh con header `Host` (niente sottodomini pubblici di staging): status code
sulle URL del manifest e della sitemap, log PHP puliti, header di sicurezza, PHP bloccato
in uploads, nessun egress dal container, utente non root, page cache servita senza PHP.

### 7.12 `cutover`
1. TTL dei record web abbassato da almeno 24–48 h (il tool lo verifica).
2. Sync finale: delta FTP + nuovo dump → scan veloce dei delta.
3. Vhost nginx del dominio attivo su `edge`: certificato origin presente (modalità
   `origin-cert`), accesso limitato agli IP della CDN.
4. **Checklist DNS solo dei record web, mai MX/SPF/DKIM**: il cambio lo fa l'operatore.
5. Verifica post-switch e certificato.
6. Sorgente intatta per `cutover.rollback_days`.

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
wp-containerize rebuild --all
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
- Disponibilità del tag `php:8.5.<patch>-apache` con le ultime patch di sicurezza.
- Comportamento FTP degli hosting più diffusi (connessioni parallele, FTPS esplicito, `MLSD`).
