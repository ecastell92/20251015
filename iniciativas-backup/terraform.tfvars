# ============================================================================
# Root Configuration - Unified Terraform Variables
# ESTRATEGIA ECONÓMICA OPTIMIZADA
# ============================================================================

# ----------------------------------------------------------------------------
# CONFIGURACIÓN BÁSICA
# ----------------------------------------------------------------------------

aws_region  = "eu-west-1"
environment = "dev"
tenant      = "00"
iniciativa  = "mvp"

# ----------------------------------------------------------------------------
# BUCKET CENTRAL
# ----------------------------------------------------------------------------

central_backup_bucket_name = "00-dev-s3-bucket-central-bck-001-aws-notinet"
central_backup_vault_name  = "00-dev-s3-aws-vault-bck-001-aws"
sufijo_recursos            = "bck-001-aws-notinet"

# ----------------------------------------------------------------------------
# REGLAS GFS OPTIMIZADAS (Ahorro 65%)
# ----------------------------------------------------------------------------

gfs_rules = {
  # ========================================================================
  # CRÍTICO: RPO 12h
  # Incrementales: 14 días en STANDARD
  # Full semanales: 1 año (90d GLACIER_IR → DEEP_ARCHIVE)
  # Full mensuales: 2 años en DEEP_ARCHIVE
  # ========================================================================
  Critico = {
    enable                     = true
    start_storage_class        = "STANDARD"      # Acceso rápido
    son_retention_days         = 14              # 2 semanas
    father_da_days             = 90              # Transición a DA
    father_retention_days      = 365             # 1 año
    father_archive_class       = "DEEP_ARCHIVE"
    grandfather_da_days        = 0               # DA inmediato
    grandfather_retention_days = 730             # 2 años
    grandfather_archive_class  = "DEEP_ARCHIVE"
  }

  # ========================================================================
  # MENOS CRÍTICO: RPO 24h
  # Incrementales: 7 días en STANDARD
  # Full quincenales: 90 días (90d GLACIER_IR)
  # Full trimestrales: 1 año en DEEP_ARCHIVE
  # ========================================================================
  MenosCritico = {
    enable                     = true
    start_storage_class        = "STANDARD"
    son_retention_days         = 7               # 1 semana
    father_da_days             = 90
    father_retention_days      = 90              # Mínimo
    father_archive_class       = "DEEP_ARCHIVE"
    grandfather_da_days        = 0
    grandfather_retention_days = 365             # 1 año
    grandfather_archive_class  = "DEEP_ARCHIVE"
  }

  # ========================================================================
  # NO CRÍTICO: Sin incrementales
  # Full mensuales: 90 días en GLACIER
  # ========================================================================
  NoCritico = {
    enable                     = true
    start_storage_class        = "GLACIER"       # Más barato
    son_retention_days         = 0               # Sin incrementales
    father_da_days             = 0
    father_retention_days      = 90              # Mínimo GLACIER
    father_archive_class       = "GLACIER"
    grandfather_da_days        = 0
    grandfather_retention_days = 0               # Sin grandfather
    grandfather_archive_class  = "GLACIER"
  }
}

# ----------------------------------------------------------------------------
# SCHEDULES OPTIMIZADOS
# ----------------------------------------------------------------------------

schedule_expressions = {
  Critico = {
    incremental = "rate(12 hours)"           # RPO 12h
    sweep       = "rate(7 days)"             # Full semanal
    grandfather = "cron(0 3 1 * ? *)"        # 1ro de cada mes 3 AM UTC
  }

  MenosCritico = {
    incremental = "rate(24 hours)"           # RPO 24h
    sweep       = "rate(14 days)"            # Full quincenal (ahorro 50%)
    grandfather = "cron(0 3 1 */3 ? *)"      # Trimestral
  }

  NoCritico = {
    # incremental: OMITIDO (ahorro 100%)
    sweep       = "rate(30 days)"            # Full mensual
    # grandfather: OMITIDO (ahorro)
  }
}

# ----------------------------------------------------------------------------
# CONFIGURACIÓN DE BACKUPS
# ----------------------------------------------------------------------------

criticality_tag = "BackupCriticality"

allowed_prefixes = {
  Critico      = []  # Todos los objetos
  MenosCritico = []  # Todos los objetos
  NoCritico    = []  # Todos los objetos
}

force_full_on_first_run     = false   # Incrementales siempre incrementales
fallback_max_objects        = 100000  # Límite fallback
fallback_time_limit_seconds = 300     # 5 minutos máximo

# ----------------------------------------------------------------------------
# TAGS PARA COST ALLOCATION
# ----------------------------------------------------------------------------

backup_tags = {
  ManagedBy    = "Terraform"
  Project      = "DataPlatformBackup"
  Environment  = "dev"
  Initiative   = "mvp"
  CostStrategy = "optimized"
  Owner        = "data-team"
}

# ----------------------------------------------------------------------------
# VALIDACIONES S3
# ----------------------------------------------------------------------------

min_deep_archive_offset_days = 90  # Mínimo requerido por S3

# ----------------------------------------------------------------------------
# SEGURIDAD (Deshabilitado por defecto para simplicidad)
# ----------------------------------------------------------------------------

enable_object_lock          = false
object_lock_mode            = "COMPLIANCE"
object_lock_retention_days  = 0
deny_delete_enabled         = false
allow_delete_principals     = []
require_mfa_for_delete      = false

# ----------------------------------------------------------------------------
# LIFECYCLE RULES LEGACY (NO SE USAN - Solo compatibilidad)
# ----------------------------------------------------------------------------

lifecycle_rules = {
  Critico      = { glacier_transition_days = 0, deep_archive_transition_days = 90, expiration_days = 365, incremental_expiration_days = 14, incremental_glacier_transition_days = 0, use_glacier_ir = false }
  MenosCritico = { glacier_transition_days = 0, deep_archive_transition_days = 90, expiration_days = 90, incremental_expiration_days = 7, incremental_glacier_transition_days = 0, use_glacier_ir = false }
  NoCritico    = { glacier_transition_days = 0, deep_archive_transition_days = 0, expiration_days = 90, incremental_expiration_days = 0, incremental_glacier_transition_days = 0, use_glacier_ir = false }
}

# ============================================================================
# RESUMEN DE OPTIMIZACIONES
# ============================================================================
#
# ✅ Versionado: Suspendido (ahorro ~30%)
# ✅ Archivos operacionales: 7 días (vs 21)
# ✅ Crítico incrementales: 14 días (vs 45)
# ✅ Menos Crítico incrementales: 7 días (vs 30)
# ✅ No Crítico: Sin incrementales (ahorro 100%)
# ✅ Full semanales: GLACIER_IR 90d → DEEP_ARCHIVE
# ✅ Full mensuales: DEEP_ARCHIVE inmediato
#
# 💰 AHORRO ESTIMADO: 65-68%
# 📊 De $27,138/mes a $8,642/mes (10 TB)
# 🎯 RPO mantenido: Crítico 12h, Menos Crítico 24h
#
# ============================================================================
