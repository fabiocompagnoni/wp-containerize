from typer.testing import CliRunner

from wp_containerize import __version__
from wp_containerize.cli import app


def test_version_option_prints_version() -> None:
    result = CliRunner().invoke(app, ["--version"])
    assert result.exit_code == 0
    assert __version__ in result.stdout
