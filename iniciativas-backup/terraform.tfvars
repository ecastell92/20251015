# ============================================================================
# CONFIGURACION CORREGIDA - terraform.tfvars
# ============================================================================
# Cambios para copiar TODOS los objetos sin pérdidas
# ============================================================================

# --------------------------------------------------------------------------
# CAMBIO 1: ELIMINAR LÍMITES DE FALLBACK
# --------------------------------------------------------------------------
# ANTES (limitaba a 100k objetos y 5 minutos):
# fallback_max_objects        = 100000
# fallback_time_limit_seconds = 300

# DESPUÉS (sin límites - permite copiar todo):
fallback_max_objects        = 0 # 0 = sin límite
fallback_time_limit_seconds = 0 # 0 = sin límite

# --------------------------------------------------------------------------
# CAMBIO 2: PERMITIR TODOS LOS PREFIJOS
# --------------------------------------------------------------------------
# ANTES (podría filtrar objetos si no están en la lista):
# allowed_prefixes = {
#   Critico      = ["data/", "logs/"]  # Solo copia estos prefijos
#   MenosCritico = ["archive/"]
#   NoCritico    = []
# }

# DESPUÉS (copiar TODO):
allowed_prefixes = {
  Critico      = [] # Lista vacía = copiar todos los objetos
  MenosCritico = []
  NoCritico    = []
}

# --------------------------------------------------------------------------
# CAMBIO 3: DESHABILITAR CHECKPOINTS DE VENTANA EN INCREMENTALES
# --------------------------------------------------------------------------
# Esto previene que objetos que llegan tarde a una ventana ya procesada
# sean descartados
disable_window_checkpoint = true # Ya está por defecto, pero asegurar

# --------------------------------------------------------------------------
# CAMBIO 4: AJUSTAR RETENCIONES GFS PARA CONSERVAR MÁS TIEMPO
# --------------------------------------------------------------------------
gfs_rules = {
  Critico = {
    enable                     = true
    start_storage_class        = "GLACIER_IR"
    son_retention_days         = 21 # AUMENTADO de 14 a 21 días
    father_da_days             = 0
    father_retention_days      = 90 # AUMENTADO de 28 a 90 días
    father_archive_class       = "DEEP_ARCHIVE"
    grandfather_da_days        = 90
    grandfather_retention_days = 730 # 2 años
    grandfather_archive_class  = "DEEP_ARCHIVE"
  }

  MenosCritico = {
    enable                     = true
    start_storage_class        = "GLACIER_IR"
    son_retention_days         = 14 # AUMENTADO de 7 a 14 días
    father_da_days             = 0
    father_retention_days      = 60 # AUMENTADO de 28 a 60 días
    father_archive_class       = "DEEP_ARCHIVE"
    grandfather_da_days        = 90
    grandfather_retention_days = 365 # 1 año
    grandfather_archive_class  = "DEEP_ARCHIVE"
  }

  NoCritico = {
    enable                     = true
    start_storage_class        = "GLACIER"
    son_retention_days         = 0
    father_da_days             = 0
    father_retention_days      = 30
    father_archive_class       = "GLACIER"
    grandfather_da_days        = 0
    grandfather_retention_days = 0
    grandfather_archive_class  = "GLACIER"
  }
}

# --------------------------------------------------------------------------
# CAMBIO 5: AUMENTAR TIMEOUT Y MEMORIA DE LAMBDAS
# --------------------------------------------------------------------------
# Esto requiere modificar initiative-logic/main.tf:

# EN filter_inventory Lambda (línea ~290):
# timeout     = 900  # Ya está configurado correctamente
# memory_size = 512  # Considerar aumentar a 1024 si hay buckets grandes

# EN incremental_backup Lambda (línea ~360):
# timeout     = 300  # Ya está OK
# memory_size = 512  # Ya está OK

# --------------------------------------------------------------------------
# CONFIGURACIÓN COMPLETA DEL RESTO (SIN CAMBIOS)
# --------------------------------------------------------------------------

aws_region         = "eu-west-1"
environment        = "dev"
tenant             = "00"
iniciativa         = "mvp"
cuenta             = "905418243844"
central_account_id = "905418243844"

central_backup_vault_name = "00-dev-s3-aws-vault-bck-001-aws"
sufijo_recursos           = "bck-001-aws"

schedule_expressions = {
  Critico = {
    incremental = "rate(12 hours)"
    sweep       = "rate(7 days)"
    grandfather = "cron(0 3 1 * ? *)"
  }

  MenosCritico = {
    incremental = "rate(24 hours)"
    sweep       = "rate(14 days)"
    grandfather = "cron(0 3 1 * ? *)"
  }

  NoCritico = {
    sweep = "rate(30 days)"
  }
}

criticality_tag = "BackupCriticality"

backup_tags = {
  ManagedBy    = "Terraform"
  Project      = "DataPlatformBackup"
  Environment  = "dev"
  Initiative   = "mvp"
  CostStrategy = "optimized"
}

backup_config_log_level        = "INFO"
backup_config_tag_filter_key   = "BackupEnabled"
backup_config_tag_filter_value = "true"

backup_config_include_glue          = true
backup_config_include_athena        = true
backup_config_include_lambda        = true
backup_config_include_iam           = true
backup_config_include_stepfunctions = true
backup_config_include_eventbridge   = true
backup_config_include_dynamodb      = false
backup_config_include_rds           = false

force_full_on_first_run = false

min_deep_archive_offset_days = 90

cleanup_inventory_source_days = 7
cleanup_batch_reports_days    = 7
cleanup_checkpoints_days      = 7
cleanup_manifests_temp_days   = 7

enable_object_lock         = false
object_lock_mode           = "COMPLIANCE"
object_lock_retention_days = 0
deny_delete_enabled        = false
allow_delete_principals    = []
require_mfa_for_delete     = false
