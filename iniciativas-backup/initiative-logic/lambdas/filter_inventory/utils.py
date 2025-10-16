"""
Utility functions for the filter_inventory Lambda.

These helpers implement a simple checkpoint mechanism using objects in the
central backup bucket.  Each checkpoint records the timestamp of the last
successful backup for a given source bucket and backup type.  The path of
the checkpoint file is ``checkpoints/<source_bucket>/<backup_type>.txt``.

When reading a checkpoint, if the file does not exist, ``None`` is
returned.  When writing a checkpoint, the timestamp is stored in ISO8601
format.
"""

import boto3
import logging
from datetime import datetime
from typing import Optional


s3 = boto3.client("s3")
logger = logging.getLogger(__name__)


def read_checkpoint(bucket_name: str, source_bucket: str, backup_type: str) -> Optional[datetime]:
    """Return the timestamp of the last checkpoint or ``None`` if none exists."""
    key = f"checkpoints/{source_bucket}/{backup_type}.txt"
    try:
        resp = s3.get_object(Bucket=bucket_name, Key=key)
        timestamp_str = resp["Body"].read().decode("utf-8")
        logger.debug("Read checkpoint %s => %s", key, timestamp_str)
        return datetime.fromisoformat(timestamp_str)
    except s3.exceptions.NoSuchKey:
        logger.debug("No checkpoint found at %s", key)
        return None
    except Exception as e:
        logger.error("Failed to read checkpoint from %s: %s", key, e)
        raise


def write_checkpoint(bucket_name: str, source_bucket: str, backup_type: str, timestamp: datetime) -> None:
    """Write the given timestamp as the checkpoint for the specified bucket and type."""
    key = f"checkpoints/{source_bucket}/{backup_type}.txt"
    try:
        s3.put_object(
            Bucket=bucket_name,
            Key=key,
            Body=timestamp.isoformat(),
        )
        logger.debug("Wrote checkpoint %s => %s", key, timestamp.isoformat())
    except Exception as e:
        logger.error("Failed to write checkpoint to %s: %s", key, e)
        raise