## ============================================================================
## CONFIGURACIÓN OPTIMIZADA - GARANTÍA CERO PÉRDIDA DE DATOS
## ============================================================================

## 1) Básicos
aws_region  = "eu-west-1"
environment = "dev"
tenant      = "00"
iniciativa  = "mvp"
cuenta      = "905418243844"

## 2) Selección de módulos
enable_s3_backups      = true
enable_central_bucket  = true
enable_backup_rds      = true
enable_backup_dynamodb = false

enable_cloudwatch_dashboard = true

## 3) Identificadores
central_backup_bucket_name = ""
central_backup_vault_name  = ""
sufijo_recursos            = "bck-001-aws"

## 4) Schedules por criticidad - ESTRATEGIA DUAL
schedule_expressions = {
  Critico = {
    incremental = "rate(12 hours)"    # ← Rápido con filtros ligeros
    sweep       = "rate(7 days)"      # ← Completo sin filtros
    grandfather = "cron(0 3 1 * ? *)" # ← Mensual completo
  }
  MenosCritico = {
    incremental = "rate(24 hours)"    # ← Diario con filtros
    sweep       = "rate(14 days)"     # ← Quincenal completo
    grandfather = "cron(0 3 1 * ? *)" # ← Mensual completo
  }
  NoCritico = {
    sweep = "rate(30 days)" # ← Solo mensual completo
  }
}

## 5) GFS – Retención por criticidad
gfs_rules = {
  Critico = {
    enable                     = true
    start_storage_class        = "GLACIER_IR"
    son_retention_days         = 21 # ← 21 días incrementales
    father_da_days             = 0
    father_retention_days      = 90 # ← 90 días sweeps
    father_archive_class       = "DEEP_ARCHIVE"
    grandfather_da_days        = 90
    grandfather_retention_days = 365 # ← 1 año completos
    grandfather_archive_class  = "DEEP_ARCHIVE"
  }
  MenosCritico = {
    enable                     = true
    start_storage_class        = "GLACIER_IR"
    son_retention_days         = 14 # ← 14 días incrementales
    father_da_days             = 0
    father_retention_days      = 60 # ← 60 días sweeps
    father_archive_class       = "DEEP_ARCHIVE"
    grandfather_da_days        = 90
    grandfather_retention_days = 180 # ← 6 meses completos
    grandfather_archive_class  = "DEEP_ARCHIVE"
  }
  NoCritico = {
    enable                     = true
    start_storage_class        = "GLACIER"
    son_retention_days         = 0 # ← Sin incrementales
    father_da_days             = 0
    father_retention_days      = 30 # ← 30 días sweeps
    father_archive_class       = "GLACIER"
    grandfather_da_days        = 0
    grandfather_retention_days = 0
    grandfather_archive_class  = "GLACIER"
  }
}

## 6) FILTROS DE BACKUP - ESTRATEGIA OPTIMIZADA
criticality_tag = "BackupCriticality"

# Incrementales: Filtros ligeros (solo datos relevantes = más rápido)
allowed_prefixes = {
  Critico      = [] # ← Ajustar a tus carpetas
  MenosCritico = [] # ← Ajustar a tus carpetas
  NoCritico    = [] # ← Sin filtro
}

# Exclusiones SOLO técnicas (aplican a incrementales Y sweeps)
exclude_key_prefixes = [
  # "temporary/",        # ← Descomentar si tienes carpeta temporal
  # "sparkHistoryLogs/", # ← Descomentar si tienes logs Spark
  # ".trash/",           # ← Descomentar si tienes papelera
]

exclude_key_suffixes = [
  "/", # ← OBLIGATORIO: Marcadores de carpeta
  # ".inprogress",  # ← Descomentar si tienes archivos en progreso
  # ".tmp",         # ← Descomentar si tienes archivos temporales
]

## 7) Controles de backup
force_full_on_first_run     = false
fallback_max_objects        = 0    # ← Sin límite
fallback_time_limit_seconds = 0    # ← Sin límite
disable_window_checkpoint   = true # ← Copiar objetos tardíos
incremental_log_level       = "INFO"

## 8) KMS en origen
kms_allow_viaservice = true
source_kms_key_arns  = []

## 9) Limpieza operacional (lifecycle)
cleanup_inventory_source_days = 7
cleanup_batch_reports_days    = 7
cleanup_checkpoints_days      = 7
cleanup_manifests_temp_days   = 7
cleanup_configurations_days   = 90

## 10) Backup de configuraciones
backup_config_log_level             = "INFO"
backup_config_tag_filter_key        = "BackupEnabled"
backup_config_tag_filter_value      = "true"
backup_config_include_glue          = true
backup_config_include_athena        = true
backup_config_include_lambda        = true
backup_config_include_iam           = true
backup_config_include_stepfunctions = true
backup_config_include_eventbridge   = true
backup_config_include_dynamodb      = true
backup_config_include_rds           = true

## 11) Seguridad
min_deep_archive_offset_days = 90
enable_object_lock           = false
object_lock_mode             = "COMPLIANCE"
object_lock_retention_days   = 0
deny_delete_enabled          = false
allow_delete_principals      = []
require_mfa_for_delete       = false

## 12) Tags globales
backup_tags = {
  ManagedBy    = "Terraform"
  Project      = "DataPlatformBackup"
  Environment  = "dev"
  Initiative   = "mvp"
  CostStrategy = "optimized-dual-path"
}
