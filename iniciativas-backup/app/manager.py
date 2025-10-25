"""High level orchestration helpers for the backup admin app."""

from __future__ import annotations

import json
from datetime import datetime, timezone
from typing import Dict, Optional

from . import config as cfg
from .aws_utils import assume_role, make_client, resolve_session_name


class BackupManager:
    """Coordinates backup operations across multiple AWS accounts."""

    def __init__(self, app_config: cfg.AppConfig):
        self._config = app_config

    @property
    def accounts(self):
        return self._config.accounts

    def describe_accounts(self) -> Dict[str, Dict[str, str]]:
        return {acc.key: {
            "name": acc.name,
            "account_id": acc.account_id,
            "region": acc.region,
            "default_generation": acc.default_generation,
            "backup_state_machine_arn": acc.backup_state_machine_arn,
        } for acc in self._config.accounts}

    def _prepare_step_functions_client(self, account: cfg.AccountConfig):
        credentials = assume_role(
            role_arn=account.role_arn,
            session_name=resolve_session_name(account.key),
        )
        return make_client("stepfunctions", account.region, credentials)

    def trigger_backup(
        self,
        account_key: str,
        criticality: str,
        backup_type: str = "incremental",
        generation: Optional[str] = None,
        payload: Optional[Dict] = None,
    ) -> str:
        account = self._config.get(account_key)
        if not account.backup_state_machine_arn:
            raise ValueError(f"Account '{account_key}' does not define a backup state machine ARN")

        client = self._prepare_step_functions_client(account)
        execution_input = {
            "BackupType": backup_type,
            "Criticality": criticality,
            "Generation": generation or account.default_generation,
        }
        if payload:
            execution_input.update(payload)

        response = client.start_execution(
            stateMachineArn=account.backup_state_machine_arn,
            name=self._execution_name(account_key, "backup"),
            input=json.dumps(execution_input),
        )
        return response["executionArn"]


    @staticmethod
    def _execution_name(account_key: str, suffix: str) -> str:
        timestamp = datetime.now(timezone.utc).strftime("%Y%m%d%H%M%S")
        return f"{account_key}-{suffix}-{timestamp}"[:80]
