# M1 — Fondamenta: piano di implementazione

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Lo scheletro di `wp-containerize`: modelli, segreti, configurazione, manifest, stato delle fasi, log, traduzioni e i comandi `init`, `site add`, `site import-csv`, `status`.

**Architecture:** Pacchetto Python in layout `src/`. Il dominio è descritto da modelli pydantic (`models.py`). Attorno ci sono servizi piccoli, uno per file: segreti (`.env`), configurazione del progetto, archivio dei manifest con ruamel, macchina a stati delle fasi e log con mascheramento. La CLI typer è un guscio sottile sopra questi servizi.

**Tech Stack:** Python ≥3.12, uv, hatchling, typer, pydantic v2, ruamel.yaml, python-dotenv (solo parsing), rich, Babel/gettext; pytest, ruff, mypy, bandit, pip-audit, pre-commit.

**Spec:** `docs/SPEC.md` (§1–2, §6, §8–11), `CLAUDE.md`, esempio `docs/site.example.yml`.

## Global Constraints

- Python `>=3.12`; pacchetto `wp_containerize`, comando `wp-containerize`; licenza Apache-2.0.
- Piattaforme: Linux, macOS, WSL. `fcntl` è ammesso, Windows nativo no.
- Prerequisiti sull'host: Python, Docker, ssh, **git**.
- Lingua: messaggi utente in **italiano** dentro `_()`, con catalogo `en`. Identificatori in inglese.
- **Nessun dato reale**: domini solo `esempio.it`, `example.com`, `example.org`, `ftp.example.net`.
- `.env` con permessi oltre `0600` → errore. I segreti non compaiono mai in log, `repr` o argv.
- Scritture su disco **atomiche**: file temporaneo nella stessa cartella, `fsync`, `os.replace`.
- `subprocess` mai con `shell=True`. In M1 non serve.
- Git: un branch per task, commit `tipo(scope): descrizione` in italiano, **mai Co-Authored-By**, `git add` selettivo, merge `--no-ff` su `main` solo con controlli verdi, poi `git push`.
- Controlli prima di ogni merge: `uv run pre-commit run --all-files` e `uv run pytest`.

## Review Focus

1. **Domini scritti male nel CSV o a mano** (`Esempio.IT.`, spazi, IDN, `http://`): vanno normalizzati o rifiutati con un messaggio chiaro, senza traceback. Il test è in Task 3.
2. **CSV esportati da Excel in italiano** (separatore `;`, BOM UTF-8): vanno letti correttamente. Il test è in Task 10.
3. **`.env` con CRLF, `#`, `$` o virgolette nei valori**: i valori si leggono alla lettera, senza interpolazione. Il test è in Task 4.
4. **Manifest modificato a mano con YAML non valido o chiavi sconosciute**: errore con percorso del file e riga, senza traceback. Il test è in Task 6.
5. **Fase interrotta con Ctrl-C**: lo stato diventa `failed`, mai `running` per sempre. Il test è in Task 7.

---

### Task 1: Documenti aggiornati (prerequisiti, lingua, layout, CSV)

**Branch:** `docs/prerequisiti`

**Files:**
- Modify: `docs/SPEC.md` (§3: aggiungere git; §9: README tradotto subito, il resto dopo)
- Modify: `CLAUDE.md` (layout `src/wp_containerize/`; regola traduzioni come in SPEC)
- Create: `docs/csv-import.md`

- [ ] **Step 1:** in SPEC §3, "Sull'host servono solo **Python 3.12+, Docker, ssh**" diventa "…**Python 3.12+, Docker, ssh, git**". In §9 aggiungere: "Fino alla prima release stabile si traduce subito solo il README (`README.en.md`); le stringhe della CLI sono sempre dentro `_()`."
- [ ] **Step 2:** in CLAUDE.md il layout diventa `src/wp_containerize/…` e la frase "Ogni modifica a un documento…" diventa la regola dello Step 1.
- [ ] **Step 3:** scrivere `docs/csv-import.md`:
  - UTF-8 con o senza BOM, separatore `,` o `;` riconosciuto in automatico, prima riga di intestazione;
  - colonna obbligatoria `dominio`; colonne opzionali `categoria`, `tipo`, `cliente`, `source_host`, `php`, `note`; le altre vengono ignorate;
  - `--map campo=colonna` per usare nomi di colonna diversi;
  - `--categoria wordpress,statico` filtra le righe (default: entrambe), con `statico` → tipo `static`;
  - esempio con soli domini `example.com`/`esempio.it`.
- [ ] **Step 4:** fare tre commit separati e il merge:

```bash
git switch -c docs/prerequisiti
git add docs/SPEC.md && git commit -m "docs(spec): git tra i prerequisiti e regola traduzioni"
git add CLAUDE.md && git commit -m "docs: layout src e regola traduzioni in CLAUDE.md"
git add docs/csv-import.md && git commit -m "docs: formato del CSV di import"
git switch main && git merge --no-ff docs/prerequisiti && git push
```

### Task 2: Scaffolding del pacchetto

**Branch:** `chore/scaffolding`

**Files:**
- Create: `pyproject.toml`, `uv.lock`, `.pre-commit-config.yaml`, `src/wp_containerize/__init__.py`, `src/wp_containerize/__main__.py`, `src/wp_containerize/cli.py`, `src/wp_containerize/py.typed`, `tests/test_cli_version.py`, `README.md`, `README.en.md`, `SECURITY.md`, `CONTRIBUTING.md`

**Interfaces:**
- Produces: `wp_containerize.__version__: str = "0.1.0.dev0"`; `wp_containerize.cli.app: typer.Typer`; console script `wp-containerize = "wp_containerize.cli:app"`.

- [ ] **Step 0:** `uv --version`. Se manca, **fermarsi e chiedere a Fabio** di installarlo: non installarlo da soli.
- [ ] **Step 1: test che fallisce**

```python
from typer.testing import CliRunner
from wp_containerize import __version__
from wp_containerize.cli import app

def test_version_option_prints_version() -> None:
    result = CliRunner().invoke(app, ["--version"])
    assert result.exit_code == 0
    assert __version__ in result.stdout
```

- [ ] **Step 2:** `pyproject.toml`:
  - build `hatchling`
  - `requires-python = ">=3.12"`
  - dipendenze runtime: `typer`, `pydantic>=2`, `ruamel.yaml`, `python-dotenv`, `rich`
  - gruppo dev: `pytest`, `pytest-cov`, `ruff`, `mypy`, `bandit`, `pip-audit`, `pre-commit`, `babel`
  - ruff con regole `E,F,W,I,B,UP,S,SIM,RUF`
  - mypy `strict = true`
  - pytest `testpaths = ["tests"]`, `addopts = "-ra --strict-markers"`, marker `docker`
  - bandit esclude `tests`

  Poi `uv sync`.
- [ ] **Step 3:** `uv run pytest tests/test_cli_version.py -v`. Atteso: FAIL (modulo mancante).
- [ ] **Step 4:** `cli.py` contiene `app` con un callback che gestisce `--version` (eager) e stampa `wp-containerize <versione>`. `__main__.py` chiama `app()`.
- [ ] **Step 5:** `uv run pytest -v`. Atteso: PASS.
- [ ] **Step 6:** `.pre-commit-config.yaml` con hook locali (`uv run ruff check`, `uv run ruff format --check`, `uv run mypy src`, `uv run bandit -q -r src`), più `check-yaml`, `end-of-file-fixer`, `detect-private-key`. Poi `uv run pre-commit install` e `uv run pre-commit run --all-files`. Atteso: tutto verde.
- [ ] **Step 7:** documenti:
  - `README.md` in italiano: cos'è, stato "in sviluppo, non pronto per la produzione", requisiti, installazione dev con `uv sync`, link a SPEC e licenza
  - `README.en.md`: stessa cosa in inglese, con un link reciproco tra i due
  - `SECURITY.md`: segnalazioni private tramite GitHub Security Advisories, niente issue pubbliche
  - `CONTRIBUTING.md`: branch, commit, controlli, traduzioni con pybabel
- [ ] **Step 8: commit e merge**

```bash
git switch -c chore/scaffolding
git add pyproject.toml uv.lock src/wp_containerize tests/test_cli_version.py && git commit -m "chore: scheletro del pacchetto e opzione --version"
git add .pre-commit-config.yaml && git commit -m "chore: controlli pre-commit"
git add README.md README.en.md && git commit -m "docs: README in italiano e inglese"
git add SECURITY.md CONTRIBUTING.md && git commit -m "docs: politica di sicurezza e guida per contribuire"
git switch main && git merge --no-ff chore/scaffolding && git push
```

### Task 3: Modelli del dominio

**Branch:** `feat/models`

**Files:**
- Create: `src/wp_containerize/models.py`, `tests/test_models.py`

**Interfaces:**
- Produces:
  - `class Phase(StrEnum)`, valori: `discover, extract, scan, ai-review, clean, upgrade, build, deploy, verify, cutover, backup`
  - `class SiteType(StrEnum)`: `wordpress`, `static`
  - `class PhaseState(StrEnum)`: `pending, running, review, done, failed, skipped`
  - `PHASES_BY_TYPE: Mapping[SiteType, tuple[Phase, ...]]`: per `wordpress` tutte le fasi nell'ordine sopra; per `static` `discover, extract, scan, build, deploy, verify, cutover, backup`
  - `class PhaseStatus(BaseModel)`: `state=PENDING`, `started_at: datetime | None`, `finished_at: datetime | None`, `artifacts: dict[str, str] = {}` (valori `"sha256:<hex>"`), `notes: str | None`, `error: str | None`, `reviewed_by: str | None`
  - `normalize_domain(value: str) -> str`, `slug_from_domain(domain: str) -> str`, `validate_slug(value: str) -> str`
  - `class SiteManifest(BaseModel)` con i campi di `docs/site.example.yml`:
    - `site`, `slug`, `aliases: list[str]`, `client: str | None`, `type: SiteType`
    - `source: Source` (`provider: str = "other"`, `account`, `host`, `docroot: str = "/"`)
    - `inventory: dict[str, Any] = {}`
    - `target: Target` (`php: str | None`, `uid: int`, `legacy_exception: bool = False`, `legacy_reason: str | None`)
    - `security: Security` (`read_only: bool = True`, `writable_paths`, `egress.allow`, `smtp: Smtp | None`, `premium_update_hosts`, `limits: Limits | None`, `trivy_waivers: list[TrivyWaiver]`, dove `TrivyWaiver` ha `id`, `reason`, `expires: date`)
    - `cache: CacheSettings | None`, `verify` (`urls: list[str] = ["/"]`), `cutover` (`ttl_lowered_at: datetime | None`, `rollback_days: int = 14`)
    - `maintenance: SiteMaintenance` (`enabled: bool = True`, `auto_plugins: bool = True`)
    - `status: dict[Phase, PhaseStatus]`
  - `class ProjectConfig(BaseModel)`:
    - `version: Literal[1]`
    - `registry` (`host: str = "ghcr.io"`, `namespace: str`)
    - `edge` (`tls: Literal["origin-cert", "http"] = "origin-cert"`, `trusted_proxies: list[str] = []`, `real_ip_header: str | None = None`)
    - `maintenance` (`enabled: bool = True`, `schedule: str = "0 4 * * *"`, `notify: MaintenanceNotify`), dove `MaintenanceNotify` ha `email: str | None = None` e `webhook: bool = False` (l'URL sta in `.env`, `MAINTENANCE_WEBHOOK_URL`)
    - `defaults` (`php: str = "8.5"`, `uid_range: tuple[int, int] = (20000, 29999)`, `limits: Limits`, `cache: CacheSettings`)
    - `scan` (`modified_after: date | None`)
    - `ai_review` (`enabled: bool = False`)
    - `backup` (`keep_daily: int = 7`, `keep_weekly: int = 4`, `keep_monthly: int = 6`)
    - `paths` (`sites: str = "sites"`, `work: str = "work"`, `templates: str = "templates"`)
  - `class Limits(BaseModel)`: `cpus: str = "0.5"`, `memory: str = "192m"`, `pids: int = 100`
  - `class CacheSettings(BaseModel)`: `page: bool = True`, `cdn_max_age: int = 3600`, `redis_maxmemory: str = "32mb"`, `mariadb_buffer_pool: str = "64M"`
  - `class Smtp(BaseModel)`: `host: str`, `port: int`, `user: str`. `class Egress(BaseModel)`: `allow: list[str] = []`
  - Tutti i modelli usano `ConfigDict(extra="forbid")`.

- [ ] **Step 1: test che falliscono**

```python
@pytest.mark.parametrize(("raw", "expected"), [
    ("Esempio.IT.", "esempio.it"), ("  example.com ", "example.com"),
])
def test_normalize_domain_accepts(raw: str, expected: str) -> None:
    assert normalize_domain(raw) == expected

def test_normalize_domain_encodes_idn() -> None:
    assert normalize_domain("città.it").startswith("xn--")

@pytest.mark.parametrize("raw", ["http://example.com", "example", "a/b.com", "../x.com",
                                 "-bad.com", "a..com", "a" * 64 + ".com", "exa mple.com"])
def test_normalize_domain_rejects(raw: str) -> None:
    with pytest.raises(ValueError):
        normalize_domain(raw)

def test_slug_from_domain() -> None:
    assert slug_from_domain("mio-sito.example.com") == "MIO_SITO_EXAMPLE_COM"

@pytest.mark.parametrize("raw", ["lower", "A__B", "1ABC", "A-B"])
def test_validate_slug_rejects(raw: str) -> None:
    with pytest.raises(ValueError):
        validate_slug(raw)

def test_example_manifest_is_valid() -> None:
    data = YAML(typ="safe").load(Path("docs/site.example.yml"))
    m = SiteManifest.model_validate(data)
    assert m.site == "esempio.it" and m.status[Phase.AI_REVIEW].state is PhaseState.PENDING

def test_legacy_exception_requires_reason() -> None:
    with pytest.raises(ValidationError):
        Target(uid=20000, legacy_exception=True, legacy_reason=None)

def test_unknown_key_is_rejected() -> None:
    with pytest.raises(ValidationError):
        SiteManifest.model_validate({**minimal_manifest(), "typo": 1})
```

- [ ] **Step 2:** `uv run pytest tests/test_models.py -v`. Atteso: FAIL.
- [ ] **Step 3: implementare `models.py`**
  - **Regole di `normalize_domain`:**
    - si applica `strip()`, poi `rstrip(".")`, poi `lower()`, poi la codifica `encodings.idna`
    - si rifiuta se contiene caratteri fuori da `[a-z0-9.-]` dopo la codifica, o se ha meno di 2 etichette
    - ogni etichetta deve essere lunga 1–63 caratteri e non iniziare né finire con `-`
    - il totale non deve superare 253 caratteri
  - **Slug:** `^[A-Z][A-Z0-9_]{0,63}$`, senza `__`.
  - **`slug_from_domain`:** maiuscolo, ogni carattere che non è alfanumerico diventa `_`, poi si comprimono gli `_` doppi.
  - Validator di modello per `site` e `aliases` che usa `normalize_domain`, e per `legacy_reason`.
- [ ] **Step 4:** `uv run pytest tests/test_models.py -v`. Atteso: PASS. Se `docs/site.example.yml` non rispetta il modello, correggere **l'esempio**, che va nello stesso commit, solo se lo scarto è un refuso dell'esempio. Se invece è il modello a essere incompleto rispetto alla SPEC, correggere il modello.
- [ ] **Step 5: commit e merge**

```bash
git switch -c feat/models
git add src/wp_containerize/models.py tests/test_models.py && git commit -m "feat(models): manifest, configurazione e validazione dei domini"
git switch main && git merge --no-ff feat/models && git push
```

### Task 4: Segreti (`.env`)

**Branch:** `feat/secrets`

**Files:**
- Create: `src/wp_containerize/errors.py`, `src/wp_containerize/secrets.py`, `tests/test_secrets.py`

**Interfaces:**
- Produces:
  - `errors.py`: `class WpcError(Exception)`, base di tutti gli errori mostrati all'utente
  - `class InsecureSecretsFileError(WpcError)`, `class MissingSecretError(WpcError)` (il messaggio contiene solo il **nome** della chiave)
  - `class SecretStore`:
    - `get(key: str) -> SecretStr`, `site(slug: str, name: str) -> SecretStr` (chiave `f"{slug}__{name}"`)
    - `has(key: str) -> bool`, `keys() -> frozenset[str]`
    - `redaction_values() -> frozenset[str]` (valori di almeno 4 caratteri)
  - `load_env(path: Path) -> SecretStore`
  - `write_secrets(path: Path, updates: Mapping[str, str]) -> None`
  - `create_env_file(path: Path, content: str) -> None` (crea con `0600`, fallisce se il file esiste)
  - `generate_password(length: int = 32) -> str`, `generate_wp_salts() -> dict[str, str]`

- [ ] **Step 1: test che falliscono**

```python
def test_load_rejects_group_readable(tmp_path: Path) -> None:
    env = tmp_path / ".env"; env.write_text("A=1\n"); env.chmod(0o644)
    with pytest.raises(InsecureSecretsFileError):
        load_env(env)

def test_values_are_literal(tmp_path: Path) -> None:
    env = write_env(tmp_path, 'P1="a#b$c"\r\nP2=x$HOME\r\n')
    store = load_env(env)
    assert store.get("P1").get_secret_value() == "a#b$c"
    assert store.get("P2").get_secret_value() == "x$HOME"

def test_missing_secret_message_has_no_values(tmp_path: Path) -> None:
    store = load_env(write_env(tmp_path, "OTHER=topsecret\n"))
    with pytest.raises(MissingSecretError) as exc:
        store.site("ESEMPIO_IT", "FTP_PASSWORD")
    assert "ESEMPIO_IT__FTP_PASSWORD" in str(exc.value) and "topsecret" not in str(exc.value)

def test_write_preserves_comments_and_mode(tmp_path: Path) -> None:
    env = write_env(tmp_path, "# commento\nA=1\n")
    write_secrets(env, {"A": "2", "B": 'x"y'})
    assert env.read_text().startswith("# commento\n")
    assert load_env(env).get("B").get_secret_value() == 'x"y'
    assert env.stat().st_mode & 0o777 == 0o600

@pytest.mark.parametrize(("key", "value"), [("bad-key", "v"), ("OK", "a\nb")])
def test_write_rejects_bad_input(tmp_path: Path, key: str, value: str) -> None:
    with pytest.raises(ValueError):
        write_secrets(write_env(tmp_path, ""), {key: value})

def test_salts_have_expected_keys_and_safe_chars() -> None:
    salts = generate_wp_salts()
    assert set(salts) == {"AUTH_KEY", "SECURE_AUTH_KEY", "LOGGED_IN_KEY", "NONCE_KEY",
                          "AUTH_SALT", "SECURE_AUTH_SALT", "LOGGED_IN_SALT", "NONCE_SALT"}
    assert all(len(v) == 64 and not set(v) & set("'\"\\$`") for v in salts.values())
```

`write_env` è un helper di test che scrive con `0600`.

- [ ] **Step 2:** `uv run pytest tests/test_secrets.py -v`. Atteso: FAIL.
- [ ] **Step 3: implementare `secrets.py`**
  - Parsing con `dotenv_values(path, interpolate=False)`.
  - Controllo dei permessi: `st_mode & 0o077 == 0` e proprietario `os.getuid()`.
  - `write_secrets` riscrive riga per riga: aggiorna le chiavi esistenti, aggiunge le nuove in fondo e scrive i valori tra doppi apici con `\` e `"` protetti. Poi fa una scrittura atomica: `os.open(tmp, O_CREAT|O_EXCL|O_WRONLY, 0o600)`, `fsync`, `os.replace`.
  - Generatori con `secrets.choice` su `ascii_letters + digits` (password) e `ascii_letters + digits + "!#%&()*+,-./:;<=>?@[]^_{|}~"` (salt).
- [ ] **Step 4:** `uv run pytest tests/test_secrets.py -v`. Atteso: PASS.
- [ ] **Step 5: commit e merge**

```bash
git switch -c feat/secrets
git add src/wp_containerize/errors.py src/wp_containerize/secrets.py tests/test_secrets.py && git commit -m "feat(secrets): lettura e scrittura sicura del .env"
git switch main && git merge --no-ff feat/secrets && git push
```

### Task 5: Configurazione del progetto

**Branch:** `feat/config`

**Files:**
- Create: `src/wp_containerize/config.py`, `tests/test_config.py`
- Modify: `src/wp_containerize/errors.py`

**Interfaces:**
- Consumes: `ProjectConfig`, `SiteManifest`, `Limits`, `CacheSettings` (Task 3); `WpcError`, `load_env`, `SecretStore` (Task 4).
- Produces:
  - `errors.py`: `class ConfigError(WpcError)`, con `path: Path` e `line: int | None`
  - `CONFIG_FILENAME = "wp-containerize.yml"`, `ENV_FILENAME = ".env"`
  - `class ProjectNotFoundError(WpcError)`
  - `find_project_root(start: Path) -> Path` (risale fino alla radice del filesystem)
  - `load_yaml(path: Path) -> Any`, che trasforma gli errori di ruamel in `ConfigError` con riga
  - `@dataclass(frozen=True) class Project`:
    - campi `root`, `config`, `secrets`
    - proprietà `sites_dir`, `work_dir`, `templates_dir`, `env_path`
    - `site_work_dir(domain: str) -> Path`
  - `load_project(start: Path | None = None) -> Project`
  - `@dataclass(frozen=True) class SiteSettings`: `php: str`, `limits: Limits`, `cache: CacheSettings`
  - `resolve_site_settings(project: Project, manifest: SiteManifest) -> SiteSettings`: il manifest prevale sui `defaults` del progetto

- [ ] **Step 1: test che falliscono**
  - `test_find_root_from_subdir`: la radice si trova partendo da una sottocartella
  - `test_project_not_found`: errore il cui messaggio contiene `wp-containerize.yml`
  - `test_invalid_yaml_reports_line`: `ConfigError.line == 3` per un file con errore alla riga 3
  - `test_site_overrides_defaults`: manifest con `target.php: "8.4"` e `cache: None` → `php == "8.4"`, `cache == defaults.cache`
- [ ] **Step 2:** `uv run pytest tests/test_config.py -v`. Atteso: FAIL.
- [ ] **Step 3:** implementare `config.py` ed `errors.py` secondo le Interfaces.
- [ ] **Step 4:** `uv run pytest -v`. Atteso: PASS.
- [ ] **Step 5: commit e merge**

```bash
git switch -c feat/config
git add src/wp_containerize/config.py src/wp_containerize/errors.py tests/test_config.py && git commit -m "feat(config): caricamento del progetto e precedenze"
git switch main && git merge --no-ff feat/config && git push
```

### Task 6: Archivio dei manifest

**Branch:** `feat/manifest`

**Files:**
- Create: `src/wp_containerize/manifest.py`, `tests/test_manifest.py`

**Interfaces:**
- Consumes: `SiteManifest`, `normalize_domain` (Task 3); `ConfigError`, `WpcError`, `load_yaml` (Task 5).
- Produces:
  - `class ManifestLockedError(WpcError)`, `class ManifestExistsError(WpcError)`
  - `class ManifestStore(sites_dir: Path)`:
    - `path_for(domain) -> Path`, `list_domains() -> list[str]`
    - `load(domain) -> SiteManifest`, `create(manifest) -> Path`
    - `edit(domain) -> AbstractContextManager[SiteManifest]`

- [ ] **Step 1: test che falliscono**

```python
def test_edit_preserves_comments(store: ManifestStore) -> None:
    path = store.create(make_manifest("esempio.it"))
    path.write_text(path.read_text().replace("site: esempio.it", "site: esempio.it  # nota"))
    with store.edit("esempio.it") as m:
        m.status[Phase.DISCOVER].state = PhaseState.DONE
    assert "# nota" in path.read_text()
    assert store.load("esempio.it").status[Phase.DISCOVER].state is PhaseState.DONE

def test_edit_exception_leaves_file_untouched(store: ManifestStore) -> None:
    path = store.create(make_manifest("esempio.it")); before = path.read_bytes()
    with pytest.raises(RuntimeError), store.edit("esempio.it") as m:
        m.client = "x"; raise RuntimeError
    assert path.read_bytes() == before

def test_concurrent_edit_is_refused(store: ManifestStore) -> None:
    store.create(make_manifest("esempio.it"))
    with store.edit("esempio.it"), pytest.raises(ManifestLockedError), store.edit("esempio.it"):
        pass

def test_invalid_manifest_reports_file(store: ManifestStore) -> None:
    store.path_for("esempio.it").write_text("site: esempio.it\ntypo: 1\n")
    with pytest.raises(ConfigError) as exc:
        store.load("esempio.it")
    assert "esempio.it.yml" in str(exc.value)

def test_create_twice_fails(store: ManifestStore) -> None: ...
def test_path_for_rejects_traversal(store: ManifestStore) -> None:
    with pytest.raises(ValueError):
        store.path_for("../etc.com")
```

- [ ] **Step 2:** `uv run pytest tests/test_manifest.py -v`. Atteso: FAIL.
- [ ] **Step 3: implementare `manifest.py`**
  - Lock: file sidecar `.<dominio>.yml.lock` con `fcntl.flock(LOCK_EX | LOCK_NB)`.
  - Il round-trip usa `YAML()` (tipo `rt`).
  - Il salvataggio fa `model_dump(mode="json")`, che viene fuso nel documento ruamel con `_merge(doc, data)`:
    - le chiavi esistenti si aggiornano ricorsivamente (dict dentro dict)
    - le chiavi nuove si aggiungono, tranne quelle con valore `None` assenti nel documento
    - le chiavi non più presenti nel modello si rimuovono
  - Scrittura atomica come in Task 4.
  - Gli errori di validazione pydantic diventano `ConfigError(path, line=None)` con l'elenco dei campi.
- [ ] **Step 4:** `uv run pytest -v`. Atteso: PASS.
- [ ] **Step 5: commit e merge**

```bash
git switch -c feat/manifest
git add src/wp_containerize/manifest.py tests/test_manifest.py && git commit -m "feat(manifest): archivio con lock e commenti preservati"
git switch main && git merge --no-ff feat/manifest && git push
```

### Task 7: Stato delle fasi

**Branch:** `feat/state`

**Files:**
- Create: `src/wp_containerize/state.py`, `tests/test_state.py`

**Interfaces:**
- Consumes: `Phase`, `PhaseState`, `PHASES_BY_TYPE`, `SiteManifest` (Task 3); `ManifestStore` (Task 6); `WpcError` (Task 5).
- Produces:
  - `class PhaseBlockedError(WpcError)`, `class PhaseAlreadyDoneError(WpcError)`
  - `phases_for(manifest: SiteManifest) -> tuple[Phase, ...]`
  - `check_can_run(manifest: SiteManifest, phase: Phase, *, force: bool) -> None`
  - `class PhaseRun`:
    - `add_artifact(name: str, path: Path) -> None`, `notes: str | None`
    - `require_review(reason: str) -> None`
  - `run_phase(store, domain, phase, *, force=False, now: Callable[[], datetime] = utc_now) -> AbstractContextManager[PhaseRun]`
  - `mark_skipped(store, domain, phase, reason: str) -> None`
  - `record_review(store, domain, phase, by: str) -> None`
  - `sha256_of(path: Path) -> str`, che restituisce `"sha256:<hex>"`. Per una cartella si calcola l'hash delle righe `"<relpath>\0<sha file>\n"` ordinate.

- [ ] **Step 1: test che falliscono**
  - `test_first_phase_runs_and_records_done`: `started_at`, `finished_at` e artefatto con prefisso `sha256:`
  - `test_previous_not_done_blocks`
  - `test_skipped_previous_allows_next`: `ai-review` è `skipped` → `clean` può partire
  - `test_done_phase_without_force_raises` e `test_force_reruns`
  - `test_exception_marks_failed_with_error`: il messaggio dell'eccezione finisce in `error`, troncato a 500 caratteri
  - `test_keyboard_interrupt_marks_failed`: si solleva `KeyboardInterrupt` dentro `run_phase` → stato `failed`, l'eccezione si propaga
  - `test_running_phase_blocks_without_force`
  - `test_require_review_sets_review_then_record_review_sets_done`
  - `test_scan_in_review_blocks_next_phase`
  - `test_static_site_rejects_clean`: `PhaseBlockedError` per una fase non prevista dal tipo
  - `test_sha256_of_dir_is_stable_and_order_independent`
- [ ] **Step 2:** `uv run pytest tests/test_state.py -v`. Atteso: FAIL.
- [ ] **Step 3: implementare `state.py`**
  - **Regole di `check_can_run`:**
    - la fase deve stare in `phases_for(manifest)`
    - la precedente deve essere `done` o `skipped`
    - se la fase è `running` serve `force`
    - se la fase è `done` e manca `force` → `PhaseAlreadyDoneError`
  - **`run_phase`:** salva `running` (lock tenuto solo durante il salvataggio). All'uscita salva `done`, oppure `review` se è stato chiamato `require_review` e `reviewed_by` è vuoto. Con qualunque `BaseException` salva `failed` e rilancia.
- [ ] **Step 4:** `uv run pytest -v`. Atteso: PASS.
- [ ] **Step 5: commit e merge**

```bash
git switch -c feat/state
git add src/wp_containerize/state.py tests/test_state.py && git commit -m "feat(state): macchina a stati delle fasi con revisione manuale"
git switch main && git merge --no-ff feat/state && git push
```

### Task 8: Log con mascheramento dei segreti

**Branch:** `feat/logging`

**Files:**
- Create: `src/wp_containerize/log.py`, `tests/test_log.py`

**Interfaces:**
- Consumes: `SecretStore.redaction_values()` (Task 4).
- Produces:
  - `class Redactor(secrets: Iterable[str])`, invocabile come `(text: str) -> str`: sostituisce ogni segreto con `***`, partendo dal più lungo
  - `configure_logging(*, verbose: bool, redactor: Redactor) -> None`
  - `site_logger(work_dir: Path, domain: str, redactor: Redactor) -> logging.Logger`: scrive JSON Lines in `work/<dominio>/logs/<AAAAMMGG>.jsonl` con file `0600` e campi `ts`, `level`, `site`, `phase`, `msg`, `exc`

- [ ] **Step 1: test che falliscono**
  - `test_secret_in_message_args_and_exception_is_masked`: il segreto, passato come argomento `%s` e dentro il testo di un'eccezione loggata con `exception()`, non compare nel file; compare invece `***`
  - `test_each_line_is_json_with_fields`
  - `test_log_file_mode_is_600`
  - `test_console_output_is_masked`: si usa `caplog` con l'handler console configurato
- [ ] **Step 2:** `uv run pytest tests/test_log.py -v`. Atteso: FAIL.
- [ ] **Step 3: implementare `log.py`**
  - Un `logging.Filter` sostituisce `record.msg` con il messaggio formattato e mascherato e azzera `record.args`.
  - Il formatter JSON maschera anche il testo dell'eccezione.
  - Per la console si usa `rich.logging.RichHandler` con lo stesso filtro.
- [ ] **Step 4:** `uv run pytest -v`. Atteso: PASS.
- [ ] **Step 5: commit e merge**

```bash
git switch -c feat/logging
git add src/wp_containerize/log.py tests/test_log.py && git commit -m "feat(log): log JSON per sito con segreti mascherati"
git switch main && git merge --no-ff feat/logging && git push
```

### Task 9: Traduzioni

**Branch:** `feat/i18n`

**Files:**
- Create:
  - `src/wp_containerize/i18n.py`
  - `src/wp_containerize/locale/en/LC_MESSAGES/wp_containerize.po`
  - `babel.cfg`
  - `hatch_build.py`
  - `tests/test_i18n.py`
- Modify: `pyproject.toml` (build hook custom e `babel` in `build-system.requires`), `CONTRIBUTING.md` (comandi `pybabel extract`/`update`)

**Interfaces:**
- Produces:
  - `setup_language(lang: str | None) -> str`, che restituisce `"it"` o `"en"`. Ordine di priorità: argomento, poi `WP_CONTAINERIZE_LANG`, poi `LANG`. `en*` → `en`, tutto il resto → `it`.
  - `_(message: str) -> str`
  - `ngettext(singular: str, plural: str, n: int) -> str`

- [ ] **Step 1: test che falliscono**

```python
def test_english_translation() -> None:
    setup_language("en")
    assert _("Sito non trovato: {domain}") == "Site not found: {domain}"

def test_italian_is_source_and_fallback() -> None:
    setup_language("it")
    assert _("Sito non trovato: {domain}") == "Sito non trovato: {domain}"
    setup_language("en")
    assert _("stringa senza traduzione") == "stringa senza traduzione"

def test_env_lang_is_used(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("LANG", "en_US.UTF-8"); monkeypatch.delenv("WP_CONTAINERIZE_LANG", raising=False)
    assert setup_language(None) == "en"
```

- [ ] **Step 2:** `uv run pytest tests/test_i18n.py -v`. Atteso: FAIL.
- [ ] **Step 3: implementare**
  - `i18n.py` usa `gettext.translation("wp_containerize", localedir=<package>/locale, languages=[lang], fallback=True)`.
  - `hatch_build.py` (`BuildHookInterface`) compila ogni `.po` in `.mo` con `babel.messages.mofile` durante build e install editable. I `.mo` restano fuori da git (`.gitignore`).
  - Nel `.po`, la voce `"Sito non trovato: {domain}"` ha come traduzione `"Site not found: {domain}"`.
- [ ] **Step 4:** `uv sync --reinstall-package wp-containerize && uv run pytest -v`. Atteso: PASS.
- [ ] **Step 5: commit e merge**

```bash
git switch -c feat/i18n
git add src/wp_containerize/i18n.py tests/test_i18n.py babel.cfg src/wp_containerize/locale && git commit -m "feat(i18n): messaggi in italiano con traduzione inglese"
git add hatch_build.py pyproject.toml .gitignore && git commit -m "chore(build): compila i cataloghi gettext in build"
git add CONTRIBUTING.md && git commit -m "docs: come aggiornare le traduzioni"
git switch main && git merge --no-ff feat/i18n && git push
```

### Task 10: CLI di base (`init`, `site add`, `site import-csv`, `status`)

**Branch:** `feat/cli-base`

**Files:**
- Modify: `src/wp_containerize/cli.py`
- Create:
  - `src/wp_containerize/commands/__init__.py`, `src/wp_containerize/commands/site.py`, `src/wp_containerize/commands/project.py`
  - `src/wp_containerize/sites.py` (servizi senza I/O della CLI)
  - `src/wp_containerize/resources/project/wp-containerize.yml`, `src/wp_containerize/resources/project/env.example`, `src/wp_containerize/resources/project/gitignore`
  - `tests/test_sites.py`, `tests/test_cli.py`
- Modify: `src/wp_containerize/locale/en/LC_MESSAGES/wp_containerize.po` (nuove stringhe)

**Interfaces:**
- Consumes: tutte le Interfaces dei Task 3–9.
- Produces:
  - `allocate_uid(used: Iterable[int], uid_range: tuple[int, int]) -> int`, che restituisce il primo libero. Se il range è esaurito solleva `WpcError`.
  - `new_manifest(domain: str, *, site_type: SiteType, slug: str | None, client: str | None, source_host: str | None, uid: int) -> SiteManifest`: tutte le fasi del tipo sono `pending`.
  - `@dataclass class CsvRow`: `domain`, `site_type`, `client`, `source_host`, `php`, `note`
  - `read_csv(path: Path, *, mapping: Mapping[str, str], categories: frozenset[str]) -> tuple[list[CsvRow], list[str]]`, che restituisce righe valide ed errori per numero di riga
  - `add_site(project: Project, row: CsvRow) -> SiteManifest`: controlla le collisioni di dominio e di slug sui manifest esistenti
  - **Comandi:**
    - `wp-containerize init [PATH] --namespace TEXT`
    - `wp-containerize site add DOMAIN [--type] [--slug] [--client] [--source-host]`
    - `wp-containerize site import-csv FILE [--categoria wordpress,statico] [--map campo=colonna]... [--dry-run]`
    - `wp-containerize status [DOMAIN]`
  - **Opzioni globali:** `--lang`, `--verbose`, `--yes`.
  - **Codici di uscita:** `0` ok, `1` errore (`WpcError`, mostrato senza traceback), `2` uso scorretto.

- [ ] **Step 1: test che falliscono** (con `CliRunner`, in `tmp_path`)
  - `test_init_creates_project_and_env_600`, `test_init_twice_never_overwrites_env`
  - `test_site_add_creates_manifest_with_pending_phases_and_uid_20000`
  - `test_site_add_rejects_slug_collision`: `a-b.example.com` e `a.b.example.com` → il secondo fallisce e suggerisce `--slug`
  - `test_import_csv_semicolon_bom_and_extra_columns`: CSV `utf-8-sig` con `;`, colonne `dominio;categoria;host_cpanel;altro`, `--map source_host=host_cpanel`, `--categoria wordpress` → importati solo i `wordpress`, `source.host` valorizzato
  - `test_import_csv_reports_invalid_domain_row_and_exit_1`: riga 3 `http://x` → l'errore cita "riga 3" e le righe valide vengono comunque importate
  - `test_import_csv_dry_run_writes_nothing`
  - `test_import_csv_skips_existing_domains`
  - `test_status_lists_sites_and_phase_states`
  - `test_error_without_traceback_outside_project`: `status` fuori da un progetto → exit 1, messaggio senza `Traceback`
  - `test_allocate_uid_skips_used_and_raises_when_full` (in `test_sites.py`)
- [ ] **Step 2:** `uv run pytest tests/test_sites.py tests/test_cli.py -v`. Atteso: FAIL.
- [ ] **Step 3: implementare**
  - `sites.py` contiene la logica, `commands/` è il guscio typer e `cli.py` registra i gruppi e il callback globale.
  - Il callback chiama `setup_language` e `configure_logging`. Il punto d'ingresso intercetta `WpcError` e stampa il messaggio tradotto.
  - **Lettura CSV:** `open(encoding="utf-8-sig", newline="")`, poi `csv.Sniffer().sniff(sample, delimiters=",;")`.
  - **`init`:** copia le risorse senza sovrascrivere nulla. `.env` si crea con `create_env_file` da `env.example`. Si creano `sites/` e `work/`, e `.gitignore` con `.env` e `work/`.
  - Il template `wp-containerize.yml` contiene i valori di default di `ProjectConfig`, commenti in italiano e `namespace` preso da `--namespace`.
  - Tutte le stringhe utente vanno in `_()` e nel `.po` `en`.
- [ ] **Step 4:** `uv run pytest -v && uv run pre-commit run --all-files`. Atteso: tutto verde.
- [ ] **Step 5: prova manuale** in una cartella temporanea:
  1. `uv run wp-containerize init /tmp/prova --namespace esempio`
  2. `cd /tmp/prova`
  3. creare un CSV con 3 domini `example.com`
  4. `site import-csv`, poi `status`, poi `LANG=en_US.UTF-8 … status`

  Atteso: una tabella con 3 siti e 11 fasi `pending`; con `LANG=en` le intestazioni sono in inglese.
- [ ] **Step 6: commit e merge**

```bash
git switch -c feat/cli-base
git add src/wp_containerize/sites.py tests/test_sites.py && git commit -m "feat(sites): creazione dei manifest, UID e import da CSV"
git add src/wp_containerize/resources && git commit -m "feat(init): modelli di progetto, .env e gitignore"
git add src/wp_containerize/cli.py src/wp_containerize/commands tests/test_cli.py src/wp_containerize/locale && git commit -m "feat(cli): comandi init, site e status"
git switch main && git merge --no-ff feat/cli-base && git push
```

## Chiusura di M1

- [ ] `uv run pytest --cov=wp_containerize` (atteso: tutti i test verdi) e `uv run pip-audit` (atteso: nessuna vulnerabilità).
- [ ] Prova reale **fuori dal repo**: nel progetto privato dell'operatore, `site import-csv` sul CSV dell'inventario con `--categoria wordpress`. Si verificano il numero di manifest creati e `status`. Nessun file di quel progetto entra nel repo.
