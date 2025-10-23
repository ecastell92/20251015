## ============================================================================
## Configuracion principal - CORREGIDO PARA PRODUCCIÓN
## ============================================================================

## 1) Basicos
aws_region         = "eu-west-1"
environment        = "dev"
tenant             = "00"
iniciativa         = "mvp"
cuenta             = "905418243844"
# Selección de módulos a implementar  

# Desplegar backup S3
enable_s3_backups     = false
enable_central_bucket = false

# Desplegar backup RDS
enable_backup_rds = true

# Desplegar backup DynamoDB
enable_backup_dynamodb = false


## 2) Identificadores
central_backup_vault_name = "00-dev-s3-aws-vault-bck-001-aws"
sufijo_recursos           = "bck-001-aws"

## 3) Schedules por criticidad
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

## 4) GFS – Retencion por criticidad (datos)
gfs_rules = {
  Critico = {
    enable                     = true
    start_storage_class        = "GLACIER_IR"
    son_retention_days         = 21
    father_da_days             = 0
    father_retention_days      = 90
    father_archive_class       = "DEEP_ARCHIVE"
    grandfather_da_days        = 90
    grandfather_retention_days = 730
    grandfather_archive_class  = "DEEP_ARCHIVE"
  }
  MenosCritico = {
    enable                     = true
    start_storage_class        = "GLACIER_IR"
    son_retention_days         = 14
    father_da_days             = 0
    father_retention_days      = 60
    father_archive_class       = "DEEP_ARCHIVE"
    grandfather_da_days        = 90
    grandfather_retention_days = 365
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

## 5) Incrementales – Filtros y controles
## ⚠️ CRÍTICO: Deshabilitados para asegurar que se copien TODOS los objetos
criticality_tag             = "BackupCriticality"
allowed_prefixes            = { Critico = [], MenosCritico = [], NoCritico = [] }
exclude_key_prefixes        = [] # ← VACÍO = copiar todo
exclude_key_suffixes        = [] # ← VACÍO = copiar todo
force_full_on_first_run     = false
fallback_max_objects        = 0
fallback_time_limit_seconds = 0
disable_window_checkpoint   = true
incremental_log_level       = "INFO"

## 6) KMS en origen
kms_allow_viaservice = true
source_kms_key_arns  = []

## 7) Limpieza operacional (lifecycle)
cleanup_inventory_source_days = 7
cleanup_batch_reports_days    = 7
cleanup_checkpoints_days      = 7
cleanup_manifests_temp_days   = 7
cleanup_configurations_days   = 90

## 8) Backup de configuraciones – toggles
## ⚠️ CRÍTICO: Habilitados RDS y DynamoDB
backup_config_log_level             = "INFO"
backup_config_tag_filter_key        = "BackupEnabled"
backup_config_tag_filter_value      = "true"
backup_config_include_glue          = true
backup_config_include_athena        = true
backup_config_include_lambda        = true
backup_config_include_iam           = true
backup_config_include_stepfunctions = true
backup_config_include_eventbridge   = true
backup_config_include_dynamodb      = true # ← HABILITADO
backup_config_include_rds           = true # ← HABILITADO

## 9) Seguridad
min_deep_archive_offset_days = 90
enable_object_lock           = false
object_lock_mode             = "COMPLIANCE"
object_lock_retention_days   = 0
deny_delete_enabled          = false
allow_delete_principals      = []
require_mfa_for_delete       = false

## 10) Tags globales
backup_tags = {
  ManagedBy    = "Terraform"
  Project      = "DataPlatformBackup"
  Environment  = "dev"
  Initiative   = "mvp"
  CostStrategy = "optimized"
}




