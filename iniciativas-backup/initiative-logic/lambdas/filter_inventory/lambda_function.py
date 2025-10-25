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

# Configuración - Un solo bucket central
BACKUP_BUCKET = os.environ.get("BACKUP_BUCKET")  
FORCE_FULL_ON_FIRST_RUN = os.environ.get("FORCE_FULL_ON_FIRST_RUN", "false").lower() == "true"

try:
    FALLBACK_MAX_OBJECTS = int(os.environ.get("FALLBACK_MAX_OBJECTS", "0") or 0)
except ValueError:
    FALLBACK_MAX_OBJECTS = 0

try:
    FALLBACK_TIME_LIMIT_SECONDS = int(os.environ.get("FALLBACK_TIME_LIMIT_SECONDS", "0") or 0)
except ValueError:
    FALLBACK_TIME_LIMIT_SECONDS = 0

# Prefijos permitidos por criticidad
try:
    ALLOWED_PREFIXES = json.loads(os.environ.get("ALLOWED_PREFIXES", "{}"))
except json.JSONDecodeError:
    ALLOWED_PREFIXES = {}

# Tamaño mínimo de parte para multipart upload (6 MiB)
MIN_CHUNK_SIZE_BYTES = 6 * 1024 * 1024

# ============================================================================
# OPTIMIZACIÓN: Validación de edad de inventory
# ============================================================================
MAX_INVENTORY_AGE_DAYS = 10  # Advertir si inventory tiene más de 10 días


# ============================================================================
# CHECKPOINT MANAGEMENT - Implementación única
# ============================================================================

def read_checkpoint(bucket: str, source_bucket: str, backup_type: str) -> Optional[datetime]:
    """Lee la marca de tiempo del último checkpoint desde un archivo en S3."""
    checkpoint_key = f"checkpoints/{source_bucket}/{backup_type}.txt"
    try:
        logger.info(f"Leyendo checkpoint desde s3://{bucket}/{checkpoint_key}")
        response = s3_client.get_object(Bucket=bucket, Key=checkpoint_key)
        timestamp_str = response["Body"].read().decode("utf-8")
        checkpoint = datetime.fromisoformat(timestamp_str)
        logger.info(f"Checkpoint encontrado: {checkpoint.isoformat()}")
        return checkpoint
    except s3_client.exceptions.NoSuchKey:
        logger.warning(f"No se encontró checkpoint. Primera ejecución o backup completo.")
        return None
    except Exception as e:
        logger.error(f"Error al leer checkpoint: {e}", exc_info=True)
        return None


def write_checkpoint(bucket: str, source_bucket: str, backup_type: str, timestamp: datetime):
    """Escribe la marca de tiempo del checkpoint actual en un archivo en S3."""
    checkpoint_key = f"checkpoints/{source_bucket}/{backup_type}.txt"
    timestamp_str = timestamp.isoformat()
    try:
        logger.info(f"Escribiendo checkpoint: s3://{bucket}/{checkpoint_key} = {timestamp_str}")
        s3_client.put_object(
            Bucket=bucket,
            Key=checkpoint_key,
            Body=timestamp_str.encode("utf-8"),
            ServerSideEncryption="AES256"  
        )
        logger.info("Checkpoint guardado correctamente.")
    except Exception as e:
        logger.error(f"Error al escribir checkpoint: {e}", exc_info=True)


# ============================================================================
# INVENTORY MANIFEST DISCOVERY - MEJORADO CON VALIDACIÓN DE EDAD
# ============================================================================

def find_latest_inventory_manifest(bucket: str, prefix: str) -> Optional[str]:
    """
    Busca y devuelve la clave del manifest.json más reciente dentro del prefijo.
    NUEVO: Valida la edad del inventory y advierte si está muy desactualizado.
    """
    logger.info(f"Buscando manifiesto de inventario en s3://{bucket}/{prefix}")
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
            #NUEVO: Validar edad del inventory
            age_days = (datetime.now(timezone.utc) - latest_obj["LastModified"]).days
            age_hours = (datetime.now(timezone.utc) - latest_obj["LastModified"]).seconds // 3600
            
            logger.info(f"Inventory encontrado: {latest_obj['Key']}")
            logger.info(f"Edad: {age_days} días, {age_hours} horas")
            
            if age_days > MAX_INVENTORY_AGE_DAYS:
                logger.warning(
                    f"ADVERTENCIA: Inventory muy antiguo ({age_days} días). "
                    f"Puede estar desactualizado para full backup. "
                    f"Verificar que S3 Inventory esté generándose correctamente."
                )
            elif age_days > 7:
                logger.info(f"Inventory de hace {age_days} días (aceptable para Weekly)")
            else:
                logger.info(f"Inventory reciente ({age_days} días)")
            
            return latest_obj["Key"]
        else:
            logger.warning(f"No se encontró manifest.json en {prefix}")
            return None
    except Exception as e:
        logger.error(f"Error al buscar manifiestos: {e}", exc_info=True)
        return None


# ============================================================================
# MANIFEST GENERATION FROM INVENTORY
# ============================================================================

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

    logger.info(f"Generando manifiesto temporal en s3://{backup_bucket}/{temp_manifest_key}")

    # Crear multipart upload con AES256
    mpu = s3_client.create_multipart_upload(
        Bucket=backup_bucket,
        Key=temp_manifest_key,
        ServerSideEncryption='AES256' 
    )

    upload_id = mpu["UploadId"]
    parts = []
    part_number = 1
    buffer = io.StringIO()
    writer = csv.writer(buffer)
    objects_found = 0

        # ========================================================================
    # APLICAR FILTROS DE PREFIJOS (solo si no es sweep completo)
    # ========================================================================
    # Los sweeps (full backups) ignoran allowed_prefixes para garantizar 
    # cobertura total. Solo aplican filtros los incrementales.

    ignore_allowed_prefixes = False
    # Verificar si viene desde un sweep que debe ignorar filtros
    # (esto se pasa desde el schedule en main.tf)
    # En el contexto de esta lambda, no tenemos acceso directo al payload del schedule,
    # pero podemos inferirlo: si backup_type == "full", asumimos sweep completo

    if backup_type == "full":
        ignore_allowed_prefixes = True
        prefixes = []  # No aplicar filtros de prefijos en sweeps
        logger.info(f"🔓 Modo SWEEP COMPLETO: Ignorando allowed_prefixes para {source_bucket}")
    else:
        # Incrementales: aplicar filtros normales
        prefixes = ALLOWED_PREFIXES.get(criticality, [])
        if prefixes:
            logger.info(f"🔒 Modo INCREMENTAL: Aplicando prefijos permitidos: {prefixes}")
        else:
            logger.info(f"🔓 Modo INCREMENTAL sin filtros: Copiando todos los objetos")
    indices = get_column_indices(manifest["fileSchema"])
    idx_bucket = indices["bucket"]
    idx_key = indices["key"]
    idx_last_modified = indices["last_modified"]

    try:
        for file_info in manifest.get("files", []):
            data_key = file_info.get("key")
            if not data_key:
                logger.warning("Entrada de archivo vacía en manifiesto, saltando...")
                continue

            # Limpiar rutas duplicadas
            duplicate_pattern = f"/{source_bucket}//{source_bucket}/"
            if duplicate_pattern in data_key:
                correct_segment = f"/{source_bucket}/"
                data_key = data_key.replace(duplicate_pattern, correct_segment)
            data_key = data_key.replace('//', '/')

            logger.info(f"Leyendo data file: s3://{backup_bucket}/{data_key}")

            try:
                obj = s3_client.get_object(Bucket=backup_bucket, Key=data_key)
            except s3_client.exceptions.NoSuchKey:
                logger.warning(f"Archivo no encontrado: s3://{backup_bucket}/{data_key}")
                continue

            with gzip.GzipFile(fileobj=obj["Body"]) as gz:
                reader = csv.reader(io.TextIOWrapper(gz))
                for row in reader:
                    object_bucket = row[idx_bucket]
                    object_key = row[idx_key]
                    last_modified_str = row[idx_last_modified]

                    try:
                        last_mod_dt = datetime.fromisoformat(last_modified_str.replace("Z", "+00:00"))
                    except Exception as e:
                        logger.warning(f"Error procesando fecha '{last_modified_str}': {e}")
                        continue

                    # Filtrar por prefijos permitidos
                    if prefixes and not any(object_key.startswith(p) for p in prefixes):
                        continue
                    
                    # Filtrar por checkpoint (solo para incrementales)
                    if last_checkpoint and last_mod_dt <= last_checkpoint:
                        continue

                    writer.writerow([object_bucket, object_key])
                    objects_found += 1

                    # Subir parte cuando se alcanza el tamaño mínimo
                    if buffer.tell() >= MIN_CHUNK_SIZE_BYTES:
                        part = s3_client.upload_part(
                            Bucket=backup_bucket,
                            Key=temp_manifest_key,
                            PartNumber=part_number,
                            UploadId=upload_id,
                            Body=buffer.getvalue().encode("utf-8"),
                        )
                        parts.append({"PartNumber": part_number, "ETag": part["ETag"]})
                        part_number += 1
                        buffer = io.StringIO()
                        writer = csv.writer(buffer)

        # Subir la última parte si hay datos
        if buffer.tell() > 0:
            part = s3_client.upload_part(
                Bucket=backup_bucket,
                Key=temp_manifest_key,
                PartNumber=part_number,
                UploadId=upload_id,
                Body=buffer.getvalue().encode("utf-8"),
            )
            parts.append({"PartNumber": part_number, "ETag": part["ETag"]})

        if objects_found == 0:
            logger.info("No se encontraron objetos nuevos. Abortando subida.")
            s3_client.abort_multipart_upload(
                Bucket=backup_bucket, 
                Key=temp_manifest_key, 
                UploadId=upload_id
            )
            return None

        # Completar multipart upload
        result = s3_client.complete_multipart_upload(
            Bucket=backup_bucket,
            Key=temp_manifest_key,
            UploadId=upload_id,
            MultipartUpload={"Parts": parts},
        )

        logger.info(f"Manifiesto completado: {objects_found} objetos en s3://{backup_bucket}/{temp_manifest_key}")
        
        return {
            "bucket": backup_bucket,
            "key": temp_manifest_key,
            "etag": result["ETag"].strip('"'),
        }

    except Exception as e:
        logger.error(f"Error durante streaming del inventario: {e}", exc_info=True)
        s3_client.abort_multipart_upload(
            Bucket=backup_bucket, 
            Key=temp_manifest_key, 
            UploadId=upload_id
        )
        raise


# ============================================================================
# FALLBACK: MANIFEST FROM DIRECT LISTING - MEJORADO
# ============================================================================

def generate_manifest_from_listing(
    backup_bucket: str,
    source_bucket: str,
    backup_type: str,
    criticality: str,
    last_checkpoint: Optional[datetime],
) -> Optional[Dict[str, str]]:
    """
    Genera un manifiesto CSV recorriendo objetos del bucket origen usando ListObjectsV2.
    Fallback para cuando aún no existe inventario S3.
    
    IMPORTANTE: Solo debería usarse en la PRIMERA corrida. Después de eso, si no hay
    inventory disponible, el proceso debería fallar para evitar costes de ListObjectsV2.
    """
    
    logger.warning("FALLBACK MODE: Generando manifiesto por listado directo")
    logger.warning("    Nota: Este método es costoso y solo debería usarse en primera corrida")
    
    temp_manifest_key = f"manifests/temp/{source_bucket}-{uuid.uuid4()}.csv"

    mpu = s3_client.create_multipart_upload(
        Bucket=backup_bucket,
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
                    
                    # Filtrar por checkpoint
                    if last_checkpoint and last_mod and last_mod <= last_checkpoint:
                        continue

                    writer.writerow([source_bucket, key])
                    objects_found += 1

                    # Límites de seguridad
                    if FALLBACK_MAX_OBJECTS and objects_found >= FALLBACK_MAX_OBJECTS:
                        logger.warning(f"Alcanzado límite de objetos: {FALLBACK_MAX_OBJECTS}")
                        break
                    
                    if FALLBACK_TIME_LIMIT_SECONDS:
                        elapsed = (datetime.now(timezone.utc) - start_time).total_seconds()
                        if elapsed >= FALLBACK_TIME_LIMIT_SECONDS:
                            logger.warning(f"Alcanzado límite de tiempo: {FALLBACK_TIME_LIMIT_SECONDS}s")
                            break

                    # Subir parte cuando se alcanza el tamaño mínimo
                    if buffer.tell() >= MIN_CHUNK_SIZE_BYTES:
                        part = s3_client.upload_part(
                            Bucket=backup_bucket,
                            Key=temp_manifest_key,
                            PartNumber=part_number,
                            UploadId=upload_id,
                            Body=buffer.getvalue().encode("utf-8"),
                        )
                        parts.append({"PartNumber": part_number, "ETag": part["ETag"]})
                        part_number += 1
                        buffer = io.StringIO()
                        writer = csv.writer(buffer)

        # Subir última parte
        if buffer.tell() > 0:
            part = s3_client.upload_part(
                Bucket=backup_bucket,
                Key=temp_manifest_key,
                PartNumber=part_number,
                UploadId=upload_id,
                Body=buffer.getvalue().encode("utf-8"),
            )
            parts.append({"PartNumber": part_number, "ETag": part["ETag"]})

        if objects_found == 0:
            logger.info("Fallback: No se encontraron objetos.")
            s3_client.abort_multipart_upload(
                Bucket=backup_bucket, 
                Key=temp_manifest_key, 
                UploadId=upload_id
            )
            return None

        result = s3_client.complete_multipart_upload(
            Bucket=backup_bucket,
            Key=temp_manifest_key,
            UploadId=upload_id,
            MultipartUpload={"Parts": parts},
        )

        logger.info(f"Fallback completado: {objects_found} objetos en s3://{backup_bucket}/{temp_manifest_key}")
        
        return {
            "bucket": backup_bucket,
            "key": temp_manifest_key,
            "etag": result["ETag"].strip('"')
        }

    except Exception as e:
        logger.error(f"Error durante fallback: {e}", exc_info=True)
        s3_client.abort_multipart_upload(
            Bucket=backup_bucket, 
            Key=temp_manifest_key, 
            UploadId=upload_id
        )
        raise


# ============================================================================
# LAMBDA HANDLER - MEJORADO CON VALIDACIÓN
# ============================================================================

def lambda_handler(event: Dict, context) -> Dict:
    """
    Handler principal para filtrar inventario y generar manifiestos.
    MEJORADO: Valida edad de inventory y evita fallback innecesario.
    """
    try:
        backup_bucket = event["backup_bucket"]
        source_bucket = event["source_bucket"]
        backup_type = event["backup_type"]
        inventory_prefix = event["inventory_key"]
        criticality = event.get("criticality", "MenosCritico")

        logger.info("="*80)
        logger.info(f"Iniciando filter_inventory")
        logger.info(f"   Source: {source_bucket}")
        logger.info(f"   Tipo: {backup_type}")
        logger.info(f"   Criticidad: {criticality}")
        logger.info("="*80)

        # Buscar inventario existente (CON VALIDACIÓN DE EDAD)
        manifest_key = find_latest_inventory_manifest(backup_bucket, inventory_prefix)
        
        # Leer checkpoint
        last_cp = read_checkpoint(backup_bucket, source_bucket, backup_type)

        # Determinar tipo efectivo de backup
        effective_backup_type = backup_type
        if backup_type == "incremental" and last_cp is None and FORCE_FULL_ON_FIRST_RUN:
            logger.info("Primera corrida: forzando FULL backup")
            effective_backup_type = "full"

        # Si es incremental, no hay checkpoint y NO queremos forzar full:
        # sembrar checkpoint y salir sin copiar todo (evita 'full' involuntario)
        if backup_type == "incremental" and last_cp is None and not FORCE_FULL_ON_FIRST_RUN:
            now = datetime.now(timezone.utc)
            write_checkpoint(backup_bucket, source_bucket, "incremental", now)
            logger.info(
                "Primera corrida incremental sin checkpoint: se siembra checkpoint y no se copia contenido."
            )
            return {
                "status": "EMPTY",
                "reason": "First incremental run seeded checkpoint without full copy",
                "source_bucket": source_bucket,
            }

        # Generar manifiesto
        if manifest_key:
            logger.info("Usando inventario S3 existente")
            manifest_obj = s3_client.get_object(Bucket=backup_bucket, Key=manifest_key)
            manifest_data = json.loads(manifest_obj["Body"].read().decode("utf-8"))
            
            manifest_info = stream_inventory_to_manifest(
                backup_bucket, 
                manifest_data, 
                source_bucket, 
                effective_backup_type, 
                criticality, 
                None if effective_backup_type == "full" else last_cp
            )
        else:
            #Validar si es realmente primera corrida
            if last_cp is None:
                logger.warning(
                    "No hay inventario disponible pero es PRIMERA CORRIDA. "
                    "Usando fallback con ListObjectsV2."
                )
                manifest_info = generate_manifest_from_listing(
                    backup_bucket, 
                    source_bucket, 
                    effective_backup_type, 
                    criticality, 
                    None if effective_backup_type == "full" else last_cp
                )
            else:
                # NO es primera corrida y no hay inventory: usar fallback acotado por checkpoint
                logger.warning(
                    "Inventory no disponible y NO es primera corrida. "
                    "Usando fallback con ListObjectsV2 limitado por checkpoint."
                )
                manifest_info = generate_manifest_from_listing(
                    backup_bucket,
                    source_bucket,
                    effective_backup_type,
                    criticality,
                    last_cp
                )

        if not manifest_info:
            logger.info("No hay objetos nuevos para respaldar.")
            return {
                "status": "EMPTY", 
                "reason": "No new objects",
                "source_bucket": source_bucket
            }

        # Guardar checkpoint al final
        checkpoint_type = effective_backup_type if FORCE_FULL_ON_FIRST_RUN else backup_type
        write_checkpoint(backup_bucket, source_bucket, checkpoint_type, datetime.now(timezone.utc))

        logger.info("="*80)
        logger.info("Proceso completado exitosamente")
        logger.info(f"   Manifiesto: s3://{manifest_info['bucket']}/{manifest_info['key']}")
        logger.info("="*80)

        return {
            "status": "SUCCESS",
            "manifest": manifest_info,
            "manifest_key": manifest_key,
            "source_bucket": source_bucket,
            "backup_type": effective_backup_type,
            "criticality": criticality,
        }

    except Exception as e:
        logger.error("="*80)
        logger.error(f"ERROR FATAL en filter_inventory: {e}")
        logger.error("="*80, exc_info=True)
        return {
            "status": "FAILED", 
            "reason": str(e),
            "source_bucket": event.get("source_bucket", "unknown")
        }
