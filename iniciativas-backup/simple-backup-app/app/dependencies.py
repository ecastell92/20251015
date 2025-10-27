"""Dependencias reutilizables para FastAPI."""
from __future__ import annotations

from functools import lru_cache
from pathlib import Path
from typing import List

from fastapi import Request

from .config import AppConfig, load_config
from .s3_service import S3RestoreService


CONFIG_DIR = Path(__file__).resolve().parent.parent / "config"
PRIMARY_CONFIG = CONFIG_DIR / "accounts.yaml"
FALLBACK_CONFIG = CONFIG_DIR / "accounts.example.yaml"


@lru_cache(maxsize=1)
def get_app_config() -> AppConfig:
    """Devuelve la configuración de la aplicación."""

    path = PRIMARY_CONFIG if PRIMARY_CONFIG.exists() else FALLBACK_CONFIG
    return load_config(path)


@lru_cache(maxsize=1)
def get_restore_service() -> S3RestoreService:
    """Crea un `S3RestoreService` reutilizable."""

    return S3RestoreService(get_app_config())


def get_messages(request: Request) -> List[str]:
    """Obtiene y limpia los mensajes flash almacenados en la sesión."""

    messages = request.session.setdefault("messages", [])
    snapshot = list(messages)
    request.session["messages"] = []
    return snapshot


