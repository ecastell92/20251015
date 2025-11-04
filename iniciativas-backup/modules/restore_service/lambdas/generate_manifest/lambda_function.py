import os
import uuid
import csv
import io
from typing import Any, Dict

import boto3

s3_client = boto3.client("s3")

DEFAULT_MANIFEST_BUCKET = os.environ["DEFAULT_MANIFEST_BUCKET"]
DEFAULT_MANIFEST_PREFIX = os.environ.get("DEFAULT_MANIFEST_PREFIX", "restore-manifests/")


def _normalized_prefix(value: str) -> str:
    value = value or ""
    return value if value.endswith("/") else f"{value}/"


def lambda_handler(event: Dict[str, Any], _context) -> Dict[str, Any]:
    source_bucket = event.get("sourceBucket")
    if not source_bucket:
        raise ValueError("sourceBucket es obligatorio para el modo prefix")

    source_prefix = event.get("sourcePrefix", "")
    manifest_bucket = event.get("manifestBucket") or DEFAULT_MANIFEST_BUCKET
    manifest_prefix = _normalized_prefix(event.get("manifestPrefix") or DEFAULT_MANIFEST_PREFIX)

    paginator = s3_client.get_paginator("list_objects_v2")
    buffer = io.StringIO()
    writer = csv.writer(buffer)

    total_objects = 0
    for page in paginator.paginate(Bucket=source_bucket, Prefix=source_prefix or ""):
        for obj in page.get("Contents", []):
            key = obj.get("Key")
            if not key or key.endswith("/"):
                continue
            writer.writerow([source_bucket, key])
            total_objects += 1

    if total_objects == 0:
        raise ValueError("No se encontraron objetos para el prefijo indicado")

    run_id = str(uuid.uuid4())
    manifest_key = f"{manifest_prefix.rstrip('/')}/manifest-{run_id}.csv"

    s3_client.put_object(
        Bucket=manifest_bucket,
        Key=manifest_key,
        Body=buffer.getvalue().encode("utf-8"),
        ContentType="text/csv",
        ServerSideEncryption="AES256",
    )

    return {
        "bucket": manifest_bucket,
        "key": manifest_key,
        "objectCount": total_objects,
        "sourceBucket": source_bucket,
        "sourcePrefix": source_prefix,
    }
