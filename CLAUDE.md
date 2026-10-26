# wp-containerize — migrazione di siti WordPress verso Docker

## Cos'è
Tool CLI open source (Apache-2.0) che porta siti WordPress da hosting condivisi
(cPanel, CloudPanel, Plesk, qualunque hosting FTP/SFTP) a stack `docker compose` isolati
su una VPS, ripulendoli e aggiornandoli lungo la strada. Pensato anche per siti
potenzialmente compromessi: nessun sito arriva in produzione senza analisi e pulizia.
Dopo il rilascio i siti migrati vengono mantenuti aggiornati in automatico dal container
`maintainer` sulla VPS.

```
discover → extract → scan → ai-review → clean → upgrade → build (immagine + bundle) → deploy → verify → cutover → backup
poi, sulla VPS: maintain (manutenzione automatica)
```

Dettagli completi in `docs/SPEC.md`. Esempio di manifest in `docs/site.example.yml`.

## Regole non negoziabili
- **Mai scrivere o cancellare nulla sulla sorgente.** Solo lettura via FTP/SFTP.
- **Ogni fase è idempotente e riprendibile.** Lo stato sta nel manifest
  (`status.<fase>`), con timestamp e hash degli artefatti. Rilanciare una fase completata
  non fa nulla senza `--force`.
- **Nessuna fase parte se quella precedente non è `done`.** `scan` può essere
  `done` solo se pulito o revisionato a mano (`scan.reviewed_by`); `ai-review` è solo consultiva.
- **Tutti i segreti in `.env`**, mai nel repo, mai nei log, mai in argv dei processi figli.
  Le credenziali della sorgente non vengono mai riusate: password DB, salt WordPress,
  utenti admin e SMTP si rigenerano.
- **Il codice estratto è dato non fidato.** Non eseguirlo mai sulla macchina locale
  né sull'host della VPS: solo dentro container, mai con rete libera.
- Claude Code nella pipeline gira solo con `Read,Grep,Glob`, senza Bash/Web/MCP.
- Operazioni distruttive o irreversibili (cutover, rimozione stack) chiedono conferma
  interattiva salvo `--yes`. Mai toccare MX/SPF/DKIM.
- **Nessun dato reale nel repo**: niente domini, clienti, host o credenziali di
  installazioni vere, nemmeno in test, esempi o messaggi di commit. Usare `esempio.it`,
  `example.com`, `ftp.example.net`.

## Stack del tool
- Python 3.12+, `typer`, `pydantic` + `pydantic-settings`, `ruamel.yaml` (commenti
  preservati), `jinja2`, `httpx`, `paramiko`, `rich`.
- Sull'host solo Python, Docker, ssh, git. Tutto il resto in container: MariaDB, wp-cli,
  ClamAV, YARA, trivy, syft, cosign, restic. Claude Code CLI opzionale.
- Qualità: `ruff`, `mypy --strict`, `bandit`, `pip-audit`, `pytest`.
  Mai test contro server reali: FTP con `pyftpdlib`, HTTP con risposte registrate.

## Layout del repo
```
src/wp_containerize/
  cli.py  config.py  manifest.py  state.py  secrets.py  log.py  i18n.py
  docker.py  remote.py
  sources/ftp.py         # mirror FTP/FTPS/SFTP
  wordpress/             # wp-config, checksum, rilevamento
  phases/*.py            # una fase per file
  templates/wordpress/   # Dockerfile, compose, apache, php.ini, my.cnf, wp-config
  templates/static/
  scanners/              # regole YARA, query SQL sospette
  locale/                # traduzioni gettext (en)
infra/                   # edge (nginx), egress, maintainer, restic, daemon.json
docs/                    # italiano; docs/en/ traduzione inglese (dopo la prima release stabile)
tests/
```
Il progetto di lavoro dell'operatore (`wp-containerize.yml`, `.env`, `sites/`, `work/`)
vive fuori dal repo o in `private/`, esclusa da git: non leggerne né citarne il contenuto
in file versionati.

## Lingua
Italiano come lingua principale (documentazione, messaggi CLI, commenti, commit);
traduzione inglese nei cataloghi gettext e, dopo la prima release stabile, in `docs/en/`
(albero parallelo completo). Identificatori del codice in inglese.
Fino alla prima release stabile si traduce subito solo il README (`README.en.md`); le
stringhe della CLI sono sempre dentro `_()`.

## Come lavorare
- Procedi per milestone, ognuna chiusa con una prova end-to-end. Non scrivere tutto insieme.
- **Git**: branch per tipologia (`feat/`, `fix/`, `docs/`, `chore/`, `test/`, `refactor/`),
  commit atomici con messaggi brevi (`tipo(scope): descrizione`), **mai** il trailer
  Co-Authored-By, `git add` selettivo, merge `--no-ff` su `main` solo con test verdi.
- Codice da senior: type hints completi, funzioni piccole, errori espliciti, `subprocess`
  solo con liste di argomenti e timeout, validazione di ogni input dai file estratti.
- Dove la SPEC segna **[DA VERIFICARE]** controlla la documentazione ufficiale prima di
  implementare e aggiorna la SPEC.
- Le decisioni che cambiano cosa si costruisce le prende il maintainer: chiedile invece
  di sceglierle.
