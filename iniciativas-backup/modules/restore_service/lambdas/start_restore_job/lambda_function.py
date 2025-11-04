import os
from typing import Any, Dict

import boto3

s3_client = boto3.client("s3")
s3control_client = boto3.client("s3control")
sts_client = boto3.client("sts")

BATCH_ROLE_NAME = os.environ.get("BATCH_ROLE_NAME", "service-role/AWSBatchOperationsRole")
DEFAULT_REPORT_SUFFIX = os.environ.get("DEFAULT_REPORT_SUFFIX", "batch-reports/")


def lambda_handler(event: Dict[str, Any], _context) -> Dict[str, Any]:
    manifest = event.get("manifest") or {}
    manifest_bucket = manifest.get("bucket")
    manifest_key = manifest.get("key")
    if not manifest_bucket or not manifest_key:
        raise ValueError("Se requiere la ubicación del manifest (bucket y key)")

    target_bucket = event.get("targetBucket")
    if not target_bucket:
        raise ValueError("targetBucket es obligatorio")
    target_prefix = event.get("targetPrefix", "")
    storage_class = (event.get("storageClass") or "").strip() or None

    report_suffix = event.get("reportSuffix") or DEFAULT_REPORT_SUFFIX
    report_suffix = report_suffix if report_suffix.endswith("/") else f"{report_suffix}/"
    report_prefix = f"{target_prefix}{report_suffix}"

    head = s3_client.head_object(Bucket=manifest_bucket, Key=manifest_key)
    etag = head["ETag"].strip('"')

    manifest_arn = f"arn:aws:s3:::{manifest_bucket}/{manifest_key}"
    target_bucket_arn = f"arn:aws:s3:::{target_bucket}"

    account_id = sts_client.get_caller_identity()["Account"]
    role_arn = f"arn:aws:iam::{account_id}:role/{BATCH_ROLE_NAME}"

    operation = {
        "S3PutObjectCopy": {
            "TargetResource": target_bucket_arn,
            "TargetKeyPrefix": target_prefix or "",
        }
    }
    if storage_class:
        operation["S3PutObjectCopy"]["StorageClass"] = storage_class

    response = s3control_client.create_job(
        AccountId=account_id,
        ConfirmationRequired=False,
        RoleArn=role_arn,
        Priority=10,
        Operation=operation,
        Manifest={
            "Spec": {"Format": "S3BatchOperations_CSV_20180820", "Fields": ["Bucket", "Key"]},
            "Location": {"ObjectArn": manifest_arn, "ETag": etag},
        },
        Report={
            "Enabled": True,
            "Bucket": target_bucket_arn,
            "Prefix": report_prefix,
            "Format": "Report_CSV_20180820",
            "ReportScope": "AllTasks",
        },
        ClientRequestToken=event.get("clientRequestToken") or event.get("requestId") or manifest_key,
        Description=f"Restore to {target_bucket}/{target_prefix}",
    )

    job_id = response["JobId"]
    return {
        "jobId": job_id,
        "status": "RUNNING",
        "targetBucket": target_bucket,
        "targetPrefix": target_prefix,
        "reportPrefix": report_prefix,
        "manifest": {"bucket": manifest_bucket, "key": manifest_key},
    }
