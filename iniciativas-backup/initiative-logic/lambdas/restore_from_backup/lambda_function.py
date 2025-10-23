import boto3
import csv
import io
import json
import logging
import os
from datetime import datetime
from typing import Dict, Any, Optional, Tuple

logger = logging.getLogger()
logger.setLevel(os.environ.get("LOG_LEVEL", "INFO").upper())

s3 = boto3.client("s3")

CENTRAL_BUCKET = os.environ["CENTRAL_BUCKET"]
INITIATIVE = os.environ.get("INITIATIVE", "backup")


def _latest_data_prefix(base_prefix: str) -> Optional[str]:
    """Devuelve el subprefijo más reciente bajo base_prefix. Soporta window=YYYYMMDDTHHMMZ y timestamp=YYYYMMDD-HHMMSS."""
    paginator = s3.get_paginator("list_objects_v2")
    latest_val: Optional[str] = None
    latest_prefix: Optional[str] = None
    try:
        for page in paginator.paginate(Bucket=CENTRAL_BUCKET, Prefix=base_prefix, Delimiter="/"):
            for cp in page.get("CommonPrefixes", []):
                p = cp.get("Prefix", "")
                val = None
                if "window=" in p:
                    val = p.rstrip("/").split("window=")[-1]
                elif "timestamp=" in p:
                    val = p.rstrip("/").split("timestamp=")[-1]
                if val and (latest_val is None or val > latest_val):
                    latest_val = val
                    latest_prefix = p
        if latest_prefix:
            return latest_prefix
        return None
    except Exception as e:
        logger.error(f"Error listando prefijos de datos en s3://{CENTRAL_BUCKET}/{base_prefix}: {e}")
        return None


def _resolve_paths_from_window(source_bucket: str, criticality: str, backup_type: str, generation: str,
                               window_label: str) -> Tuple[str, str]:
    """Devuelve (manifest_prefix, data_prefix_base) basados en una etiqueta de ventana."""
    y, m, d, h = window_label[0:4], window_label[4:6], window_label[6:8], window_label[9:11]
    manifests_prefix = (
        f"manifests/criticality={criticality}/backup_type={backup_type}/"
        f"initiative={INITIATIVE}/bucket={source_bucket}/window={window_label}/"
    )
    data_base_prefix = (
        f"backup/criticality={criticality}/backup_type={backup_type}/"
        f"generation={generation}/initiative={INITIATIVE}/bucket={source_bucket}/"
        f"year={y}/month={m}/day={d}/hour={h}/"
    )
    return manifests_prefix, data_base_prefix


def _find_latest_manifest(manif_prefix: str) -> Optional[str]:
    """Busca el manifest más reciente bajo un prefijo de manifests (acepta paths con window= o directos)."""
    paginator = s3.get_paginator("list_objects_v2")
    latest_key: Optional[str] = None
    latest_dt = None
    for page in paginator.paginate(Bucket=CENTRAL_BUCKET, Prefix=manif_prefix):
        for obj in page.get("Contents", []):
            key = obj["Key"]
            if key.endswith(".csv"):
                lm = obj.get("LastModified")
                if latest_dt is None or (lm and lm > latest_dt):
                    latest_dt = lm
                    latest_key = key
    return latest_key


def _iter_manifest_rows(manifest_key: str):
    """Itera filas del manifest.csv devolviendo (bucket, key)."""
    obj = s3.get_object(Bucket=CENTRAL_BUCKET, Key=manifest_key)
    body = obj["Body"].read()
    buf = io.StringIO(body.decode("utf-8"))
    reader = csv.reader(buf)
    for row in reader:
        if len(row) >= 2:
            yield row[0], row[1]


def lambda_handler(event: Dict[str, Any], context: Any) -> Dict[str, Any]:
    """
    Restaura objetos desde el bucket central al bucket origen sin usar DynamoDB.

    Event esperado:
    {
      "source_bucket": "dev-raw",
      "criticality": "MenosCritico|Critico|NoCritico",
      "backup_type": "incremental|full",
      "generation": "son|father|grandfather",
      "year": "2025",
      "month": "10",
      "day": "20",
      "hour": "20",
      "prefix": "opcional/prefijo/original/",
      "max_objects": 10000,
      "dry_run": true
    }
    Si no se proveen year/month/day/hour se usa el ultimo manifest disponible.
    """
    source_bucket = event.get("source_bucket")
    criticality = event.get("criticality", "MenosCritico")
    backup_type = event.get("backup_type", "incremental")
    generation = event.get("generation", "son")
    prefix_filter = event.get("prefix", "") or ""
    max_objects = int(event.get("max_objects", 10000) or 10000)
    dry_run = bool(event.get("dry_run", True))

    if not source_bucket:
        raise ValueError("source_bucket es requerido")

    # Resolver prefijos (si hay fecha/hora, usarlos; si no, buscar el ultimo)
    year = event.get("year")
    month = event.get("month")
    day = event.get("day")
    hour = event.get("hour")

    manifest_key: Optional[str] = None
    data_prefix: Optional[str] = None

    if all([year, month, day, hour]):
        # Derivar window_label (minuto 00) y usar nuevo esquema de prefixes
        window_label = f"{year}{month}{day}T{hour}00Z"
        manif_prefix, data_base = _resolve_paths_from_window(
            source_bucket, criticality, backup_type, generation, window_label
        )
        manifest_key = _find_latest_manifest(manif_prefix)
        if not manifest_key:
            raise RuntimeError(
                f"No se encontro manifest bajo s3://{CENTRAL_BUCKET}/{manif_prefix}. "
                f"Verifica parametros (bucket/criticidad/tipo/generacion/fecha)."
            )
        # Obtener prefijo de datos más reciente (window= o timestamp=)
        data_prefix = _latest_data_prefix(data_base)
        if not data_prefix:
            raise RuntimeError(
                f"No se encontro prefijo de datos con timestamp bajo s3://{CENTRAL_BUCKET}/{data_base}."
            )
    else:
        # Buscar último manifest en esquema actual (window=)
        prefix_root = f"manifests/criticality={criticality}/backup_type={backup_type}/initiative={INITIATIVE}/bucket={source_bucket}/"
        manifest_key = _find_latest_manifest(prefix_root)
        if not manifest_key:
            raise RuntimeError("No se encontro ningun manifest para los parametros indicados")
        # Derivar window_label desde el key (…/window=<label>/manifest-…)
        parts = manifest_key.split("/")
        window_label = ""
        for p in parts:
            if p.startswith("window="):
                window_label = p.split("window=")[-1]
                break
        if not window_label:
            # fallback: intentar desde fecha del objeto (menos preciso)
            obj = s3.head_object(Bucket=CENTRAL_BUCKET, Key=manifest_key)
            dt = obj.get("LastModified")
            if dt:
                window_label = dt.strftime("%Y%m%dT%H%MZ")
        _, data_base = _resolve_paths_from_window(source_bucket, criticality, backup_type, generation, window_label)
        data_prefix = _latest_data_prefix(data_base)

    if not data_prefix:
        raise RuntimeError("No se encontro un prefijo de datos con timestamp para restaurar")

    logger.info("Usando manifest: s3://%s/%s", CENTRAL_BUCKET, manifest_key)
    logger.info("Usando data prefix: s3://%s/%s", CENTRAL_BUCKET, data_prefix)

    restored = 0
    skipped = 0
    errors = 0

    for bkt, key in _iter_manifest_rows(manifest_key):
        if bkt != source_bucket:
            skipped += 1
            continue
        if prefix_filter and not key.startswith(prefix_filter):
            skipped += 1
            continue

        src_key = f"{data_prefix}{key}"
        dst_key = key

        if dry_run:
            restored += 1
            if restored >= max_objects:
                break
            continue

        try:
            s3.copy_object(
                Bucket=source_bucket,
                Key=dst_key,
                CopySource={"Bucket": CENTRAL_BUCKET, "Key": src_key},
                ServerSideEncryption="AES256",
            )
            restored += 1
        except Exception as e:
            logger.error(f"Error restaurando {dst_key} desde {src_key}: {e}")
            errors += 1

        if restored >= max_objects:
            break

    result = {
        "status": "DRY_RUN" if dry_run else "RESTORE_COMPLETED",
        "source_bucket": source_bucket,
        "criticality": criticality,
        "backup_type": backup_type,
        "generation": generation,
        "manifest_key": manifest_key,
        "data_prefix": data_prefix,
        "restored_count": restored,
        "skipped": skipped,
        "errors": errors,
        "max_objects": max_objects,
    }

    logger.info(json.dumps(result, indent=2))
    return result
