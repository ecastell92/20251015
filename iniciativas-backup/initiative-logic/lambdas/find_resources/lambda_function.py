import boto3
import os
import logging
from botocore.exceptions import ClientError
from typing import Dict, Any, List

# --- Configuración global ---
logger = logging.getLogger()
logger.setLevel(os.environ.get("LOG_LEVEL", "INFO").upper())

s3_client = boto3.client("s3")
resource_tag_client = boto3.client("resourcegroupstaggingapi")

BACKUP_TAG_KEY = "BackupEnabled"
CRITICALITY_TAG_KEY = "BackupCriticality"
DEFAULT_CRITICALITY = "MenosCritico"
INVENTORY_ID = "AutoBackupInventory"
SQS_QUEUE_ARN = os.environ["SQS_QUEUE_ARN"]

# --- Funciones auxiliares ---

def create_inventory_configuration(bucket_name: str, central_bucket_name: str, central_account_id: str):
    """Crea la configuración de inventario en el bucket origen."""
    logger.info(f"Creando configuración de inventario '{INVENTORY_ID}' para '{bucket_name}'.")

    # Tomamos el KMS opcionalmente
    kms_key_arn = os.environ.get("CENTRAL_KMS_KEY_ARN")

    # Construimos el bloque de destino
    s3_destination = {
        "AccountId": central_account_id,
        "Bucket": f"arn:aws:s3:::{central_bucket_name}",
        "Format": "CSV",
        "Prefix": "inventory-source",
    }

    # Añadimos cifrado solo si hay clave KMS
    if kms_key_arn:
        s3_destination["Encryption"] = {"SSEKMS": {"KeyId": kms_key_arn}}

    try:
        s3_client.put_bucket_inventory_configuration(
            Bucket=bucket_name,
            Id=INVENTORY_ID,
            InventoryConfiguration={
                "Id": INVENTORY_ID,
                "IsEnabled": True,
                "IncludedObjectVersions": "Current",
                "OptionalFields": [
                    "Size", "LastModifiedDate", "StorageClass", "ETag",
                    "EncryptionStatus", "ReplicationStatus", "IsMultipartUploaded"
                ],
                # Ajustado a Daily para permitir barridos definitivos cada 12h
                "Schedule": {"Frequency": "Daily"},
                "Destination": {"S3BucketDestination": s3_destination},
            },
        )
        logger.info(f"Inventario '{INVENTORY_ID}' creado correctamente en '{bucket_name}'.")
    except ClientError as e:
        logger.error(f"Error al crear inventario en '{bucket_name}': {e}")
        raise


def ensure_inventory_exists(bucket_name: str, central_bucket_name: str, central_account_id: str):
    """Asegura que el inventario exista y esté actualizado en el bucket origen."""
    try:
        # CAMBIO: Verificar configuración actual
        existing = s3_client.get_bucket_inventory_configuration(Bucket=bucket_name, Id=INVENTORY_ID)
        current_freq = existing["InventoryConfiguration"]["Schedule"]["Frequency"]

        # Actualizar a Daily si no coincide
        if current_freq != "Daily":
            logger.info(f"Inventario en '{bucket_name}' tiene frecuencia '{current_freq}', actualizando a Daily...")
            create_inventory_configuration(bucket_name, central_bucket_name, central_account_id)
        else:
            logger.info(f"Inventario '{INVENTORY_ID}' ya existe en '{bucket_name}' con frecuencia Daily.")
    except ClientError as e:
        if e.response["Error"]["Code"] == "NoSuchConfiguration":
            logger.info(f"No existe inventario en '{bucket_name}', creando...")
            create_inventory_configuration(bucket_name, central_bucket_name, central_account_id)
        else:
            logger.error(f"Error al verificar inventario en '{bucket_name}': {e}")
            raise


def ensure_event_notification_is_configured(bucket_name: str, queue_arn: str):
    """Asegura que exista la notificación de eventos hacia SQS."""
    notification_id = "BckIncrementalTrigger-SQS"
    logger.info(f"Verificando notificación SQS en '{bucket_name}'.")

    try:
        current_config = s3_client.get_bucket_notification_configuration(Bucket=bucket_name)
        current_config.pop("ResponseMetadata", None)
        queue_configs = current_config.get("QueueConfigurations", [])
        if any(q.get("Id") == notification_id for q in queue_configs):
            logger.info(f"Notificación '{notification_id}' ya existe en '{bucket_name}'.")
            return
        current_config.setdefault("QueueConfigurations", []).append({
            "Id": notification_id,
            "QueueArn": queue_arn,
            "Events": ["s3:ObjectCreated:*"],
        })
    except ClientError:
        current_config = {"QueueConfigurations": [{
            "Id": notification_id,
            "QueueArn": queue_arn,
            "Events": ["s3:ObjectCreated:*"],
        }]}

    try:
        s3_client.put_bucket_notification_configuration(
            Bucket=bucket_name, NotificationConfiguration=current_config
        )
        logger.info(f"Notificación SQS configurada en '{bucket_name}'.")
    except ClientError as e:
        logger.error(f"Error al configurar notificación SQS en '{bucket_name}': {e}")
        raise


# --- Handler principal ---
def lambda_handler(event: Dict[str, Any], context: Any) -> Dict[str, List[Dict[str, str]]]:
    logger.info("Iniciando descubrimiento y configuración de buckets para backup.")

    try:
        central_bucket = os.environ["CENTRAL_BACKUP_BUCKET"]
        central_account_id = os.environ["CENTRAL_ACCOUNT_ID"]
    except KeyError as e:
        logger.error(f"Variable de entorno faltante: {e}")
        raise

    # Buscar buckets con BackupEnabled=true
    paginator = resource_tag_client.get_paginator("get_resources")
    source_bucket_arns = []
    for page in paginator.paginate(
        TagFilters=[{"Key": BACKUP_TAG_KEY, "Values": ["true"]}],
        ResourceTypeFilters=["s3"]
    ):
        for resource in page.get("ResourceTagMappingList", []):
            source_bucket_arns.append(resource["ResourceARN"])

    if not source_bucket_arns:
        logger.warning("No se encontraron buckets con BackupEnabled=true.")
        return {"Buckets": []}

    # Configurar inventarios y notificaciones
    resources_to_backup = []
    for arn in source_bucket_arns:
        bucket_name = arn.split(":::")[-1]
        logger.info(f"Procesando bucket '{bucket_name}'...")
        ensure_inventory_exists(bucket_name, central_bucket, central_account_id)
        ensure_event_notification_is_configured(bucket_name, SQS_QUEUE_ARN)

        try:
            tags = s3_client.get_bucket_tagging(Bucket=bucket_name).get("TagSet", [])
            criticality = next(
                (t["Value"] for t in tags if t["Key"] == CRITICALITY_TAG_KEY),
                DEFAULT_CRITICALITY,
            )
        except ClientError:
            criticality = DEFAULT_CRITICALITY

        resources_to_backup.append({
            "source_bucket": bucket_name,
            "inventory_key": f"inventory-source/{bucket_name}/{INVENTORY_ID}/",
            "criticality": criticality,
            "backup_bucket": central_bucket,
        })

    logger.info(f"Proceso completado. {len(resources_to_backup)} buckets configurados para respaldo.")
    return {"Buckets": resources_to_backup}
