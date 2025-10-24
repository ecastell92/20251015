import boto3
import json
import os
import logging
import uuid
import time  # ← AGREGADO
from urllib.parse import unquote_plus
from datetime import datetime, timezone
from typing import Dict, Set, Tuple, Optional, List
import io
import csv

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
DISABLE_WINDOW_CHECKPOINT = os.environ.get("DISABLE_WINDOW_CHECKPOINT", "false").lower() == "true"

# Prefijos permitidos por criticidad
try:
    ALLOWED_PREFIXES = json.loads(os.environ.get("ALLOWED_PREFIXES", "{}"))
except json.JSONDecodeError:
    logger.warning("ALLOWED_PREFIXES inválido, usando vacío")
    ALLOWED_PREFIXES = {}

# ============================================================================
# FRECUENCIAS CONFIGURABLES
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
    """
    Aplica exclusiones (prefijo/sufijo y marcadores de carpeta) e inclusiones por criticidad.
    
    CORREGIDO: Exclusiones menos agresivas - solo excluye si el prefijo está:
    1. Al inicio del path (startswith)
    2. Precedido por / (para subdirectorios)
    
    NO excluye si el prefijo aparece en medio de un nombre de archivo/carpeta sin / delante.
    """
    # 1. Excluir marcadores de carpeta
    if object_key.endswith('/'):
        logger.debug(f"Excluido (marcador de carpeta): {object_key}")
        return False

    # 2. Cargar exclusiones desde entorno
    def _parse_list(name: str) -> List[str]:
        raw = os.environ.get(name, '')
        if not raw:
            return []
        try:
            vals = json.loads(raw)
            return [v for v in vals if isinstance(v, str)]
        except Exception:
            return [s.strip() for s in raw.split(',') if s.strip()]

    ex_prefixes = _parse_list('EXCLUDE_KEY_PREFIXES')
    ex_suffixes = _parse_list('EXCLUDE_KEY_SUFFIXES')

    # 3. Excluir por prefijo - CORREGIDO: Solo al inicio o precedido por /
    for p in ex_prefixes:
        if not p:
            continue
        # Normalizar prefijo para comparación
        p_normalized = p.rstrip('/')
        
        # Excluir si:
        # - Empieza con el prefijo: "temporary/file.txt"
        # - Tiene el prefijo precedido por /: "data/temporary/file.txt"
        if object_key.startswith(p_normalized + '/') or object_key.startswith(p_normalized):
            logger.debug(f"Excluido (prefijo al inicio): {object_key} (match: {p})")
            return False
        if f"/{p_normalized}/" in object_key:
            logger.debug(f"Excluido (prefijo en subdirectorio): {object_key} (match: {p})")
            return False
    
    # 4. Excluir por sufijo
    if any(object_key.endswith(s) for s in ex_suffixes):
        logger.debug(f"Excluido (sufijo): {object_key}")
        return False

    # 5. Aplicar prefijos permitidos por criticidad (inclusión)
    prefixes = ALLOWED_PREFIXES.get(criticality, [])
    if not prefixes:
        # Sin filtro = todo permitido (excepto exclusiones anteriores)
        return True
    
    # Verificar si el objeto está dentro de los prefijos permitidos
    allowed = any(object_key.startswith(p) for p in prefixes)
    if not allowed:
        logger.debug(f"Excluido (fuera de prefijos permitidos): {object_key}")
    return allowed


def compute_window_start(event_time: datetime, freq_hours: int) -> datetime:
    """Calcula el inicio de la ventana temporal según frecuencia."""
    window_hour = (event_time.hour // freq_hours) * freq_hours
    return event_time.replace(hour=window_hour, minute=0, second=0, microsecond=0)


# ============================================================================
# MANIFEST GENERATION - CORREGIDO
# ============================================================================

def upload_manifest(
    criticality: str,
    source_bucket: str,
    window_start: datetime,
    object_keys: Set[str],
) -> Tuple[str, str, str, str]:
    """
    Sube el CSV con los objetos del ciclo incremental.
    CORREGIDO: Obtiene ETag confiable y espera consistencia.
    
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

    # Build CSV safely using csv.writer (handles special chars)
    buf = io.StringIO()
    writer = csv.writer(buf)
    for key in sorted(object_keys):
        writer.writerow([source_bucket, key])
    csv_body = buf.getvalue()

    logger.info(f"Subiendo manifiesto: s3://{BACKUP_BUCKET}/{manifest_key}")

    # Upload con retry para asegurar consistencia
    max_attempts = 3
    for attempt in range(1, max_attempts + 1):
        try:
            put_resp = s3_client.put_object(
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

            # CRÍTICO: Obtener ETag del PutObject response
            etag = put_resp.get("ETag", "").strip('"')
            
            # Verificar inmediatamente que el objeto existe con el mismo ETag
            time.sleep(0.5)  # Pequeño delay para consistencia eventual
            head_resp = s3_client.head_object(Bucket=BACKUP_BUCKET, Key=manifest_key)
            head_etag = head_resp.get("ETag", "").strip('"')
            
            if etag and etag == head_etag:
                logger.info(f"✅ Manifiesto verificado con ETag: {etag}")
                logger.info(f"   Objetos: {len(object_keys)}")
                return manifest_key, etag, window_label, run_id
            else:
                logger.warning(
                    f"ETag mismatch en intento {attempt}: "
                    f"put={etag} vs head={head_etag}"
                )
                if attempt < max_attempts:
                    time.sleep(1)
                    continue
                    
        except Exception as e:
            logger.error(f"Error en intento {attempt}: {e}")
            if attempt < max_attempts:
                time.sleep(1)
                continue
            raise
    
    # Si llegamos aquí, todos los intentos fallaron
    raise RuntimeError(
        f"No se pudo subir manifest con ETag consistente después de {max_attempts} intentos"
    )


# ============================================================================
# S3 BATCH JOB SUBMISSION - SIMPLIFICADO
# ============================================================================

def submit_batch_job(
    criticality: str,
    source_bucket: str,
    window_start: datetime,
    manifest_key: str,
    manifest_etag: str,  # Ya viene sin comillas y verificado
    window_label: str,
    run_id: str,
) -> str:
    """Crea un job de S3 Batch Operations para copiar los objetos."""
    
    window_label = window_start.strftime('%Y%m%dT%H%MZ')
    data_prefix = (
        f"backup/criticality={criticality}/backup_type=incremental/"
        f"generation={GENERATION_INCREMENTAL}/"
        f"initiative={INICIATIVA}/bucket={source_bucket}/"
        f"year={window_start.strftime('%Y')}/month={window_start.strftime('%m')}/"
        f"day={window_start.strftime('%d')}/hour={window_start.strftime('%H')}/"
        f"window={window_label}"
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
    logger.info(f"   ETag: {manifest_etag}")

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
                    "ETag": manifest_etag,  # Sin comillas, ya verificado
                },
            },
            Description=description,
            RoleArn=BATCH_ROLE_ARN,
            Priority=10,
            ClientRequestToken=str(uuid.uuid4()),
        )

        job_id = response["JobId"]
        logger.info(f"✅ S3 Batch Job creado: {job_id}")
        return job_id
        
    except Exception as e:
        error_msg = str(e)
        logger.error(f"❌ Error creando Batch Job: {error_msg}")
        
        # Si es error de ETag, intentar una vez más con HeadObject fresh
        if "ETag" in error_msg or "etag" in error_msg.lower():
            logger.warning("⚠️  Reintentando con ETag fresh de HeadObject...")
            time.sleep(2)
            try:
                head_resp = s3_client.head_object(Bucket=BACKUP_BUCKET, Key=manifest_key)
                fresh_etag = head_resp["ETag"].strip('"')
                logger.info(f"   ETag fresh: {fresh_etag}")
                
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
                            "ETag": fresh_etag,
                        },
                    },
                    Description=description,
                    RoleArn=BATCH_ROLE_ARN,
                    Priority=10,
                    ClientRequestToken=str(uuid.uuid4()),
                )
                
                job_id = response["JobId"]
                logger.info(f"✅ S3 Batch Job creado (retry): {job_id}")
                return job_id
                
            except Exception as retry_error:
                logger.error(f"❌ Retry también falló: {retry_error}")
                raise
        
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
                
                # Obtener frecuencia configurada
                freq_hours = get_frequency_hours(criticality)
                
                # Validar si requiere incrementales
                if not freq_hours:
                    logger.debug(
                        f"Bucket {bucket_name} ({criticality}) no requiere incrementales "
                        f"(frecuencia no configurada)"
                    )
                    continue

                # Validar prefijos permitidos y exclusiones
                if not within_allowed_prefixes(criticality, object_key):
                    logger.debug(
                        f"Objeto excluido por filtros: {object_key}"
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
                    f"✅ Objeto incluido: {criticality} / {bucket_name} / "
                    f"ventana {freq_hours}h ({window_label})"
                )

        except Exception as exc:
            mid = record.get("messageId")
            if mid:
                failed_message_ids.append(mid)
            logger.error(f"Error procesando record {mid}: {exc}", exc_info=True)

    # Procesar grupos y crear batch jobs
    jobs_created = []
    logger.info(f"\n📦 Grupos encontrados: {len(grouped_objects)}")

    for group_key, object_keys in grouped_objects.items():
        if not object_keys:
            continue

        criticality, source_bucket, window_label = group_key
        window_start = window_metadata[group_key]

        # Optional idempotence by window
        if not DISABLE_WINDOW_CHECKPOINT:
            if has_window_been_processed(BACKUP_BUCKET, source_bucket, criticality, window_label):
                logger.info(
                    f"⏭️  Ventana ya procesada, saltando: {source_bucket} / {criticality} / {window_label}"
                )
                continue

        logger.info(f"\n📋 Procesando grupo:")
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

            # Mark window as processed (checkpoint)
            if not DISABLE_WINDOW_CHECKPOINT:
                try:
                    write_window_checkpoint(BACKUP_BUCKET, source_bucket, criticality, window_label)
                except Exception as e:
                    logger.warning(f"No se pudo escribir checkpoint de ventana {window_label}: {e}")
        
        except Exception as exc:
            # Map failure to contributing SQS messages
            mids = list(group_message_ids.get(group_key, set()))
            failed_message_ids.extend(mids)
            logger.error(
                f"❌ Error creando job para {source_bucket} ventana {window_label}: {exc}",
                exc_info=True
            )

    # Partial batch response
    failures = list({mid for mid in failed_message_ids if mid})
    if failures:
        logger.warning(f"⚠️  Mensajes con error (parcial): {len(failures)}")
    
    logger.info("="*80)
    logger.info(f"✅ Proceso completado: {len(jobs_created)} jobs creados; fallidos={len(failures)}")
    logger.info("="*80)

    # SQS partial-batch contract
    return {
        "batchItemFailures": [{"itemIdentifier": mid} for mid in failures]
    }