"""Servicios para interactuar con S3 y ejecutar restauraciones."""
from __future__ import annotations

from dataclasses import dataclass
from typing import Iterable, List, Optional

import boto3
from botocore.client import BaseClient
from botocore.exceptions import ClientError

from .config import AccountConfig, AppConfig
from .models import BackupObject, RestoreRequest, RestoreResult


@dataclass
class STSSessionFactory:
    """Crea sesiones boto3 asumiendo roles en cuentas externas."""

    def build_client(self, service_name: str, account: AccountConfig) -> BaseClient:
        sts_client = boto3.client("sts")
        credentials = sts_client.assume_role(
            RoleArn=account.role_arn,
            RoleSessionName="SimpleBackupRestore",
        )["Credentials"]

        session = boto3.session.Session(
            aws_access_key_id=credentials["AccessKeyId"],
            aws_secret_access_key=credentials["SecretAccessKey"],
            aws_session_token=credentials["SessionToken"],
            region_name=account.region,
        )
        return session.client(service_name, region_name=account.region)


class S3RestoreService:
    """Encapsula la lógica de consulta y restauración de copias en S3."""

    def __init__(self, config: AppConfig, session_factory: Optional[STSSessionFactory] = None) -> None:
        self.config = config
        self.session_factory = session_factory or STSSessionFactory()
        self._audit_log: List[RestoreResult] = []

    # ----------------------------
    # Gestión de cuentas y objetos
    # ----------------------------
    def list_accounts(self) -> List[AccountConfig]:
        return self.config.accounts

    def get_account(self, account_id: str) -> AccountConfig:
        for account in self.config.accounts:
            if account.id == account_id:
                return account
        raise KeyError(f"Cuenta no encontrada: {account_id}")

    def list_backup_objects(self, account_id: str, prefix: str = "") -> Iterable[BackupObject]:
        account = self.get_account(account_id)
        client = self.session_factory.build_client("s3", account)

        combined_prefix = f"{account.backup_prefix}{prefix}" if prefix else account.backup_prefix
        paginator = client.get_paginator("list_objects_v2")
        for page in paginator.paginate(Bucket=account.backup_bucket, Prefix=combined_prefix):
            for item in page.get("Contents", []):
                yield BackupObject(
                    key=item["Key"],
                    size=item["Size"],
                    last_modified=item["LastModified"],
                )

    # ----------------------------
    # Restauraciones
    # ----------------------------
    def restore(self, request: RestoreRequest) -> RestoreResult:
        account = self.get_account(request.account_id)
        if request.strategy == "copy":
            return self._copy_object(account, request)
        if request.strategy == "download":
            return self._generate_presigned_url(account, request)
        raise ValueError(f"Estrategia de restauración no soportada: {request.strategy}")

    def get_audit_log(self) -> List[RestoreResult]:
        return list(self._audit_log)

    # ----------------------------
    # Estrategias internas
    # ----------------------------
    def _copy_object(self, account: AccountConfig, request: RestoreRequest) -> RestoreResult:
        destination_bucket = request.destination_bucket or account.restore_bucket
        if not destination_bucket:
            raise ValueError("No se ha definido bucket de restauración para la estrategia copy")

        destination_prefix = request.destination_prefix or account.restore_prefix
        key_name = request.object_key.split("/")[-1]
        destination_key = f"{destination_prefix}{key_name}" if destination_prefix else key_name

        client = self.session_factory.build_client("s3", account)
        source = {"Bucket": account.backup_bucket, "Key": request.object_key}
        try:
            client.copy(
                CopySource=source,
                Bucket=destination_bucket,
                Key=destination_key,
            )
        except ClientError as exc:  # pragma: no cover - depende de AWS
            raise RuntimeError(f"Error al copiar objeto: {exc}") from exc

        result = RestoreResult(
            success=True,
            message="Objeto copiado correctamente",
            object_key=request.object_key,
            destination=f"s3://{destination_bucket}/{destination_key}",
            strategy="copy",
        )
        self._audit_log.append(result)
        return result

    def _generate_presigned_url(self, account: AccountConfig, request: RestoreRequest) -> RestoreResult:
        client = self.session_factory.build_client("s3", account)
        try:
            url = client.generate_presigned_url(
                "get_object",
                Params={"Bucket": account.backup_bucket, "Key": request.object_key},
                ExpiresIn=3600,
            )
        except ClientError as exc:  # pragma: no cover - depende de AWS
            raise RuntimeError(f"No se pudo generar URL presignada: {exc}") from exc

        result = RestoreResult(
            success=True,
            message="URL generada por 60 minutos",
            object_key=request.object_key,
            destination=url,
            strategy="download",
        )
        self._audit_log.append(result)
        return result


