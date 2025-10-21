import boto3
import json
import os
import logging
import uuid
from urllib.parse import unquote_plus
from datetime import datetime, timezone
from typing import Dict, Set, Tuple, Optional, List

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

# ============================================================================
# FRECUENCIAS CONFIGURABLES (CORREGIDO)
# ============================================================================
# Leer frecuencias desde variables de entorno en lugar de hardcodear
# Formato: BACKUP_FREQUENCY_HOURS_CRITICO=12
# ============================================================================

def get_frequency_hours(criticality: str) -> Optional[int]:
    """
    Obtiene la frecuencia de ventana en horas desde variables de entorno.
    
    Returns:
        int: Horas de ventana, o None si no requiere incrementales
    """
    env_var_name = f"BACKUP_FREQUENCY_HOURS_{criticality.upper()}"
    freq_str = os.environ.get(env_var_name)
    
    if freq_str is None or freq_str == "" or freq_str == "0":
        logger.debug(f"No se encontró {env_var_name} o está deshabilitado")
        return None
    
    try:
        freq = int(freq_str)
        if freq <= 0:
            logger.warning(f"{env_var_name}={freq} inválido, ignorando incrementales")
            return None
        return freq
    except ValueError:
        logger.error(f"{env_var_name}={freq_str} no es un número válido")
        return None

# Caché para no repetir consultas de tags
bucket_criticality_cache: Dict[str, str] = {}


# ============================================================================
# CHECKPOINTS (incremental windows)
# ============================================================================

def _window_checkpoint_key(source_bucket: str, criticality: str, window_label: str) -> str:
    return f"checkpoints/incremental/{source_bucket}/{criticality}/{window_label}.marker"


def has_window_been_processed(backup_bucket: str, source_bucket: str, criticality: str, window_label: str) -> bool:
    """Returns True if a checkpoint marker exists for this (bucket, criticality, window)."""
    key = _window_checkpoint_key(source_bucket, criticality, window_label)
    try:
        s3_client.head_object(Bucket=backup_bucket, Key=key)
        return True
    except s3_client.exceptions.NoSuchKey:
        return False
    except Exception:
        return False


def write_window_checkpoint(backup_bucket: str, source_bucket: str, criticality: str, window_label: str):
    key = _window_checkpoint_key(source_bucket, criticality, window_label)
    s3_client.put_object(
        Bucket=backup_bucket,
        Key=key,
        Body=b"processed",
        ServerSideEncryption="AES256",
    )


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
    
    data_prefix = (
        f"backup/criticality={criticality}/backup_type=incremental/"
        f"generation={GENERATION_INCREMENTAL}/"
        f"initiative={INICIATIVA}/bucket={source_bucket}/"
        f"year={window_start.strftime('%Y')}/month={window_start.strftime('%m')}/"
        f"day={window_start.strftime('%d')}/hour={window_start.strftime('%H')}/"
        f"timestamp={run_id}" 
    )

    reports_prefix = (
        f"reports/criticality={criticality}/backup_type=incremental/"
        f"initiative={INICIATIVA}/bucket={source_bucket}/"
        f"window={window_label}/run={run_id}"
    )

    manifest_arn = f"arn:aws:s3:::{BACKUP_BUCKET}/{manifest_key}"
    
    description = (
        f"Incremental backup for {source_bucket} ({criticality}) window {window_label}"
    )

    logger.info(f"  Creando S3 Batch Job:")
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
    # Track which SQS messageIds feed each group for partial-batch failure reporting
    group_message_ids: Dict[Tuple[str, str, str], Set[str]] = {}
    failed_message_ids: List[str] = []

    # Procesar cada registro SQS
    for record in records:
        try:
            body = record.get("body", "")
            message_id = record.get("messageId") or record.get("messageId".upper(), "")
            try:
                s3_event = json.loads(body) if isinstance(body, str) else body
            except json.JSONDecodeError:
                logger.warning(f"Body no es JSON (messageId={message_id}); marcando como fallo parcial")
                if message_id:
                    failed_message_ids.append(message_id)
                continue
            
            recs = s3_event.get("Records", []) if isinstance(s3_event, dict) else []
            for s3_record in recs:
                if not isinstance(s3_record, dict):
                    continue
                if "s3" not in s3_record or "bucket" not in s3_record["s3"] or "object" not in s3_record["s3"]:
                    logger.debug("Record sin datos S3 esperados; omitiendo")
                    continue
                bucket_name = s3_record["s3"]["bucket"]["name"]
                object_key = unquote_plus(s3_record["s3"]["object"]["key"])
                event_time = datetime.fromisoformat(
                    s3_record["eventTime"].replace("Z", "+00:00")
                )

                logger.debug(f"Procesando: s3://{bucket_name}/{object_key}")

                # Obtener criticidad del bucket
                criticality = get_bucket_criticality(bucket_name)
                
                # Obtener frecuencia configurada (CAMBIO PRINCIPAL)
                freq_hours = get_frequency_hours(criticality)
                
                # Validar si requiere incrementales
                if not freq_hours:
                    logger.debug(
                        f"Bucket {bucket_name} ({criticality}) no requiere incrementales "
                        f"(frecuencia no configurada)"
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
                if message_id:
                    group_message_ids.setdefault(group_key, set()).add(message_id)
                
                logger.debug(
                    f"Objeto agrupado: {criticality} / {bucket_name} / "
                    f"ventana {freq_hours}h ({window_label})"
                )

        except Exception as exc:
            mid = record.get("messageId")
            if mid:
                failed_message_ids.append(mid)
            logger.error(f"Error procesando record {mid}: {exc}", exc_info=True)

    # Procesar grupos y crear batch jobs
    jobs_created = []
    logger.info(f"\n Grupos encontrados: {len(grouped_objects)}")

    for group_key, object_keys in grouped_objects.items():
        if not object_keys:
            continue

        criticality, source_bucket, window_label = group_key
        window_start = window_metadata[group_key]

        # Skip if this window was already processed (idempotence by window)
        if has_window_been_processed(BACKUP_BUCKET, source_bucket, criticality, window_label):
            logger.info(
                f"Ventana ya procesada anteriormente, saltando: {source_bucket} / {criticality} / {window_label}"
            )
            continue

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

            # Mark window as processed (checkpoint) after successful job submission
            try:
                write_window_checkpoint(BACKUP_BUCKET, source_bucket, criticality, window_label)
            except Exception as e:
                logger.warning(f"No se pudo escribir checkpoint de ventana {window_label}: {e}")
        
        except Exception as exc:
            # Map the failure to the contributing SQS messages for partial retries
            mids = list(group_message_ids.get(group_key, set()))
            failed_message_ids.extend(mids)
            logger.error(
                f"Error creando job para {source_bucket} ventana {window_label}: {exc}",
                exc_info=True
            )

    # Partial batch response (prevents reprocessing successful messages)
    failures = list({mid for mid in failed_message_ids if mid})
    if failures:
        logger.warning(f"Mensajes con error (parcial): {len(failures)}")
    
    status = "NO_OBJECTS" if not jobs_created else "BATCH_SUBMITTED"
    logger.info("="*80)
    logger.info(f"Proceso completado: {len(jobs_created)} jobs creados; fallidos={len(failures)}")
    logger.info("="*80)

    # SQS partial-batch contract
    try:
        return {
            "batchItemFailures": [{"itemIdentifier": mid} for mid in failures]
        }
    except Exception as e:
        # Blind fallback to avoid invocation error surfacing to Lambda metric
        logger.error(f"Fallo al construir respuesta parcial: {e}")
        return {"batchItemFailures": []}
