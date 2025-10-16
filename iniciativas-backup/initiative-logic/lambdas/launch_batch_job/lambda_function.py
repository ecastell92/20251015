"""
Lambda function: launch_batch_job
"""

import boto3
import os
import logging
import json
import uuid
from datetime import datetime, timezone
from typing import Dict, Any

logger = logging.getLogger()
logger.setLevel(os.environ.get("LOG_LEVEL", "INFO").upper())

# Environment config
ACCOUNT_ID = os.environ["ACCOUNT_ID"]
BACKUP_BUCKET_ARN = os.environ["BACKUP_BUCKET_ARN"]
BATCH_ROLE_ARN = os.environ["BATCH_ROLE_ARN"]
S3_BACKUP_INICIATIVA = os.environ.get("S3_BACKUP_INICIATIVA", "backup")
MANIFESTS_BUCKET = os.environ["MANIFESTS_BUCKET"]

s3_control = boto3.client("s3control")
s3_client = boto3.client("s3")


def lambda_handler(event: Dict[str, Any], context: object) -> Dict[str, Any]:
    """Entrypoint for the launch_batch_job Lambda."""
    try:
        logger.info("Received event: %s", json.dumps(event))

        manifest = event["manifest"]
        source_bucket = event["source_bucket"]
        backup_type = event["backup_type"]
        generation = event.get("generation", "father" if backup_type == "full" else "son")
        criticality = event.get("criticality", "MenosCritico")

        temp_manifest_bucket = manifest["bucket"]
        temp_manifest_key = manifest["key"]

        dest_bucket_name = BACKUP_BUCKET_ARN.split(":")[-1]  # Para data
        manifests_bucket_name = MANIFESTS_BUCKET  # Para manifests

        # Build prefixes with timestamp
        now = datetime.now(timezone.utc)
        timestamp_suffix = now.strftime("%Y%m%d-%H%M%S")

        # Data prefix (en bucket CENTRAL con KMS)
        data_prefix = (
            f"backup/criticality={criticality}/backup_type={backup_type}/generation={generation}/"
            f"initiative={S3_BACKUP_INICIATIVA}/bucket={source_bucket}/"
            f"year={now.strftime('%Y')}/month={now.strftime('%m')}/"
            f"day={now.strftime('%d')}/hour={now.strftime('%H')}/timestamp={timestamp_suffix}"
        )
        
        # Manifests prefix (en bucket MANIFESTS con AES256)
        manifests_prefix = (
            f"manifests/criticality={criticality}/backup_type={backup_type}/"
            f"initiative={S3_BACKUP_INICIATIVA}/bucket={source_bucket}/"
            f"year={now.strftime('%Y')}/month={now.strftime('%m')}/"
            f"day={now.strftime('%d')}/hour={now.strftime('%H')}"
        )
        
        # Reports prefix (en bucket CENTRAL)
        reports_prefix = (
            f"reports/criticality={criticality}/backup_type={backup_type}/generation={generation}/"
            f"initiative={S3_BACKUP_INICIATIVA}/bucket={source_bucket}/"
            f"year={now.strftime('%Y')}/month={now.strftime('%m')}/"
            f"day={now.strftime('%d')}/hour={now.strftime('%H')}"
        )
        
        final_manifest_key = f"{manifests_prefix}/manifest.csv"

        # Validar existencia de buckets y mover manifest al bucket MANIFESTS (no al central)
        try:
            s3_client.head_bucket(Bucket=temp_manifest_bucket)
        except Exception as e:
            logger.error("Source manifest bucket does not exist or is not accessible: %s", temp_manifest_bucket)
            raise
        try:
            s3_client.head_bucket(Bucket=manifests_bucket_name)
        except Exception:
            logger.warning(
                "Manifests bucket not found or inaccessible: %s. Will attempt to keep manifest in source bucket.",
                manifests_bucket_name,
            )
            manifests_bucket_name = temp_manifest_bucket

        logger.info(
            "Moving manifest from s3://%s/%s to s3://%s/%s",
            temp_manifest_bucket, temp_manifest_key,
            manifests_bucket_name, final_manifest_key,
        )
        s3_client.copy_object(
            Bucket=manifests_bucket_name,
            CopySource={"Bucket": temp_manifest_bucket, "Key": temp_manifest_key},
            Key=final_manifest_key,
        )
        s3_client.delete_object(Bucket=temp_manifest_bucket, Key=temp_manifest_key)

        # Get manifest ETag
        head_resp = s3_client.head_object(Bucket=manifests_bucket_name, Key=final_manifest_key)
        final_etag = head_resp["ETag"].strip('"')

        # Submit Batch Job
        logger.info("Submitting S3 Batch Operations job with manifest %s", final_manifest_key)
        response = s3_control.create_job(
            AccountId=ACCOUNT_ID,
            ConfirmationRequired=False,
            Operation={
                "S3PutObjectCopy": {
                    "TargetResource": BACKUP_BUCKET_ARN,
                    "TargetKeyPrefix": data_prefix,
                }
            },
            Description=(
                f"Backup {backup_type} for {source_bucket} ({criticality}) - {now.isoformat()}"
            ),
            Report={
                "Enabled": True,
                "Bucket": BACKUP_BUCKET_ARN,
                "Prefix": reports_prefix,
                "Format": "Report_CSV_20180820",
                "ReportScope": "AllTasks",
            },
            Manifest={
                "Spec": {
                    "Format": "S3BatchOperations_CSV_20180820",
                    "Fields": ["Bucket", "Key"],
                },
                "Location": {
                    #  ARN del bucket MANIFESTS
                    "ObjectArn": f"arn:aws:s3:::{manifests_bucket_name}/{final_manifest_key}",
                    "ETag": final_etag,
                },
            },
            RoleArn=BATCH_ROLE_ARN,
            Priority=10,
            ClientRequestToken=str(uuid.uuid4()),
        )

        job_id = response["JobId"]
        logger.info("Created S3 Batch Job %s", job_id)
        return {"status": "JOB_CREATED", "jobId": job_id}

    except Exception as e:
        logger.error("Failed to submit S3 Batch Job: %s", e, exc_info=True)
        raise
