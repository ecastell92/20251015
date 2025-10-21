# ============================================================================
# CONFIGURACION DE BACKUPS S3 - TERRAFORM.TFVARS
# ============================================================================
# Este archivo contiene la CONFIGURACION principal del sistema de backups.
# CAMBIAR VALORES AQUÍ ACTUALIZA TODO EL SISTEMA AUTOMÁTICAMENTE
# ============================================================================

# --------------------------------------------------------------------------
# CONFIGURACION BASICA
# --------------------------------------------------------------------------

aws_region  = "eu-west-1"
environment = "dev"
tenant      = "00"
iniciativa  = "mvp"
cuenta      = "905418243844"

# ID de la cuenta CENTRAL donde vive el bucket de backups.
# Si coincide con la cuenta actual, manténlo igual que "cuenta".
central_account_id = "905418243844"


# --------------------------------------------------------------------------
# BUCKET CENTRAL (REQUERIDO)
# --------------------------------------------------------------------------

#central_backup_bucket_name = "00-dev-s3-bucket-central-bck-001-aws-notinet"
central_backup_vault_name = "00-dev-s3-aws-vault-bck-001-aws"
sufijo_recursos           = "bck-001-aws"

# --------------------------------------------------------------------------
# SCHEDULES POR CRITICIDAD (REQUERIDO)
# --------------------------------------------------------------------------
# Define CUANDO se ejecutan los backups para cada nivel de criticidad
# 
# incremental: Backups incrementales (opcional - solo si RPO < 24h)
# sweep:       Backups full regulares (Father generation)
# grandfather: Backups full de larga RETENCION (opcional)
# --------------------------------------------------------------------------

schedule_expressions = {
  # ========================================================================
  # CRÍTICO: RPO 12 horas
  # ========================================================================
  Critico = {
    incremental = "rate(6 hours)"     # Cada 12h
    sweep       = "rate(7 days)"      # Full semanal
    grandfather = "cron(0 3 1 * ? *)" # Full mensual (1er día, 3 AM UTC)
  }

  # ========================================================================
  # MENOS CRÍTICO: RPO 24 horas
  # ========================================================================
  MenosCritico = {
    incremental = "rate(24 hours)"
    sweep       = "rate(14 days)"
    grandfather = "cron(0 3 1 * ? *)"
  }

  # ========================================================================
  # NO CRÍTICO: Solo full mensuales (SIN incrementales para ahorrar)
  # ========================================================================
  NoCritico = {
    sweep = "rate(30 days)"
  }
}

# --------------------------------------------------------------------------
# REGLAS GFS POR CRITICIDAD (REQUERIDO)
# --------------------------------------------------------------------------
# Grandfather-Father-Son: Define RETENCIONes y storage classes
# 
# Son:         Incrementales diarios
# Father:      Full semanales/quincenales
# Grandfather: Full mensuales/trimestrales para auditoria
# --------------------------------------------------------------------------

gfs_rules = {
  Critico = {
    enable                     = true
    start_storage_class        = "GLACIER_IR"
    son_retention_days         = 14
    father_da_days             = 0
    father_retention_days      = 28
    father_archive_class       = "DEEP_ARCHIVE"
    grandfather_da_days        = 90
    grandfather_retention_days = 365
    grandfather_archive_class  = "DEEP_ARCHIVE"
  }

  MenosCritico = {
    enable                     = true
    start_storage_class        = "GLACIER_IR"
    son_retention_days         = 7
    father_da_days             = 0
    father_retention_days      = 28
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



# --------------------------------------------------------------------------
# CONFIGURACION DE TAGS Y PREFIJOS
# --------------------------------------------------------------------------

criticality_tag = "BackupCriticality"

allowed_prefixes = {
  Critico      = [] # Todos los objetos
  MenosCritico = [] # Todos los objetos
  NoCritico    = [] # Todos los objetos

  # Ejemplo con filtros:
  # Critico      = ["data/", "logs/critical/"]
  # MenosCritico = ["archive/", "temp/"]
  # NoCritico    = ["cache/"]
}

backup_tags = {
  ManagedBy    = "Terraform"
  Project      = "DataPlatformBackup"
  Environment  = "dev"
  Initiative   = "mvp"
  CostStrategy = "optimized"
}

# ---------------------------------------------------------------------------
# BACKUP CONFIGURATIONS (Lambda) - Opciones configurables desde tfvars
# ---------------------------------------------------------------------------

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

# --------------------------------------------------------------------------
# CONTROL DE PRIMERA CORRIDA Y FALLBACK
# --------------------------------------------------------------------------

force_full_on_first_run     = false  # Incrementales siempre son incrementales
fallback_max_objects        = 100000 # Límite en fallback (sin inventario)
fallback_time_limit_seconds = 300    # 5 minutos máximo

# --------------------------------------------------------------------------
# VALIDACIONES Y SEGURIDAD
# --------------------------------------------------------------------------

min_deep_archive_offset_days = 90 # Requisito S3: mínimo entre GLACIER_IR y DA


# ---------------------------------------------------------------------------
# LIMPIEZA DE ARCHIVOS OPERACIONALES (central-resources)
# ---------------------------------------------------------------------------

cleanup_inventory_source_days = 7
cleanup_batch_reports_days    = 7
cleanup_checkpoints_days      = 7
cleanup_manifests_temp_days   = 7
# Seguridad (opcional - por defecto deshabilitado)
enable_object_lock         = false
object_lock_mode           = "COMPLIANCE"
object_lock_retention_days = 0
deny_delete_enabled        = false
allow_delete_principals    = []
require_mfa_for_delete     = false

# LIFECYCLE RULES LEGACY (DEPRECATED) – se usan los defaults del módulo

# --------------------------------------------------------------------------
#  EJEMPLOS DE CONFIGURACION
# --------------------------------------------------------------------------

# --------------------------------------------------------------------------
# EJEMPLO 1: RPO MAS AGRESIVO (6 HORAS PARA CRÍTICO)
# --------------------------------------------------------------------------
#
# backup_frequencies = {
#   critical_hours      = 6   # Cada 6 horas (event-driven)
#   less_critical_hours = 24
#   non_critical_hours  = 168
# }
#
# RESULTADO AUTOMÁTICO:
# -------------------------------------------------------------------------- Crítico: rate(6 hours)
# -------------------------------------------------------------------------- Método: incremental_backup (event-driven)
# -------------------------------------------------------------------------- Storage: GLACIER_IR
# -------------------------------------------------------------------------- RETENCION: 14 días incrementales
# -------------------------------------------------------------------------- RPO: 6 horas

# --------------------------------------------------------------------------
# EJEMPLO 2: CAMBIAR A MANIFEST DIFF PARA MENOS CRÍTICO
# --------------------------------------------------------------------------
#
# backup_frequencies = {
#   critical_hours      = 12
#   less_critical_hours = 36  # MAS de 24h → cambia a manifest diff
#   non_critical_hours  = 168
# }
#
# RESULTADO AUTOMÁTICO:
# -------------------------------------------------------------------------- Menos Crítico: rate(36 hours)
# -------------------------------------------------------------------------- Método: filter_inventory (manifest diff)
# -------------------------------------------------------------------------- Usa checkpoint para comparación
# -------------------------------------------------------------------------- Storage: GLACIER_IR
# -------------------------------------------------------------------------- RETENCION: 7 días incrementales

# --------------------------------------------------------------------------
# EJEMPLO 3: BACKUPS MENSUALES PARA NO CRÍTICO
# --------------------------------------------------------------------------
#
# backup_frequencies = {
#   critical_hours      = 12
#   less_critical_hours = 24
#   non_critical_hours  = 720  # 30 días
# }
#
# RESULTADO AUTOMÁTICO:
# -------------------------------------------------------------------------- No Crítico: rate(720 hours)
# -------------------------------------------------------------------------- Método: manifest_diff (solo full)
# -------------------------------------------------------------------------- Sin incrementales automáticos
# -------------------------------------------------------------------------- Storage: GLACIER
# -------------------------------------------------------------------------- RETENCION: 90 días

# --------------------------------------------------------------------------
#  CÓMO FUNCIONA EL ROUTING AUTOMÁTICO
# --------------------------------------------------------------------------
#
# Como funciona el routing de backups (resumen):
# - Paso 1: Ajusta schedule_expressions por criticidad.
# - Paso 2: Si incremental < 24h -> event-driven (Lambda incremental_backup + SQS). Si no -> manifest diff (filter_inventory + Step Functions).
# - Paso 3: Se aplican storage class y retenciones segun criticidad (GFS).



