import boto3
import json
import os
import logging
import uuid
from urllib.parse import unquote_plus
from datetime import datetime, timezone
from typing import Dict, Set, Tuple

# ---------------------------------------------------------------------------
# Configuración global
# ---------------------------------------------------------------------------
logger = logging.getLogger()
logger.setLevel(os.environ.get("LOG_LEVEL", "INFO").upper())

s3_client = boto3.client("s3")
s3_control = boto3.client("s3control")

BACKUP_BUCKET = os.environ["BACKUP_BUCKET"]
BACKUP_BUCKET_ARN = os.environ["BACKUP_BUCKET_ARN"]
INICIATIVA = os.environ.get("INICIATIVA", "backup")
GENERATION_INCREMENTAL = os.environ.get("GENERATION_INCREMENTAL", "son")
CRITICALITY_TAG_KEY = os.environ.get("CRITICALITY_TAG_KEY", "BackupCriticality")
ACCOUNT_ID = os.environ["ACCOUNT_ID"]
BATCH_ROLE_ARN = os.environ["BATCH_ROLE_ARN"]

# Prefijos permitidos por criticidad
try:
    ALLOWED_PREFIXES = json.loads(os.environ.get("ALLOWED_PREFIXES", "{}"))
except json.JSONDecodeError:
    logger.warning("ALLOWED_PREFIXES inválido, usando vacío")
    ALLOWED_PREFIXES = {}

# Frecuencias de ventanas por criticidad
FREQUENCY_MAP = {
    "Critico": 12,
    "MenosCritico": 24,
    "NoCritico": None,  # No requiere incrementales
}

# Caché para no repetir consultas de tags
bucket_criticality_cache: Dict[str, str] = {}


# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

def get_bucket_criticality(bucket_name: str) -> str:
    """Obtiene la criticidad del bucket desde tags, con caché."""
    cached = bucket_criticality_cache.get(bucket_name)
    if cached:
        return cached

    try:
        response = s3_client.get_bucket_tagging(Bucket=bucket_name)
        tags = {t["Key"]: t["Value"] for t in response.get("TagSet", [])}
        criticality = tags.get(CRITICALITY_TAG_KEY, "MenosCritico")
    except s3_client.exceptions.ClientError as e:
        error_code = e.response["Error"]["Code"]
        if error_code == "NoSuchTagSet":
            logger.warning(f"Bucket {bucket_name} sin tags, usando MenosCritico")
            criticality = "MenosCritico"
        else:
            raise

    bucket_criticality_cache[bucket_name] = criticality
    return criticality


def within_allowed_prefixes(criticality: str, object_key: str) -> bool:
    """Verifica si el objeto está dentro de los prefijos permitidos."""
    prefixes = ALLOWED_PREFIXES.get(criticality, [])
    if not prefixes:
        return True  # Sin filtro = todo permitido
    return any(object_key.startswith(p) for p in prefixes)


def compute_window_start(event_time: datetime, freq_hours: int) -> datetime:
    """Calcula el inicio de la ventana temporal según frecuencia."""
    window_hour = (event_time.hour // freq_hours) * freq_hours
    return event_time.replace(hour=window_hour, minute=0, second=0, microsecond=0)


# ============================================================================
# MANIFEST GENERATION
# ============================================================================

def upload_manifest(
    criticality: str,
    source_bucket: str,
    window_start: datetime,
    object_keys: Set[str],
) -> Tuple[str, str, str, str]:
    """
    Sube el CSV con los objetos del ciclo incremental.
    
    Returns:
        Tuple[key, etag, window_label, run_id]
    """
    window_label = window_start.strftime("%Y%m%dT%H%MZ")
    run_id = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
    
    manifest_key = (
        f"manifests/criticality={criticality}/backup_type=incremental/"
        f"initiative={INICIATIVA}/bucket={source_bucket}/window={window_label}/"
        f"manifest-{run_id}.csv"
    )
    

    csv_body = "\n".join(f"{source_bucket},{key}" for key in sorted(object_keys))

    logger.info(f"Subiendo manifiesto: s3://{BACKUP_BUCKET}/{manifest_key}")

    # Usar el mismo bucket central con AES256
    s3_client.put_object(
        Bucket=BACKUP_BUCKET,
        Key=manifest_key,
        Body=csv_body.encode("utf-8"),
        ContentType="text/csv",
        ServerSideEncryption="AES256", 
        Metadata={
            "criticality": criticality,
            "object-count": str(len(object_keys)),
            "source-bucket": source_bucket,
            "window-start": window_label,
            "created-at": run_id,
        },
    )

    # Obtener ETag
    etag = s3_client.head_object(
        Bucket=BACKUP_BUCKET, 
        Key=manifest_key
    )["ETag"].strip('"')

    logger.info(f"Manifiesto creado con {len(object_keys)} objetos")

    return manifest_key, etag, window_label, run_id


# ============================================================================
# S3 BATCH JOB SUBMISSION
# ============================================================================

def submit_batch_job(
    criticality: str,
    source_bucket: str,
    window_start: datetime,
    manifest_key: str,
    manifest_etag: str,
    window_label: str,
    run_id: str,
) -> str:
    """Crea un job de S3 Batch Operations para copiar los objetos."""
    
    #Agregado timestamp al data_prefix
    data_prefix = (
        f"backup/criticality={criticality}/backup_type=incremental/"
        f"generation={GENERATION_INCREMENTAL}/"
        f"initiative={INICIATIVA}/bucket={source_bucket}/"
        f"year={window_start.strftime('%Y')}/month={window_start.strftime('%m')}/"
        f"day={window_start.strftime('%d')}/hour={window_start.strftime('%H')}/"
        f"timestamp={run_id}" 
    )

    # Prefijo de reportes
    reports_prefix = (
        f"reports/criticality={criticality}/backup_type=incremental/"
        f"initiative={INICIATIVA}/bucket={source_bucket}/"
        f"window={window_label}/run={run_id}"
    )

    # ARN del manifiesto en el bucket central
    manifest_arn = f"arn:aws:s3:::{BACKUP_BUCKET}/{manifest_key}"
    
    description = (
        f"Incremental backup for {source_bucket} ({criticality}) window {window_label}"
    )

    logger.info(f"   Creando S3 Batch Job:")
    logger.info(f"   Source: {source_bucket}")
    logger.info(f"   Criticality: {criticality}")
    logger.info(f"   Window: {window_label}")
    logger.info(f"   Manifest: s3://{BACKUP_BUCKET}/{manifest_key}")

    try:
        response = s3_control.create_job(
            AccountId=ACCOUNT_ID,
            ConfirmationRequired=False,
            Operation={
                "S3PutObjectCopy": {
                    "TargetResource": BACKUP_BUCKET_ARN,
                    "TargetKeyPrefix": data_prefix,
                }
            },
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
                    "ETag": manifest_etag,
                },
            },
            Description=description,
            RoleArn=BATCH_ROLE_ARN,
            Priority=10,
            ClientRequestToken=str(uuid.uuid4()),
        )

        job_id = response["JobId"]
        logger.info(f"S3 Batch Job creado: {job_id}")
        return job_id
    
    except Exception as e:
        logger.error(f"Error creando Batch Job: {e}", exc_info=True)
        raise


# ============================================================================
# LAMBDA HANDLER
# ============================================================================

def lambda_handler(event, context):
    """
    Handler principal para backups incrementales event-driven.
    Procesa eventos S3 desde SQS, agrupa por ventanas y genera batch jobs.
    """
    records = event.get("Records", [])
    logger.info("="*80)
    logger.info(f"Evento recibido con {len(records)} registros SQS")
    logger.info("="*80)

    # Agrupar objetos por (criticidad, bucket, ventana)
    grouped_objects: Dict[Tuple[str, str, str], Set[str]] = {}
    window_metadata: Dict[Tuple[str, str, str], datetime] = {}

    processing_failed = False

    # Procesar cada registro SQS
    for record in records:
        try:
            s3_event = json.loads(record["body"])
            
            for s3_record in s3_event.get("Records", []):
                bucket_name = s3_record["s3"]["bucket"]["name"]
                object_key = unquote_plus(s3_record["s3"]["object"]["key"])
                event_time = datetime.fromisoformat(
                    s3_record["eventTime"].replace("Z", "+00:00")
                )

                logger.debug(f"Procesando: s3://{bucket_name}/{object_key}")

                # Obtener criticidad del bucket
                criticality = get_bucket_criticality(bucket_name)
                freq_hours = FREQUENCY_MAP.get(criticality)
                
                # Validar si requiere incrementales
                if not freq_hours:
                    logger.debug(
                        f"Bucket {bucket_name} ({criticality}) no requiere incrementales"
                    )
                    continue

                # Validar prefijos permitidos
                if not within_allowed_prefixes(criticality, object_key):
                    logger.debug(
                        f"Objeto fuera de prefijos permitidos: {object_key}"
                    )
                    continue

                # Calcular ventana temporal
                window_start = compute_window_start(event_time, freq_hours)
                window_label = window_start.strftime("%Y%m%dT%H%MZ")

                # Agrupar objeto
                group_key = (criticality, bucket_name, window_label)
                grouped_objects.setdefault(group_key, set()).add(object_key)
                window_metadata[group_key] = window_start.astimezone(timezone.utc)

        except Exception as exc:
            processing_failed = True
            logger.error(f"Error procesando record: {exc}", exc_info=True)

    # Procesar grupos y crear batch jobs
    jobs_created = []
    logger.info(f"\n Grupos encontrados: {len(grouped_objects)}")

    for group_key, object_keys in grouped_objects.items():
        if not object_keys:
            continue

        criticality, source_bucket, window_label = group_key
        window_start = window_metadata[group_key]

        logger.info(f"\n Procesando grupo:")
        logger.info(f"   Bucket: {source_bucket}")
        logger.info(f"   Criticality: {criticality}")
        logger.info(f"   Window: {window_label}")
        logger.info(f"   Objects: {len(object_keys)}")

        try:
            # Subir manifiesto
            manifest_key, manifest_etag, manifest_window_label, run_id = upload_manifest(
                criticality, source_bucket, window_start, object_keys
            )
            
            # Crear batch job
            job_id = submit_batch_job(
                criticality=criticality,
                source_bucket=source_bucket,
                window_start=window_start,
                manifest_key=manifest_key,
                manifest_etag=manifest_etag,
                window_label=manifest_window_label,
                run_id=run_id,
            )
            
            jobs_created.append({
                "job_id": job_id,
                "bucket": source_bucket,
                "criticality": criticality,
                "window": window_label,
                "objects": len(object_keys)
            })
        
        except Exception as exc:
            processing_failed = True
            logger.error(
                f"Error creando job para {source_bucket} ventana {window_label}: {exc}",
                exc_info=True
            )

    # Error si hubo fallos
    if processing_failed:
        logger.error("="*80)
        logger.error("Incremental backup tuvo errores")
        logger.error("="*80)
        raise RuntimeError("Incremental backup failed processing one or more records")

    # Resultado
    status = "NO_OBJECTS" if not jobs_created else "BATCH_SUBMITTED"
    
    logger.info("="*80)
    logger.info(f"Proceso completado: {len(jobs_created)} jobs creados")
    logger.info("="*80)

    return {
        "status": status,
        "jobs": jobs_created,
        "backup_bucket": BACKUP_BUCKET,
        "total_objects": sum(j["objects"] for j in jobs_created)
    }