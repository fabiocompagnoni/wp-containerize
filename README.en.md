# wp-containerize

[Versione italiana](README.md)

Command-line tool that migrates WordPress sites from shared hosting, reachable over
FTP/SFTP, to isolated and up-to-date Docker stacks. Each site is extracted read-only,
scanned for malicious code, cleaned, upgraded and finally packaged into a portable
bundle that can run on a VPS or locally.

It is also meant for potentially compromised sites: no site reaches production without
analysis and cleanup.

> **Status: under development, not production ready.** Interfaces may change without
> notice.

## Requirements

- Linux, macOS or Windows via WSL
- Python 3.12 or later
- Docker
- ssh and git

Everything else (database, wp-cli, scanners) runs in containers.

## Development setup

Requires [uv](https://docs.astral.sh/uv/).

```bash
uv sync
uv run wp-containerize --version
uv run pytest
```

## Documentation

- [Specification](docs/SPEC.md) (Italian)
- [Contributing](CONTRIBUTING.md)
- [Security policy](SECURITY.md)

## License

Apache-2.0, see [LICENSE](LICENSE).
