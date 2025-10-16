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
MANIFESTS_BUCKET = os.environ["MANIFESTS_BUCKET"]
INICIATIVA = os.environ.get("INICIATIVA", "backup")
GENERATION_INCREMENTAL = os.environ.get("GENERATION_INCREMENTAL", "son")
CRITICALITY_TAG_KEY = os.environ.get("CRITICALITY_TAG_KEY", "BackupCriticality")
ACCOUNT_ID = os.environ["ACCOUNT_ID"]
BATCH_ROLE_ARN = os.environ["BATCH_ROLE_ARN"]

if not MANIFESTS_BUCKET:
    raise ValueError("MANIFESTS_BUCKET environment variable must be defined")

try:
    ALLOWED_PREFIXES = json.loads(os.environ.get("ALLOWED_PREFIXES", "{}"))
except json.JSONDecodeError:
    ALLOWED_PREFIXES = {}

FREQUENCY_MAP = {
    "Critico": 12,
    "MenosCritico": 24,
    "NoCritico": None,
}

# Caché simple para no volver a consultar las etiquetas de cada bucket
bucket_criticality_cache: Dict[str, str] = {}

# ---------------------------------------------------------------------------
# Funciones auxiliares
# ---------------------------------------------------------------------------
def get_bucket_criticality(bucket_name: str) -> str:
    cached = bucket_criticality_cache.get(bucket_name)
    if cached:
        return cached

    try:
        response = s3_client.get_bucket_tagging(Bucket=bucket_name)
        tags = {t["Key"]: t["Value"] for t in response.get("TagSet", [])}
        criticality = tags.get(CRITICALITY_TAG_KEY, "MenosCritico")
    except s3_client.exceptions.ClientError as e:
        if e.response["Error"]["Code"] == "NoSuchTagSet":
            logger.warning(
                "Bucket %s sin etiquetas. Usando MenosCritico por defecto.",
                bucket_name,
            )
            criticality = "MenosCritico"
        else:
            raise

    bucket_criticality_cache[bucket_name] = criticality
    return criticality


def within_allowed_prefixes(criticality: str, object_key: str) -> bool:
    prefixes = ALLOWED_PREFIXES.get(criticality, [])
    if not prefixes:
        return True
    return any(object_key.startswith(p) for p in prefixes)


def compute_window_start(event_time: datetime, freq_hours: int) -> datetime:
    window_hour = (event_time.hour // freq_hours) * freq_hours
    return event_time.replace(hour=window_hour, minute=0, second=0, microsecond=0)


def upload_manifest(
    criticality: str,
    source_bucket: str,
    window_start: datetime,
    object_keys: Set[str],
) -> Tuple[str, str, str, str]:
    """Sube el CSV con los objetos del ciclo incremental y devuelve (key, etag, window_label, run_id)."""
    window_label = window_start.strftime("%Y%m%dT%H%MZ")
    run_id = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
    manifest_key = (
        f"manifests/criticality={criticality}/backup_type=incremental/"
        f"initiative={INICIATIVA}/bucket={source_bucket}/window={window_label}/"
        f"manifest-{run_id}.csv"
    )

    csv_body = "\n".join(f"{source_bucket},{key}" for key in sorted(object_keys))

    s3_client.put_object(
        Bucket=MANIFESTS_BUCKET,
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

    etag = s3_client.head_object(Bucket=MANIFESTS_BUCKET, Key=manifest_key)["ETag"].strip('"')
    return manifest_key, etag, window_label, run_id


def submit_batch_job(
    criticality: str,
    source_bucket: str,
    window_start: datetime,
    manifest_key: str,
    manifest_etag: str,
    window_label: str,
    run_id: str,
) -> str:
    """Crea un job de S3 Batch Operations para copiar los objetos listados en el manifiesto."""
    data_prefix = (
        f"backup/criticality={criticality}/backup_type=incremental/generation={GENERATION_INCREMENTAL}/"
        f"initiative={INICIATIVA}/bucket={source_bucket}/"
        f"year={window_start.strftime('%Y')}/month={window_start.strftime('%m')}/"
        f"day={window_start.strftime('%d')}/hour={window_start.strftime('%H')}"
    )

    reports_prefix = (
        f"reports/criticality={criticality}/backup_type=incremental/"
        f"initiative={INICIATIVA}/bucket={source_bucket}/"
        f"window={window_label}/run={run_id}"
    )

    manifest_arn = f"arn:aws:s3:::{MANIFESTS_BUCKET}/{manifest_key}"
    description = (
        f"Incremental backup for {source_bucket} ({criticality}) window {window_label}"
    )

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
    logger.info(
        "S3 Batch Operations job %s creado para bucket %s (criticality=%s, window=%s)",
        job_id,
        source_bucket,
        criticality,
        window_label,
    )
    return job_id


# ---------------------------------------------------------------------------
# Handler principal
# ---------------------------------------------------------------------------
def lambda_handler(event, context):
    records = event.get("Records", [])
    logger.info("Evento recibido con %d registros", len(records))

    grouped_objects: Dict[Tuple[str, str, str], Set[str]] = {}
    window_metadata: Dict[Tuple[str, str, str], datetime] = {}

    processing_failed = False

    for record in records:
        try:
            s3_event = json.loads(record["body"])
            for s3_record in s3_event.get("Records", []):
                bucket_name = s3_record["s3"]["bucket"]["name"]
                object_key = unquote_plus(s3_record["s3"]["object"]["key"])
                event_time = datetime.fromisoformat(
                    s3_record["eventTime"].replace("Z", "+00:00")
                )

                criticality = get_bucket_criticality(bucket_name)
                freq_hours = FREQUENCY_MAP.get(criticality)
                if not freq_hours:
                    logger.debug(
                        "Bucket %s con criticidad %s no requiere incrementales. Omitiendo.",
                        bucket_name,
                        criticality,
                    )
                    continue

                if not within_allowed_prefixes(criticality, object_key):
                    logger.debug(
                        "Objeto %s fuera de prefijos permitidos para criticidad %s. Omitido.",
                        object_key,
                        criticality,
                    )
                    continue

                window_start = compute_window_start(event_time, freq_hours)
                window_label = window_start.strftime("%Y%m%dT%H%MZ")

                group_key = (criticality, bucket_name, window_label)
                grouped_objects.setdefault(group_key, set()).add(object_key)
                window_metadata[group_key] = window_start.astimezone(timezone.utc)

        except Exception as exc:
            processing_failed = True
            logger.error("Error procesando record %s: %s", record, exc, exc_info=True)

    jobs_created = []

    for group_key, object_keys in grouped_objects.items():
        if not object_keys:
            continue

        criticality, source_bucket, window_label = group_key
        window_start = window_metadata[group_key]

        try:
            manifest_key, manifest_etag, manifest_window_label, run_id = upload_manifest(
                criticality, source_bucket, window_start, object_keys
            )
            job_id = submit_batch_job(
                criticality=criticality,
                source_bucket=source_bucket,
                window_start=window_start,
                manifest_key=manifest_key,
                manifest_etag=manifest_etag,
                window_label=manifest_window_label,
                run_id=run_id,
            )
            jobs_created.append(job_id)
        except Exception as exc:
            processing_failed = True
            logger.error(
                "Error creando manifiesto o job para bucket %s ventana %s: %s",
                source_bucket,
                window_label,
                exc,
                exc_info=True,
            )

    if processing_failed:
        raise RuntimeError("Incremental backup failed processing one or more records.")

    status = "NO_OBJECTS" if not jobs_created else "BATCH_SUBMITTED"
    return {"status": status, "jobs": jobs_created, "backup_bucket": BACKUP_BUCKET}
