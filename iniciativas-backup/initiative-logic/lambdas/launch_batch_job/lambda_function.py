import boto3
import os
import logging
import json
import uuid
import hashlib
from datetime import datetime, timezone
from typing import Dict, Any

logger = logging.getLogger()
logger.setLevel(os.environ.get("LOG_LEVEL", "INFO").upper())

# Environment config - SIMPLIFICADO
ACCOUNT_ID = os.environ["ACCOUNT_ID"]
BACKUP_BUCKET_ARN = os.environ["BACKUP_BUCKET_ARN"]
BATCH_ROLE_ARN = os.environ["BATCH_ROLE_ARN"]
S3_BACKUP_INICIATIVA = os.environ.get("S3_BACKUP_INICIATIVA", "backup")

# Derivar nombre del bucket desde el ARN
CENTRAL_BUCKET_NAME = BACKUP_BUCKET_ARN.split(":")[-1]

s3_control = boto3.client("s3control")
s3_client = boto3.client("s3")


def move_manifest_if_needed(
    temp_bucket: str,
    temp_key: str,
    final_key: str
) -> str:
    """
    Mueve el manifest a su ubicación final si es necesario.
    
    Returns:
        ETag del manifest en su ubicación final
    """
    if temp_key == final_key:
        logger.info("Manifest already in final location: s3://%s/%s", 
                   CENTRAL_BUCKET_NAME, final_key)
        head_resp = s3_client.head_object(Bucket=CENTRAL_BUCKET_NAME, Key=final_key)
        return head_resp["ETag"]
    
    # Validar que ambos están en el bucket central
    if temp_bucket != CENTRAL_BUCKET_NAME:
        raise ValueError(
            f"Temp manifest is not in central bucket. "
            f"Expected: {CENTRAL_BUCKET_NAME}, Got: {temp_bucket}"
        )
    
    logger.info(
        "   Moving manifest:\n"
        "   From: s3://%s/%s\n"
        "   To:   s3://%s/%s",
        temp_bucket, temp_key,
        CENTRAL_BUCKET_NAME, final_key
    )
    
    try:
        # Copy manifest a ubicación final
        s3_client.copy_object(
            Bucket=CENTRAL_BUCKET_NAME,
            CopySource={"Bucket": temp_bucket, "Key": temp_key},
            Key=final_key,
            ServerSideEncryption="AES256",  # Forzar cifrado
            MetadataDirective="COPY"  # Preservar metadata original
        )
        
        # Verificar que la copia fue exitosa antes de borrar
        head_resp = s3_client.head_object(Bucket=CENTRAL_BUCKET_NAME, Key=final_key)
        final_etag = head_resp["ETag"]
        
        # Solo borrar si la verificación fue exitosa
        s3_client.delete_object(Bucket=temp_bucket, Key=temp_key)
        
        logger.info("✅ Manifest moved successfully (ETag: %s)", final_etag)
        return final_etag
        
    except Exception as e:
        logger.error("Failed to move manifest: %s", e, exc_info=True)
        # Intentar limpiar copia parcial si existe
        try:
            s3_client.delete_object(Bucket=CENTRAL_BUCKET_NAME, Key=final_key)
        except:
            pass
        raise


def lambda_handler(event: Dict[str, Any], context: object) -> Dict[str, Any]:
    """
    Entrypoint for the launch_batch_job Lambda.
    
    Expected event structure:
    {
        "manifest": {
            "bucket": str,
            "key": str,
            "etag": str
        },
        "source_bucket": str,
        "backup_type": "incremental" | "full",
        "generation": "son" | "father" | "grandfather",
        "criticality": "Critico" | "MenosCritico" | "NoCritico"
    }
    """
    try:
        logger.info("="*80)
        logger.info("   Iniciando launch_batch_job")
        logger.info("   Event: %s", json.dumps(event, indent=2))
        logger.info("="*80)

        # Extract event parameters
        manifest = event["manifest"]
        source_bucket = event["source_bucket"]
        backup_type = event["backup_type"]
        generation = event.get("generation", "father" if backup_type == "full" else "son")
        criticality = event.get("criticality", "MenosCritico")

        temp_manifest_bucket = manifest["bucket"]
        temp_manifest_key = manifest["key"]

        # Build deterministic id (idempotent) from window label (preferred)
        window_label = event.get("window_label")
        if not window_label:
            # fallback estable si no se pasa la ventana
            window_label = datetime.now(timezone.utc).strftime("%Y%m%dT%H%MZ")
        base_id = f"{source_bucket}|{backup_type}|{generation}|{criticality}|{window_label}"
        token = hashlib.sha256(base_id.encode("utf-8")).hexdigest()
        # Use visible window label as suffix, so reintentos escriben mismo prefijo
        timestamp_suffix = window_label
        now = datetime.now(timezone.utc)

        # Data prefix - donde S3 Batch copiará los objetos
        data_prefix = (
            f"backup/criticality={criticality}/backup_type={backup_type}/"
            f"generation={generation}/initiative={S3_BACKUP_INICIATIVA}/"
            f"bucket={source_bucket}/"
            f"year={now.strftime('%Y')}/month={now.strftime('%m')}/"
            f"day={now.strftime('%d')}/hour={now.strftime('%H')}/"
            f"timestamp={timestamp_suffix}"
        )
        
        # Manifests prefix - ubicación final del manifest CSV
        manifests_prefix = (
            f"manifests/criticality={criticality}/backup_type={backup_type}/"
            f"initiative={S3_BACKUP_INICIATIVA}/bucket={source_bucket}/"
            f"year={now.strftime('%Y')}/month={now.strftime('%m')}/"
            f"day={now.strftime('%d')}/hour={now.strftime('%H')}"
        )
        
        # Reports prefix - donde S3 Batch escribirá sus reportes
        reports_prefix = (
            f"reports/criticality={criticality}/backup_type={backup_type}/"
            f"generation={generation}/initiative={S3_BACKUP_INICIATIVA}/"
            f"bucket={source_bucket}/"
            f"year={now.strftime('%Y')}/month={now.strftime('%m')}/"
            f"day={now.strftime('%d')}/hour={now.strftime('%H')}"
        )
        
        final_manifest_key = f"{manifests_prefix}/manifest-{timestamp_suffix}.csv"

        logger.info("   Paths configurados:")
        logger.info("   Data:      backup/...")
        logger.info("   Manifest:  %s", final_manifest_key)
        logger.info("   Reports:   %s", reports_prefix)

        # Move manifest to final location and get ETag
        final_etag = move_manifest_if_needed(
            temp_manifest_bucket,
            temp_manifest_key,
            final_manifest_key
        )

        # Build manifest ARN for S3 Batch
        manifest_arn = f"arn:aws:s3:::{CENTRAL_BUCKET_NAME}/{final_manifest_key}"

        # Submit S3 Batch Operations job
        logger.info("="*80)
        logger.info("   Submitting S3 Batch Operations job")
        logger.info("   Source bucket:  %s", source_bucket)
        logger.info("   Backup type:    %s", backup_type)
        logger.info("   Generation:     %s", generation)
        logger.info("   Criticality:    %s", criticality)
        logger.info("   Manifest ARN:   %s", manifest_arn)
        logger.info("   Manifest ETag:  %s", final_etag)
        logger.info("="*80)
        
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
                f"Backup {backup_type}/{generation} for {source_bucket} "
                f"({criticality}) - {now.isoformat()}"
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
                    "ObjectArn": manifest_arn,
                    "ETag": final_etag,
                },
            },
            RoleArn=BATCH_ROLE_ARN,
            Priority=10,
            # Idempotent token to prevent duplicate jobs on retries
            ClientRequestToken=token,
        )

        job_id = response["JobId"]
        
        logger.info("="*80)
        logger.info("S3 Batch Job creado exitosamente")
        logger.info("   Job ID: %s", job_id)
        logger.info("   Manifest: s3://%s/%s", CENTRAL_BUCKET_NAME, final_manifest_key)
        logger.info("="*80)
        
        return {
            "status": "JOB_CREATED",
            "jobId": job_id,
            "manifest_location": f"s3://{CENTRAL_BUCKET_NAME}/{final_manifest_key}",
            "data_prefix": data_prefix,
            "reports_prefix": reports_prefix,
            "source_bucket": source_bucket,
            "backup_type": backup_type,
            "generation": generation,
            "criticality": criticality,
        }

    except KeyError as e:
        logger.error("Missing required field in event: %s", e)
        logger.error("   Event received: %s", json.dumps(event, indent=2))
        raise ValueError(f"Missing required field: {e}")
    
    except Exception as e:
        logger.error("="*80)
        logger.error("Failed to submit S3 Batch Job")
        logger.error("   Error: %s", e)
        logger.error("="*80, exc_info=True)
        raise