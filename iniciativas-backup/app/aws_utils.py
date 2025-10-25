"""AWS helper utilities for cross-account orchestration."""

from __future__ import annotations

import datetime as _dt
import os
from dataclasses import dataclass

import boto3
from botocore.config import Config


@dataclass
class TemporaryCredentials:
    access_key: str
    secret_key: str
    session_token: str
    expiration: _dt.datetime

    def as_dict(self) -> dict:
        return {
            "aws_access_key_id": self.access_key,
            "aws_secret_access_key": self.secret_key,
            "aws_session_token": self.session_token,
        }


def assume_role(role_arn: str, session_name: str, duration_seconds: int = 3600) -> TemporaryCredentials:
    """Assume an IAM role and return temporary credentials."""

    sts_client = boto3.client("sts")
    response = sts_client.assume_role(
        RoleArn=role_arn,
        RoleSessionName=session_name,
        DurationSeconds=duration_seconds,
    )
    creds = response["Credentials"]
    return TemporaryCredentials(
        access_key=creds["AccessKeyId"],
        secret_key=creds["SecretAccessKey"],
        session_token=creds["SessionToken"],
        expiration=creds["Expiration"],
    )


def make_client(service: str, region: str, credentials: TemporaryCredentials, retries: int = 3):
    """Create a boto3 client for the given service using temporary credentials."""

    config = Config(
        retries={"mode": "standard", "max_attempts": max(1, retries)},
        user_agent_extra="backup-admin-app/1.0",
    )

    return boto3.client(
        service,
        region_name=region,
        config=config,
        aws_access_key_id=credentials.access_key,
        aws_secret_access_key=credentials.secret_key,
        aws_session_token=credentials.session_token,
    )


def resolve_session_name(account_key: str) -> str:
    base = os.environ.get("BACKUP_APP_SESSION_PREFIX", "backup-admin")
    return f"{base}-{account_key}"[:64]
