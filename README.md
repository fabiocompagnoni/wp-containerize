# wp-containerize

[English version](README.en.md)

Tool a riga di comando per migrare siti WordPress da hosting condivisi, raggiungibili
via FTP/SFTP, a stack Docker isolati e aggiornati. Ogni sito viene estratto in sola
lettura, analizzato alla ricerca di codice malevolo, ripulito, aggiornato e infine
impacchettato in un bundle portabile, da eseguire su una VPS o in locale.

Pensato anche per siti potenzialmente compromessi: nessun sito arriva in produzione
senza analisi e pulizia.

> **Stato: in sviluppo, non pronto per la produzione.** Le interfacce possono cambiare
> senza preavviso.

## Requisiti

- Linux, macOS o Windows tramite WSL
- Python 3.12 o successivo
- Docker
- ssh e git

Tutto il resto (database, wp-cli, scanner) gira in container.

## Installazione per lo sviluppo

Serve [uv](https://docs.astral.sh/uv/).

```bash
uv sync
uv run wp-containerize --version
uv run pytest
```

## Documentazione

- [Specifica](docs/SPEC.md)
- [Come contribuire](CONTRIBUTING.md)
- [Politica di sicurezza](SECURITY.md)

## Licenza

Apache-2.0, vedi [LICENSE](LICENSE).
