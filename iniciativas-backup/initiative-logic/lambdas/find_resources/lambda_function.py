import boto3
import os
import logging
import time
import random
from botocore.exceptions import ClientError
from typing import Dict, Any, List

# Configuración global
logger = logging.getLogger()
logger.setLevel(os.environ.get("LOG_LEVEL", "INFO").upper())

s3_client = boto3.client("s3")
resource_tag_client = boto3.client("resourcegroupstaggingapi")
sts_client = boto3.client("sts")

# Constantes
BACKUP_TAG_KEY = "BackupEnabled"
CRITICALITY_TAG_KEY = "BackupCriticality"
DEFAULT_CRITICALITY = "MenosCritico"
INVENTORY_ID = "AutoBackupInventory"

# ============================================================================
# OPTIMIZACIÓN DE COSTES: INVENTORY WEEKLY PARA TODAS LAS CRITICIDADES
# ============================================================================
# RATIONALE:
# - Los incrementales (12h/24h) usan event-driven (SQS), NO inventory
# - Inventory solo se necesita para full backups (sweep)
# - Crítico: sweep cada 7d → Weekly inventory es suficiente y se genera justo antes
# - MenosCritico: sweep cada 14d → Weekly inventory sobra (2 inventarios entre sweeps)
# - NoCritico: sweep cada 30d → Weekly inventory sobra (4 inventarios entre sweeps)
#
# AHORRO: Daily → Weekly = reducción 85% en costes de inventory
# Para 20 buckets con 10M objetos: $11,750/mes → $2,108/mes = $9,642/mes ahorrados
# ============================================================================

INVENTORY_FREQUENCIES = {"Critico": "Weekly", "MenosCritico": "Weekly", "NoCritico": "Weekly"}

# Criticidades que requieren notificaciones SQS (solo las que tienen incrementales)
# Se puede configurar via env con lista separada por comas; por defecto solo "Critico"
_crit_env = os.environ.get("CRITICALITIES_WITH_NOTIFICATIONS", "").strip()
if _crit_env:
    CRITICALITIES_WITH_NOTIFICATIONS = [c.strip() for c in _crit_env.split(",") if c.strip()]
else:
    CRITICALITIES_WITH_NOTIFICATIONS = ["Critico"]


# ============================================================================
# ACCOUNT RESOLUTION (Single-account friendly)
# ============================================================================


def resolve_central_account_id() -> str:
    """Obtiene el Account ID donde vive el bucket central."""

    env_value = os.environ.get("CENTRAL_ACCOUNT_ID")
    if env_value:
        logger.debug("Usando CENTRAL_ACCOUNT_ID proporcionado por entorno")
        return env_value

    logger.info("CENTRAL_ACCOUNT_ID no definido; resolviendo via STS (despliegue single-account)")

    try:
        identity = sts_client.get_caller_identity()
        account_id = identity.get("Account")
        if not account_id:
            raise RuntimeError("STS no devolvió Account ID")
        logger.debug(f"Account ID resuelto via STS: {account_id}")
        return account_id
    except ClientError as e:
        logger.error("No se pudo obtener Account ID via STS", exc_info=True)
        raise


# ============================================================================
# INVENTORY CONFIGURATION
# ============================================================================


def create_inventory_configuration(
    bucket_name: str, central_bucket_name: str, central_account_id: str, frequency: str = "Weekly"
):
    """
    Crea la configuración de inventario en el bucket origen.
    Sin cifrado KMS - el bucket central usa AES256 por defecto.

    Args:
        bucket_name: Nombre del bucket origen
        central_bucket_name: Nombre del bucket central donde se guardan inventarios
        central_account_id: ID de la cuenta central
        frequency: Frecuencia del inventario ("Daily" o "Weekly")
    """
    logger.info(
        f"Creando inventario '{INVENTORY_ID}' en bucket '{bucket_name}' con frecuencia {frequency}"
    )

    # Configuración del destino
    s3_destination = {
        "AccountId": central_account_id,
        "Bucket": f"arn:aws:s3:::{central_bucket_name}",
        "Format": "CSV",
        "Prefix": "inventory-source",
    }

    try:
        s3_client.put_bucket_inventory_configuration(
            Bucket=bucket_name,
            Id=INVENTORY_ID,
            InventoryConfiguration={
                "Id": INVENTORY_ID,
                "IsEnabled": True,
                "IncludedObjectVersions": "Current",
                "OptionalFields": [
                    "Size",
                    "LastModifiedDate",
                    "StorageClass",
                    "ETag",
                    "EncryptionStatus",
                    "ReplicationStatus",
                    "IsMultipartUploaded",
                ],
                "Schedule": {"Frequency": frequency},
                "Destination": {"S3BucketDestination": s3_destination},
            },
        )
        logger.info(f"Inventario {frequency} creado correctamente en '{bucket_name}'")

    except ClientError as e:
        error_code = e.response["Error"]["Code"]
        logger.error(f"Error creando inventario en '{bucket_name}': {error_code} - {e}")
        raise


def ensure_inventory_exists(
    bucket_name: str, central_bucket_name: str, central_account_id: str, frequency: str = "Weekly"
):
    """
    Asegura que el inventario exista y esté actualizado en el bucket origen.
    Verifica frecuencia configurada y actualiza si es necesario.

    Args:
        bucket_name: Nombre del bucket origen
        central_bucket_name: Nombre del bucket central
        central_account_id: ID de la cuenta central
        frequency: Frecuencia esperada del inventario
    """
    try:
        existing = s3_client.get_bucket_inventory_configuration(Bucket=bucket_name, Id=INVENTORY_ID)
        current_freq = existing["InventoryConfiguration"]["Schedule"]["Frequency"]

        if current_freq != frequency:
            logger.info(
                f"Inventario en '{bucket_name}' tiene frecuencia '{current_freq}', "
                f"actualizando a {frequency} (optimización de costes)..."
            )
            create_inventory_configuration(
                bucket_name, central_bucket_name, central_account_id, frequency
            )
        else:
            logger.info(
                f"Inventario '{INVENTORY_ID}' ya configurado en '{bucket_name}' con frecuencia {frequency}"
            )

    except ClientError as e:
        error_code = e.response["Error"]["Code"]

        if error_code == "NoSuchConfiguration":
            logger.info(
                f"No existe inventario en '{bucket_name}', creando con frecuencia {frequency}..."
            )
            create_inventory_configuration(
                bucket_name, central_bucket_name, central_account_id, frequency
            )
        else:
            logger.error(f"Error verificando inventario en '{bucket_name}': {error_code} - {e}")
            raise


# ============================================================================
# EVENT NOTIFICATIONS
# ============================================================================


def ensure_event_notification_is_configured(bucket_name: str, queue_arn: str):
    """
    Asegura que exista la notificación de eventos S3 hacia SQS.
    Configuración idempotente - no duplica si ya existe.
    """
    notification_id = "BckIncrementalTrigger-SQS"
    logger.info(f"Verificando notificación SQS en '{bucket_name}'")

    try:
        current_config = s3_client.get_bucket_notification_configuration(Bucket=bucket_name)
        current_config.pop("ResponseMetadata", None)

        queue_configs = current_config.get("QueueConfigurations", [])

        if any(q.get("Id") == notification_id for q in queue_configs):
            logger.info(f"Notificación '{notification_id}' ya existe en '{bucket_name}'")
            pass

        current_config.setdefault("QueueConfigurations", []).append(
            {
                "Id": notification_id,
                "QueueArn": queue_arn,
                "Events": ["s3:ObjectCreated:*"],
            }
        )
        # Normalizar: dejar una sola entrada por QueueArn para ObjectCreated
        qcfgs = current_config.get("QueueConfigurations", [])

        def _is_object_created(cfg):
            return any(str(e).startswith("s3:ObjectCreated") for e in cfg.get("Events", []))

        qcfgs = [q for q in qcfgs if not (q.get("QueueArn") == queue_arn and _is_object_created(q))]
        qcfgs.append(
            {
                "Id": notification_id,
                "QueueArn": queue_arn,
                "Events": ["s3:ObjectCreated:*"],
            }
        )
        current_config["QueueConfigurations"] = qcfgs

    except ClientError as e:
        error_code = e.response["Error"]["Code"]

        if error_code == "NoSuchConfiguration":
            current_config = {
                "QueueConfigurations": [
                    {
                        "Id": notification_id,
                        "QueueArn": queue_arn,
                        "Events": ["s3:ObjectCreated:*"],
                    }
                ]
            }
        else:
            logger.error(f"Error obteniendo notificaciones de '{bucket_name}': {e}")
            raise

    # Put with retry to avoid OperationAborted conflicts
    max_attempts = 7
    delay = 0.5
    for attempt in range(1, max_attempts + 1):
        try:
            s3_client.put_bucket_notification_configuration(
                Bucket=bucket_name,
                NotificationConfiguration=current_config,
            )
            logger.info(f"Notificación SQS configurada en '{bucket_name}'")
            break
        except ClientError as e:
            code = e.response.get("Error", {}).get("Code", "")
            status = e.response.get("ResponseMetadata", {}).get("HTTPStatusCode", 0)
            if code == "OperationAborted" or status in (409, 503):
                sleep_for = delay + random.uniform(0, delay)
                logger.warning(
                    f"Conflicto configurando notificaciones en '{bucket_name}' (intento {attempt}/{max_attempts}). "
                    f"Reintentando en {sleep_for:.2f}s"
                )
                time.sleep(sleep_for)
                delay = min(delay * 2, 5)
                continue
            logger.error(
                f"Error configurando notificación SQS en '{bucket_name}': {code} status={status} - {e}"
            )
            raise
    else:
        raise RuntimeError(
            f"OperationAborted persistente al configurar notificaciones en '{bucket_name}'"
        )


def remove_event_notification_if_exists(bucket_name: str):
    """
    Elimina la notificación SQS si existe (para buckets que no requieren incrementales).
    """
    notification_id = "BckIncrementalTrigger-SQS"

    try:
        current_config = s3_client.get_bucket_notification_configuration(Bucket=bucket_name)
        current_config.pop("ResponseMetadata", None)

        queue_configs = current_config.get("QueueConfigurations", [])

        # Filtrar para remover nuestra notificación
        updated_configs = [q for q in queue_configs if q.get("Id") != notification_id]

        if len(updated_configs) < len(queue_configs):
            current_config["QueueConfigurations"] = updated_configs

            s3_client.put_bucket_notification_configuration(
                Bucket=bucket_name, NotificationConfiguration=current_config
            )
            logger.info(
                f"Notificación SQS eliminada de '{bucket_name}' (no requiere incrementales)"
            )
        else:
            logger.debug(f"✓ No había notificación SQS en '{bucket_name}' (correcto)")

    except ClientError as e:
        error_code = e.response["Error"]["Code"]
        if error_code == "NoSuchConfiguration":
            logger.debug(f"✓ No había configuración de notificaciones en '{bucket_name}'")
        else:
            logger.warning(f"Error eliminando notificación de '{bucket_name}': {e}")


# ============================================================================
# CRITICALITY DETECTION
# ============================================================================


def get_bucket_criticality(bucket_name: str) -> str:
    """Obtiene la criticidad del bucket desde sus tags."""
    try:
        tags = s3_client.get_bucket_tagging(Bucket=bucket_name).get("TagSet", [])
        criticality = next(
            (t["Value"] for t in tags if t["Key"] == CRITICALITY_TAG_KEY),
            DEFAULT_CRITICALITY,
        )
        logger.debug(f"Bucket '{bucket_name}' → Criticidad: {criticality}")
        return criticality

    except ClientError as e:
        error_code = e.response["Error"]["Code"]

        if error_code == "NoSuchTagSet":
            logger.warning(
                f"Bucket '{bucket_name}' sin tags. Usando criticidad por defecto: {DEFAULT_CRITICALITY}"
            )
            return DEFAULT_CRITICALITY
        else:
            logger.error(f"Error obteniendo tags de '{bucket_name}': {e}")
            raise


# ============================================================================
# LAMBDA HANDLER
# ============================================================================


def lambda_handler(event: Dict[str, Any], context: Any) -> Dict[str, List[Dict[str, str]]]:
    """
    Handler principal para descubrir y configurar buckets S3 para backup.

    Returns:
        Dict con lista de buckets configurados y sus metadatos
    """
    logger.info("=" * 80)
    logger.info("Iniciando descubrimiento de buckets para backup")
    logger.info("=" * 80)

    # Validar variables de entorno
    try:
        central_bucket = os.environ["CENTRAL_BACKUP_BUCKET"]
        sqs_queue_arn = os.environ["SQS_QUEUE_ARN"]
    except KeyError as e:
        logger.error(f"Variable de entorno faltante: {e}")
        raise

    central_account_id = resolve_central_account_id()

    logger.info(f"Bucket central: {central_bucket}")
    logger.info(f"Account ID: {central_account_id}")

    # Buscar buckets con BackupEnabled=true
    logger.info(f"Buscando buckets con tag {BACKUP_TAG_KEY}=true")

    paginator = resource_tag_client.get_paginator("get_resources")
    source_bucket_arns = []

    try:
        for page in paginator.paginate(
            TagFilters=[{"Key": BACKUP_TAG_KEY, "Values": ["true"]}], ResourceTypeFilters=["s3"]
        ):
            for resource in page.get("ResourceTagMappingList", []):
                source_bucket_arns.append(resource["ResourceARN"])

    except ClientError as e:
        logger.error(f"Error buscando recursos etiquetados: {e}")
        raise

    if not source_bucket_arns:
        logger.warning("No se encontraron buckets con BackupEnabled=true")
        return {"Buckets": []}

    logger.info(f"Encontrados {len(source_bucket_arns)} buckets para configurar")

    # Configurar inventarios y notificaciones según criticidad
    resources_to_backup = []
    errors = []

    for arn in source_bucket_arns:
        bucket_name = arn.split(":::")[-1]

        try:
            logger.info(f"\n{'='*80}")
            logger.info(f"Procesando bucket: {bucket_name}")

            # Obtener criticidad
            criticality = get_bucket_criticality(bucket_name)
            logger.info(f"Criticidad: {criticality}")

            # Obtener frecuencia de inventario según criticidad
            inventory_freq = INVENTORY_FREQUENCIES.get(criticality, "Weekly")
            logger.info(f"Frecuencia de inventory: {inventory_freq}")

            # DECISIÓN 1: Configurar inventory con frecuencia apropiada
            logger.info(f"Configurando inventory {inventory_freq}...")
            ensure_inventory_exists(bucket_name, central_bucket, central_account_id, inventory_freq)

            # DECISIÓN 2: Notificaciones SQS (solo si requiere incrementales)
            if criticality in CRITICALITIES_WITH_NOTIFICATIONS:
                logger.info(f"Configurando notificaciones SQS (incrementales habilitados)")
                ensure_event_notification_is_configured(bucket_name, sqs_queue_arn)
            else:
                logger.info(f"Omitiendo notificaciones SQS (sin incrementales)")
                remove_event_notification_if_exists(bucket_name)

            # Agregar a lista de respaldo
            resources_to_backup.append(
                {
                    "source_bucket": bucket_name,
                    "inventory_key": f"inventory-source/{bucket_name}/{INVENTORY_ID}/",
                    "criticality": criticality,
                    "backup_bucket": central_bucket,
                }
            )

            logger.info(f"Bucket '{bucket_name}' configurado correctamente")

        except Exception as e:
            error_msg = f"Error configurando bucket '{bucket_name}': {str(e)}"
            logger.error(f"{error_msg}", exc_info=True)
            errors.append({"bucket": bucket_name, "error": error_msg})

    logger.info("=" * 80)
    logger.info(f"Proceso completado")
    logger.info(f" Buckets configurados: {len(resources_to_backup)}")
    logger.info(f" Errores: {len(errors)}")
    logger.info("=" * 80)

    result = {"Buckets": resources_to_backup}

    if errors:
        result["Errors"] = errors
        logger.warning(f"Algunos buckets tuvieron errores: {errors}")

    return result
