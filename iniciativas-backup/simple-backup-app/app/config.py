"""Carga y validación de configuración para cuentas AWS y estrategia de restauración."""
from __future__ import annotations

from pathlib import Path
from typing import List, Literal, Optional

import yaml
from pydantic import BaseModel, Field, ValidationError, field_validator


class AccountConfig(BaseModel):
    """Representa la configuración de una cuenta AWS gestionada por la app."""

    id: str = Field(..., description="ID numérico de la cuenta AWS")
    name: str = Field(..., description="Nombre amigable de la cuenta")
    role_arn: str = Field(..., description="ARN del rol a asumir en la cuenta")
    region: str = Field(..., description="Región por defecto para las operaciones S3")
    backup_bucket: str = Field(..., description="Bucket S3 origen de las copias de seguridad")
    backup_prefix: str = Field("", description="Prefijo dentro del bucket de backup")
    restore_bucket: Optional[str] = Field(
        default=None,
        description="Bucket S3 destino estándar para restauraciones automáticas",
    )
    restore_prefix: str = Field(
        "",
        description="Prefijo dentro del bucket de restauración",
    )

    @field_validator("backup_prefix", "restore_prefix")
    @classmethod
    def normalize_prefix(cls, value: str) -> str:
        if not value:
            return ""
        return value if value.endswith("/") else value + "/"


class AppConfig(BaseModel):
    """Configuración completa de la aplicación."""

    default_restore_strategy: Literal["copy", "download"] = "copy"
    accounts: List[AccountConfig] = Field(..., max_length=10)

    @field_validator("accounts")
    @classmethod
    def ensure_unique_account_ids(cls, accounts: List[AccountConfig]) -> List[AccountConfig]:
        seen = set()
        for account in accounts:
            if account.id in seen:
                msg = f"Cuenta duplicada: {account.id}"
                raise ValueError(msg)
            seen.add(account.id)
        return accounts


def load_config(path: Path) -> AppConfig:
    """Carga un archivo YAML y devuelve la configuración validada."""

    if not path.exists():
        raise FileNotFoundError(
            f"Archivo de configuración no encontrado: {path}. Crea uno a partir de accounts.example.yaml"
        )

    with path.open("r", encoding="utf-8") as config_file:
        raw_config = yaml.safe_load(config_file) or {}

    try:
        return AppConfig.model_validate(raw_config)
    except ValidationError as exc:
        raise ValueError(f"Error de validación en configuración: {exc}") from exc


