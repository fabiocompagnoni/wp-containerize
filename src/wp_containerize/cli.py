"""Punto d'ingresso della riga di comando."""

import typer

from wp_containerize import __version__

app = typer.Typer(
    name="wp-containerize",
    help="Migra siti WordPress da hosting FTP a container Docker.",
    no_args_is_help=True,
)


def _print_version(value: bool) -> None:
    if value:
        typer.echo(f"wp-containerize {__version__}")
        raise typer.Exit


@app.callback()
def main(
    version: bool = typer.Option(
        False,
        "--version",
        callback=_print_version,
        is_eager=True,
        help="Mostra la versione ed esce.",
    ),
) -> None:
    """Migra siti WordPress da hosting FTP a container Docker."""
