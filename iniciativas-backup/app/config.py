"""Configuration models and helpers for the backup admin app."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Iterable, List, Optional

import yaml


@dataclass
class AccountConfig:
    """Represents the backup settings for one AWS account."""

    key: str
    name: str
    account_id: str
    region: str
    role_arn: str
    backup_state_machine_arn: Optional[str] = None
    restore_state_machine_arn: Optional[str] = None
    default_generation: str = "son"

    def summary(self) -> str:
        return (
            f"{self.name} ({self.account_id}) – region={self.region} "
            f"default_generation={self.default_generation}"
        )


class AppConfig:
    """Holds configuration for all managed accounts."""

    def __init__(self, accounts: Iterable[AccountConfig]):
        self._accounts: Dict[str, AccountConfig] = {acc.key: acc for acc in accounts}

    @property
    def accounts(self) -> List[AccountConfig]:
        return list(self._accounts.values())

    def get(self, key: str) -> AccountConfig:
        try:
            return self._accounts[key]
        except KeyError as exc:
            raise KeyError(f"No account configured with key '{key}'") from exc


def load_config(path: Path) -> AppConfig:
    """Loads the YAML configuration file."""

    if not path.exists():
        raise FileNotFoundError(f"Configuration file not found: {path}")

    raw = yaml.safe_load(path.read_text()) or {}
    accounts_raw = raw.get("accounts")
    if not isinstance(accounts_raw, list):
        raise ValueError("Configuration must contain a list under 'accounts'")

    accounts = []
    for entry in accounts_raw:
        if not isinstance(entry, dict):
            raise ValueError("Each account entry must be a mapping")
        try:
            account = AccountConfig(
                key=entry["key"],
                name=entry["name"],
                account_id=str(entry["account_id"]),
                region=entry["region"],
                role_arn=entry["role_arn"],
                backup_state_machine_arn=entry.get("backup_state_machine_arn"),
                restore_state_machine_arn=entry.get("restore_state_machine_arn"),
                default_generation=entry.get("default_generation", "son"),
            )
        except KeyError as exc:
            raise ValueError(f"Missing required key in account entry: {exc}") from exc
        accounts.append(account)

    if not accounts:
        raise ValueError("No accounts defined in configuration")

    return AppConfig(accounts)
