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


def _latest_timestamp_prefix(base_prefix: str) -> Optional[str]:
    """Devuelve el subprefijo 'timestamp=YYYYMMDD-HHMMSS' mas reciente bajo base_prefix."""
    paginator = s3.get_paginator("list_objects_v2")
    latest_ts: Optional[str] = None
    try:
        for page in paginator.paginate(Bucket=CENTRAL_BUCKET, Prefix=base_prefix, Delimiter="/"):
            for cp in page.get("CommonPrefixes", []):
                p = cp.get("Prefix", "")
                if "timestamp=" in p:
                    ts = p.rstrip("/").split("timestamp=")[-1]
                    if latest_ts is None or ts > latest_ts:
                        latest_ts = ts
        if latest_ts:
            return f"{base_prefix}timestamp={latest_ts}/"
        return None
    except Exception as e:
        logger.error(f"Error listando prefijos de timestamp en s3://{CENTRAL_BUCKET}/{base_prefix}: {e}")
        return None


def _resolve_paths(source_bucket: str, criticality: str, backup_type: str, generation: str,
                   year: str, month: str, day: str, hour: str) -> Tuple[str, str]:
    """Calcula los prefijos de manifest y data para un conjunto de parametros."""
    manifests_prefix = (
        f"manifests/criticality={criticality}/backup_type={backup_type}/"
        f"initiative={INITIATIVE}/bucket={source_bucket}/"
        f"year={year}/month={month}/day={day}/hour={hour}/"
    )
    data_base_prefix = (
        f"backup/criticality={criticality}/backup_type={backup_type}/"
        f"generation={generation}/initiative={INITIATIVE}/bucket={source_bucket}/"
        f"year={year}/month={month}/day={day}/hour={hour}/"
    )
    return manifests_prefix, data_base_prefix


def _find_latest_manifest(manif_prefix: str) -> Optional[str]:
    """Busca el manifest mas reciente (por nombre) bajo un prefijo de manifests."""
    paginator = s3.get_paginator("list_objects_v2")
    latest_key: Optional[str] = None
    for page in paginator.paginate(Bucket=CENTRAL_BUCKET, Prefix=manif_prefix):
        for obj in page.get("Contents", []):
            key = obj["Key"]
            if key.endswith(".csv") and (latest_key is None or key > latest_key):
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
        manif_prefix, data_base = _resolve_paths(
            source_bucket, criticality, backup_type, generation, year, month, day, hour
        )
        manifest_key = _find_latest_manifest(manif_prefix)
        if not manifest_key:
            raise RuntimeError(
                f"No se encontro manifest bajo s3://{CENTRAL_BUCKET}/{manif_prefix}. "
                f"Verifica parametros (bucket/criticidad/tipo/generacion/fecha)."
            )
        data_prefix = _latest_timestamp_prefix(data_base)
        if not data_prefix:
            raise RuntimeError(
                f"No se encontro prefijo de datos con timestamp bajo s3://{CENTRAL_BUCKET}/{data_base}."
            )
    else:
        # Buscar la ultima combinacion disponible recorriendo de forma descendente por fecha
        paginator = s3.get_paginator("list_objects_v2")
        latest_combo: Optional[Tuple[str, str, str, str]] = None
        prefix_root = f"manifests/criticality={criticality}/backup_type={backup_type}/initiative={INITIATIVE}/bucket={source_bucket}/"
        for page in paginator.paginate(Bucket=CENTRAL_BUCKET, Prefix=prefix_root, Delimiter="/"):
            for ycp in page.get("CommonPrefixes", []):
                y = ycp["Prefix"].split("year=")[-1].strip("/")
                # List month
                for mpage in s3.get_paginator("list_objects_v2").paginate(Bucket=CENTRAL_BUCKET, Prefix=f"{ycp['Prefix']}", Delimiter="/"):
                    for mcp in mpage.get("CommonPrefixes", []):
                        m = mcp["Prefix"].split("month=")[-1].strip("/")
                        for dpage in s3.get_paginator("list_objects_v2").paginate(Bucket=CENTRAL_BUCKET, Prefix=f"{mcp['Prefix']}", Delimiter="/"):
                            for dcp in dpage.get("CommonPrefixes", []):
                                d = dcp["Prefix"].split("day=")[-1].strip("/")
                                for hpage in s3.get_paginator("list_objects_v2").paginate(Bucket=CENTRAL_BUCKET, Prefix=f"{dcp['Prefix']}", Delimiter="/"):
                                    for hcp in hpage.get("CommonPrefixes", []):
                                        h = hcp["Prefix"].split("hour=")[-1].strip("/")
                                        combo = (y, m, d, h)
                                        if latest_combo is None or combo > latest_combo:
                                            latest_combo = combo
                                            manifest_key = _find_latest_manifest(hcp["Prefix"])
                                            # data base path parallels manifests hour
                                            data_prefix = _latest_timestamp_prefix(
                                                f"backup/criticality={criticality}/backup_type={backup_type}/generation={generation}/initiative={INITIATIVE}/bucket={source_bucket}/year={y}/month={m}/day={d}/hour={h}/"
                                            )
        if manifest_key is None:
            raise RuntimeError("No se encontro ningun manifest para los parametros indicados")

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
