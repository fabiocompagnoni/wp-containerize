# Contribuire

Lingua principale: italiano (documentazione, messaggi, commenti, commit). Gli
identificatori del codice sono in inglese. Leggi `CLAUDE.md` e `docs/SPEC.md` prima di
iniziare.

## Ambiente

```bash
uv sync
uv run pre-commit install
```

## Branch e commit

- Un branch per tipologia: `feat/`, `fix/`, `docs/`, `chore/`, `test/`, `refactor/`.
- Commit atomici con messaggi brevi nel formato `tipo(scope): descrizione`.
- `git add` selettivo; merge `--no-ff` su `main` solo con i test verdi.

## Controlli

Prima di ogni commit devono passare:

```bash
uv run ruff check
uv run ruff format --check
uv run mypy src
uv run bandit -q -r src
uv run pytest
```

Gli stessi controlli (tranne `pytest`) girano come hook pre-commit; `uv run pip-audit`
verifica le dipendenze. I test non contattano mai server reali e non contengono dati
reali: usa `esempio.it`, `example.com`, `ftp.example.net`.

## Traduzioni

Le stringhe della CLI vanno racchiuse in `_()`. I cataloghi gettext si gestiscono con
`pybabel` (estrazione, aggiornamento, compilazione); la traduzione inglese va aggiornata
nello stesso cambiamento che modifica un messaggio. Fino alla prima release stabile si
traduce subito solo il README (`README.en.md`).

---

# Contributing

Primary language: Italian (docs, messages, comments, commits). Code identifiers are in
English. Read `CLAUDE.md` and `docs/SPEC.md` first.

## Setup

```bash
uv sync
uv run pre-commit install
```

## Branches and commits

- One branch per type: `feat/`, `fix/`, `docs/`, `chore/`, `test/`, `refactor/`.
- Atomic commits with short messages in the form `type(scope): description`.
- Selective `git add`; `--no-ff` merge into `main` only with green tests.

## Checks

Before each commit these must pass:

```bash
uv run ruff check
uv run ruff format --check
uv run mypy src
uv run bandit -q -r src
uv run pytest
```

The same checks (except `pytest`) run as pre-commit hooks; `uv run pip-audit` checks the
dependencies. Tests never contact real servers and contain no real data: use
`esempio.it`, `example.com`, `ftp.example.net`.

## Translations

CLI strings must be wrapped in `_()`. gettext catalogs are managed with `pybabel`
(extract, update, compile); update the English translation in the same change that
alters a message. Until the first stable release only the README (`README.en.md`) is
translated right away.
