"""
Lambda function: filter_inventory
--------------------------------
Filtra el inventario de S3 para generar un manifiesto con los objetos que deben
respaldarse, según criticidad y checkpoint previo.
"""

import boto3
import os
import json
import gzip
import csv
import io
import uuid
import logging
from datetime import datetime, timezone
from typing import Dict, Optional

logger = logging.getLogger()
logger.setLevel(os.environ.get("LOG_LEVEL", "INFO").upper())

s3_client = boto3.client("s3")

# Bucket alternativo para guardar los manifiestos (sin KMS)
MANIFEST_BUCKET = os.environ.get("MANIFEST_BUCKET")
FORCE_FULL_ON_FIRST_RUN = os.environ.get("FORCE_FULL_ON_FIRST_RUN", "false").lower() == "true"
try:
    FALLBACK_MAX_OBJECTS = int(os.environ.get("FALLBACK_MAX_OBJECTS", "0") or 0)
except ValueError:
    FALLBACK_MAX_OBJECTS = 0
try:
    FALLBACK_TIME_LIMIT_SECONDS = int(os.environ.get("FALLBACK_TIME_LIMIT_SECONDS", "0") or 0)
except ValueError:
    FALLBACK_TIME_LIMIT_SECONDS = 0

# --- IMPLEMENTACIÓN REAL DE CHECKPOINTS ---
def read_checkpoint(bucket: str, source_bucket: str, backup_type: str) -> Optional[datetime]:
    """
    Lee la marca de tiempo del último checkpoint desde un archivo en S3.
    """
    checkpoint_key = f"checkpoints/{source_bucket}/{backup_type}.txt"
    try:
        logger.info(f"🔎 Leyendo checkpoint desde s3://{bucket}/{checkpoint_key}")
        response = s3_client.get_object(Bucket=bucket, Key=checkpoint_key)
        timestamp_str = response["Body"].read().decode("utf-8")
        checkpoint = datetime.fromisoformat(timestamp_str)
        logger.info(f"Checkpoint encontrado: {checkpoint.isoformat()}")
        return checkpoint
    except s3_client.exceptions.NoSuchKey:
        logger.warning(f"No se encontró checkpoint en s3://{bucket}/{checkpoint_key}. Se procesarán todos los objetos.")
        return None
    except Exception as e:
        logger.error(f"Error al leer el checkpoint: {e}", exc_info=True)
        return None


def write_checkpoint(bucket: str, source_bucket: str, backup_type: str, timestamp: datetime):
    """
    Escribe la marca de tiempo del checkpoint actual en un archivo en S3.
    """
    checkpoint_key = f"checkpoints/{source_bucket}/{backup_type}.txt"
    timestamp_str = timestamp.isoformat()
    try:
        logger.info(f"Escribiendo nuevo checkpoint en s3://{bucket}/{checkpoint_key} con fecha {timestamp_str}")
        s3_client.put_object(
            Bucket=bucket,
            Key=checkpoint_key,
            Body=timestamp_str.encode("utf-8")
        )
        logger.info("Checkpoint escrito correctamente.")
    except Exception as e:
        logger.error(f"Error al escribir el checkpoint: {e}", exc_info=True)

# -------------------------------------------------
# Tamaño mínimo de parte para multipart upload (6 MiB)
MIN_CHUNK_SIZE_BYTES = 6 * 1024 * 1024

# Prefijos permitidos por criticidad
try:
    ALLOWED_PREFIXES = json.loads(os.environ.get("ALLOWED_PREFIXES", "{}"))
except json.JSONDecodeError:
    ALLOWED_PREFIXES = {}

# --------------------------------------------------------------------
# Buscar el manifest.json más reciente
# --------------------------------------------------------------------
def find_latest_inventory_manifest(bucket: str, prefix: str) -> Optional[str]:
    """
    Busca y devuelve la clave del manifest.json más reciente dentro del prefijo.
    """
    logger.info(f"Buscando el manifiesto más reciente en s3://{bucket}/{prefix}")
    if not prefix.endswith("/"):
        prefix += "/"

    paginator = s3_client.get_paginator("list_objects_v2")
    latest_obj = None

    try:
        for page in paginator.paginate(Bucket=bucket, Prefix=prefix):
            for obj in page.get("Contents", []):
                if obj["Key"].endswith("manifest.json"):
                    if latest_obj is None or obj["LastModified"] > latest_obj["LastModified"]:
                        latest_obj = obj
        if latest_obj:
            logger.info(f"Manifiesto más reciente encontrado: {latest_obj['Key']}")
            return latest_obj["Key"]
        else:
            logger.warning(f"No se encontró manifest.json bajo el prefijo {prefix}")
            return None
    except Exception as e:
        logger.error(f"Error al listar manifiestos en s3://{bucket}/{prefix}: {e}", exc_info=True)
        return None

# --------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------
def get_column_indices(schema_string: str) -> Dict[str, int]:
    """Obtiene los índices de las columnas necesarias del schema del inventario."""
    columns = [c.strip() for c in schema_string.split(",")]
    required = ["Bucket", "Key", "LastModifiedDate"]
    for field in required:
        if field not in columns:
            raise ValueError(f"Inventory schema missing required field: {field}")
    return {
        "bucket": columns.index("Bucket"),
        "key": columns.index("Key"),
        "last_modified": columns.index("LastModifiedDate"),
    }

# --------------------------------------------------------------------
# Genera el manifiesto CSV con los objetos a respaldar
# --------------------------------------------------------------------
def stream_inventory_to_manifest(
    backup_bucket: str,
    manifest: Dict,
    source_bucket: str,
    backup_type: str,
    criticality: str,
    last_checkpoint: Optional[datetime],
) -> Optional[Dict[str, str]]:
    """Lee los data files del inventario y genera un manifiesto CSV con los objetos cambiados."""
    temp_manifest_key = f"manifests/temp/{source_bucket}-{uuid.uuid4()}.csv"

    # Si existe un bucket auxiliar para manifiestos, se usa (sin KMS)
    target_bucket = backup_bucket

    mpu = s3_client.create_multipart_upload(
        Bucket=target_bucket,
        Key=temp_manifest_key,
        ServerSideEncryption='AES256'
    )

    upload_id = mpu["UploadId"]
    parts = []
    part_number = 1
    buffer = io.StringIO()
    writer = csv.writer(buffer)
    objects_found = 0

    prefixes = ALLOWED_PREFIXES.get(criticality, [])
    indices = get_column_indices(manifest["fileSchema"])
    idx_bucket = indices["bucket"]
    idx_key = indices["key"]
    idx_last_modified = indices["last_modified"]

    try:
        for file_info in manifest.get("files", []):
            data_key = file_info.get("key")
            if not data_key:
                logger.warning("Saltando entrada de archivo vacía en el manifiesto.")
                continue

            data_bucket = backup_bucket
            duplicate_pattern = f"/{source_bucket}//{source_bucket}/"
            if duplicate_pattern in data_key:
                correct_segment = f"/{source_bucket}/"
                data_key = data_key.replace(duplicate_pattern, correct_segment)
            data_key = data_key.replace('//', '/')

            logger.info(f"Leyendo data file del inventario: s3://{data_bucket}/{data_key}")

            try:
                obj = s3_client.get_object(Bucket=data_bucket, Key=data_key)
            except s3_client.exceptions.NoSuchKey:
                logger.warning(f"Archivo de datos del inventario no encontrado: s3://{data_bucket}/{data_key}")
                continue

            with gzip.GzipFile(fileobj=obj["Body"]) as gz:
                reader = csv.reader(io.TextIOWrapper(gz))
                for i, row in enumerate(reader):
                    object_bucket = row[idx_bucket]
                    object_key = row[idx_key]
                    last_modified_str = row[idx_last_modified]

                    try:
                        last_mod_dt = datetime.fromisoformat(last_modified_str.replace("Z", "+00:00"))
                    except Exception as e:
                        logger.warning(f"Error procesando fecha '{last_modified_str}': {e}")
                        continue

                    if prefixes and not any(object_key.startswith(p) for p in prefixes):
                        continue
                    if last_checkpoint and last_mod_dt <= last_checkpoint:
                        continue

                    writer.writerow([object_bucket, object_key])
                    objects_found += 1

                    if buffer.tell() >= MIN_CHUNK_SIZE_BYTES:
                        part = s3_client.upload_part(
                            Bucket=target_bucket,
                            Key=temp_manifest_key,
                            PartNumber=part_number,
                            UploadId=upload_id,
                            Body=buffer.getvalue().encode("utf-8"),
                        )
                        parts.append({"PartNumber": part_number, "ETag": part["ETag"]})
                        part_number += 1
                        buffer = io.StringIO()
                        writer = csv.writer(buffer)

        if buffer.tell() > 0:
            part = s3_client.upload_part(
                Bucket=target_bucket,
                Key=temp_manifest_key,
                PartNumber=part_number,
                UploadId=upload_id,
                Body=buffer.getvalue().encode("utf-8"),
            )
            parts.append({"PartNumber": part_number, "ETag": part["ETag"]})

        if objects_found == 0:
            logger.info("No se encontraron objetos nuevos. Abortando subida.")
            s3_client.abort_multipart_upload(Bucket=target_bucket, Key=temp_manifest_key, UploadId=upload_id)
            return None

        result = s3_client.complete_multipart_upload(
            Bucket=target_bucket,
            Key=temp_manifest_key,
            UploadId=upload_id,
            MultipartUpload={"Parts": parts},
        )

        logger.info(f"Manifiesto completado con {objects_found} objetos en s3://{target_bucket}/{temp_manifest_key}")
        return {
            "bucket": target_bucket,
            "key": temp_manifest_key,
            "etag": result["ETag"].strip('"'),
        }

    except Exception as e:
        logger.error(f"Error durante el streaming del inventario: {e}", exc_info=True)
        s3_client.abort_multipart_upload(Bucket=target_bucket, Key=temp_manifest_key, UploadId=upload_id)
        raise


# --------------------------------------------------------------------
# Fallback: generar manifiesto listando directamente el bucket origen
# --------------------------------------------------------------------
def generate_manifest_from_listing(
    backup_bucket: str,
    source_bucket: str,
    backup_type: str,
    criticality: str,
    last_checkpoint: Optional[datetime],
) -> Optional[Dict[str, str]]:
    """Genera un manifiesto CSV recorriendo objetos del bucket origen usando ListObjectsV2.

    Se respeta ALLOWED_PREFIXES por criticidad y, si hay checkpoint, solo se incluyen
    objetos con LastModified posterior al checkpoint.
    """
    temp_manifest_key = f"manifests/temp/{source_bucket}-{uuid.uuid4()}.csv"
    target_bucket = backup_bucket

    mpu = s3_client.create_multipart_upload(
        Bucket=target_bucket,
        Key=temp_manifest_key,
        ServerSideEncryption='AES256'
    )

    upload_id = mpu["UploadId"]
    parts = []
    part_number = 1
    buffer = io.StringIO()
    writer = csv.writer(buffer)
    objects_found = 0

    prefixes = ALLOWED_PREFIXES.get(criticality, [])
    prefixes = prefixes if prefixes else [""]

    try:
        start_time = datetime.now(timezone.utc)
        for pfx in prefixes:
            kwargs = {"Bucket": source_bucket}
            if pfx:
                kwargs["Prefix"] = pfx

            paginator = s3_client.get_paginator("list_objects_v2")
            for page in paginator.paginate(**kwargs):
                for obj in page.get("Contents", []):
                    key = obj["Key"]
                    last_mod = obj.get("LastModified")
                    if last_checkpoint and last_mod and last_mod <= last_checkpoint:
                        continue

                    writer.writerow([source_bucket, key])
                    objects_found += 1

                    # Límites opcionales
                    if FALLBACK_MAX_OBJECTS and objects_found >= FALLBACK_MAX_OBJECTS:
                        logger.info("Fallback listing: alcanzado límite de objetos (%d).", FALLBACK_MAX_OBJECTS)
                        break
                    if FALLBACK_TIME_LIMIT_SECONDS and (datetime.now(timezone.utc) - start_time).total_seconds() >= FALLBACK_TIME_LIMIT_SECONDS:
                        logger.info("Fallback listing: alcanzado límite de tiempo (%ds).", FALLBACK_TIME_LIMIT_SECONDS)
                        break

                    if buffer.tell() >= MIN_CHUNK_SIZE_BYTES:
                        part = s3_client.upload_part(
                            Bucket=target_bucket,
                            Key=temp_manifest_key,
                            PartNumber=part_number,
                            UploadId=upload_id,
                            Body=buffer.getvalue().encode("utf-8"),
                        )
                        parts.append({"PartNumber": part_number, "ETag": part["ETag"]})
                        part_number += 1
                        buffer = io.StringIO()
                        writer = csv.writer(buffer)

        if buffer.tell() > 0:
            part = s3_client.upload_part(
                Bucket=target_bucket,
                Key=temp_manifest_key,
                PartNumber=part_number,
                UploadId=upload_id,
                Body=buffer.getvalue().encode("utf-8"),
            )
            parts.append({"PartNumber": part_number, "ETag": part["ETag"]})

        if objects_found == 0:
            logger.info("Fallback listing: no se encontraron objetos.")
            s3_client.abort_multipart_upload(Bucket=target_bucket, Key=temp_manifest_key, UploadId=upload_id)
            return None

        result = s3_client.complete_multipart_upload(
            Bucket=target_bucket,
            Key=temp_manifest_key,
            UploadId=upload_id,
            MultipartUpload={"Parts": parts},
        )

        logger.info(
            f"Fallback manifest completado con {objects_found} objetos en s3://{target_bucket}/{temp_manifest_key}"
        )
        return {"bucket": target_bucket, "key": temp_manifest_key, "etag": result["ETag"].strip('"')}

    except Exception as e:
        logger.error(f"Error durante fallback listing: {e}", exc_info=True)
        s3_client.abort_multipart_upload(Bucket=target_bucket, Key=temp_manifest_key, UploadId=upload_id)
        raise

# --------------------------------------------------------------------
# Handler principal
# --------------------------------------------------------------------
def lambda_handler(event: Dict, context) -> Dict:
    try:
        backup_bucket = event["backup_bucket"]
        source_bucket = event["source_bucket"]
        backup_type = event["backup_type"]
        inventory_prefix = event["inventory_key"]
        criticality = event.get("criticality", "MenosCritico")

        logger.info(f"Iniciando filtrado de inventario para {source_bucket} (tipo={backup_type}, crit={criticality})")

        manifest_key = find_latest_inventory_manifest(backup_bucket, inventory_prefix)
        last_cp = read_checkpoint(backup_bucket, source_bucket, backup_type)

        # Forzar FULL en primera corrida si se solicita y el backup_type entrante es incremental
        effective_backup_type = backup_type
        if backup_type == "incremental" and last_cp is None and FORCE_FULL_ON_FIRST_RUN:
            logger.info("Forzando FULL en primera corrida (sin checkpoint previo).")
            effective_backup_type = "full"

        if manifest_key:
            manifest_obj = s3_client.get_object(Bucket=backup_bucket, Key=manifest_key)
            manifest_data = json.loads(manifest_obj["Body"].read().decode("utf-8"))
            manifest_info = stream_inventory_to_manifest(
                backup_bucket, manifest_data, source_bucket, effective_backup_type, criticality, None if effective_backup_type == "full" else last_cp
            )
        else:
            logger.warning(
                f"No hay inventario aún para {source_bucket}. Usando fallback de ListObjectsV2 para generar manifiesto inicial."
            )
            manifest_info = generate_manifest_from_listing(
                backup_bucket, source_bucket, effective_backup_type, criticality, None if effective_backup_type == "full" else last_cp
            )

        if not manifest_info:
            logger.info("No hay objetos nuevos para respaldar.")
            return {"status": "EMPTY", "reason": "No new objects"}

        # Escribimos checkpoint al final; si fue FULL forzado, marca tiempo actual
        write_checkpoint(backup_bucket, source_bucket, effective_backup_type if FORCE_FULL_ON_FIRST_RUN else backup_type, datetime.now(timezone.utc))

        logger.info("Proceso completado correctamente. Manifiesto generado.")
        return {
            "status": "SUCCESS",
            "manifest": manifest_info,
            "manifest_key": manifest_key,
            "source_bucket": source_bucket,
            "backup_type": effective_backup_type,
            "criticality": criticality,
        }

    except Exception as e:
        logger.error(f"Error fatal en filter_inventory: {e}", exc_info=True)
        return {"status": "FAILED", "reason": str(e)}
