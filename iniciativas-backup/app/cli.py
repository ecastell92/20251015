"""Command line interface for the backup admin app."""


from __future__ import annotations


from pathlib import Path
from typing import Optional


import typer


from .config import load_config
from .manager import BackupManager


app = typer.Typer(help="Administra backups multi-cuenta usando Step Functions.")


def _load_manager(config_path: Path) -> BackupManager:
    config = load_config(config_path)
    return BackupManager(config)


@app.command()
def list_accounts(config: Path = typer.Option(..., exists=True, readable=True, help="Ruta al YAML de configuracion")):
    """Lista todas las cuentas gestionadas."""

    manager = _load_manager(config)
    for account in manager.accounts:
        typer.echo(f"- {account.key}: {account.summary()}")


@app.command()
def trigger_backup(
    account: str = typer.Argument(..., help="Clave de la cuenta (key)"),
    criticality: str = typer.Option("Critico", help="Criticidad a ejecutar"),
    backup_type: str = typer.Option("incremental", help="Tipo de backup"),
    generation: Optional[str] = typer.Option(None, help="Generacion GFS a usar"),
    config: Path = typer.Option(..., exists=True, readable=True, help="Ruta al YAML de configuracion"),
):
    """Lanza una ejecucion de Step Functions para un backup."""

    manager = _load_manager(config)
    execution_arn = manager.trigger_backup(
        account_key=account,
        criticality=criticality,
        backup_type=backup_type,
        generation=generation,
    )
    typer.echo(f"Ejecucion iniciada: {execution_arn}")


def run():
    app()


if __name__ == "__main__":  # pragma: no cover
    run()

