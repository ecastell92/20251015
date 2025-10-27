"""Modelos de dominio utilizados por la aplicación."""
from __future__ import annotations

from datetime import datetime
from typing import Literal, Optional

from pydantic import BaseModel, Field


class BackupObject(BaseModel):
    """Representa un objeto dentro del bucket de copias de seguridad."""

    key: str = Field(..., description="Ruta del objeto en S3")
    size: int = Field(..., description="Tamaño en bytes")
    last_modified: datetime = Field(..., description="Fecha de última modificación")

    @property
    def human_readable_size(self) -> str:
        """Convierte el tamaño a una cadena amigable."""

        size = float(self.size)
        for unit in ("bytes", "KB", "MB", "GB", "TB"):
            if size < 1024 or unit == "TB":
                return f"{size:,.2f} {unit}"
            size /= 1024
        return f"{size:,.2f} TB"


class RestoreRequest(BaseModel):
    """Petición de restauración realizada por un usuario."""

    account_id: str
    object_key: str
    strategy: Literal["copy", "download"]
    destination_bucket: Optional[str] = None
    destination_prefix: str = ""


class RestoreResult(BaseModel):
    """Resultado de una restauración."""

    success: bool
    message: str
    object_key: str
    destination: str
    strategy: str
    timestamp: datetime = Field(default_factory=datetime.utcnow)


