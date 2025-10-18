# ============================================================================
# Configuración de Variables - Central Resources
# ============================================================================
# IMPORTANTE: Este archivo debe estar sincronizado con initiative-logic
# ============================================================================

# ----------------------------------------------------------------------------
# CONFIGURACIÓN BÁSICA
# ----------------------------------------------------------------------------

aws_region  = "eu-west-1"
environment = "dev"
tenant      = "00"
iniciativa  = "mvp"

# ----------------------------------------------------------------------------
# BUCKET CENTRAL - NOMBRE COMPLETO (Sin partes)
# ----------------------------------------------------------------------------

# Nombre completo del bucket (sin construcción con partes)
central_backup_bucket_name = "00-dev-s3-bucket-central-bck-001-aws-notinet"

central_backup_vault_name = "00-dev-s3-aws-vault-bck-001-aws"

sufijo_recursos = "bck-001-aws"

# ----------------------------------------------------------------------------
# REGLAS GFS (Grandfather-Father-Son) POR CRITICIDAD
# ----------------------------------------------------------------------------

gfs_rules = {
  # CRITICO: 5 años, IR 180d -> DA
  Critico = {
    enable                     = true
    start_storage_class        = "GLACIER_IR" # Incrementales en GLACIER_IR
    son_retention_days         = 14           # 2 semanas de incrementales
    father_da_days             = 90           # Transición a DA (mínimo S3)
    father_retention_days      = 365          # 1 año de full semanales
    father_archive_class       = "DEEP_ARCHIVE"
    grandfather_da_days        = 0   # DA inmediato para auditoría
    grandfather_retention_days = 730 # 2 años de auditoría
    grandfather_archive_class  = "DEEP_ARCHIVE"
  }

  # MENOS CRITICO: 5 años, IR 90d -> DA
  MenosCritico = {
    enable                     = true
    start_storage_class        = "GLACIER_IR" # Incrementales en GLACIER_IR
    son_retention_days         = 7            # 1 semana de incrementales
    father_da_days             = 90           # Transición a DA
    father_retention_days      = 91           # Mínimo posible
    father_archive_class       = "DEEP_ARCHIVE"
    grandfather_da_days        = 0   # DA inmediato
    grandfather_retention_days = 365 # 1 año de auditoría
    grandfather_archive_class  = "DEEP_ARCHIVE"
  }

  # NO CRITICO: Directo a GLACIER, eliminar a 90d
  NoCritico = {
    enable                     = true
    start_storage_class        = "GLACIER" # Más barato (sin incrementales)
    son_retention_days         = 0         # Sin incrementales (ahorro)
    father_da_days             = 0         # Quedarse en GLACIER
    father_retention_days      = 90        # Mínimo GLACIER (90d)
    father_archive_class       = "GLACIER"
    grandfather_da_days        = 0 # Sin grandfather (ahorro)
    grandfather_retention_days = 0 # Sin retención larga
    grandfather_archive_class  = "GLACIER"
  }
}

# ----------------------------------------------------------------------------
# LIFECYCLE RULES LEGACY (Por compatibilidad - DEPRECATED)
# ----------------------------------------------------------------------------
# NOTA: Estas reglas están deshabilitadas cuando gfs_rules.enable=true

lifecycle_rules = {
  Critico      = { glacier_transition_days = 0, deep_archive_transition_days = 90, expiration_days = 365, incremental_expiration_days = 14, incremental_glacier_transition_days = 0, use_glacier_ir = true }
  MenosCritico = { glacier_transition_days = 0, deep_archive_transition_days = 90, expiration_days = 90, incremental_expiration_days = 7, incremental_glacier_transition_days = 0, use_glacier_ir = true }
  NoCritico    = { glacier_transition_days = 0, deep_archive_transition_days = 0, expiration_days = 90, incremental_expiration_days = 0, incremental_glacier_transition_days = 0, use_glacier_ir = false }
}
# ----------------------------------------------------------------------------
# SCHEDULES OPTIMIZADOS POR CRITICIDAD
# ----------------------------------------------------------------------------

schedule_expressions = {
  # ========================================================================
  # CRÍTICO: RPO 12h
  # ========================================================================
  Critico = {
    incremental = "rate(12 hours)"    # Cada 12h (RPO cumplido)
    sweep       = "rate(7 days)"      # Full semanal (Father)
    grandfather = "cron(0 3 1 * ? *)" # 1ro de cada mes a las 3 AM UTC
  }

  # ========================================================================
  # MENOS CRÍTICO: RPO 24h
  # ========================================================================
  MenosCritico = {
    incremental = "rate(24 hours)"      # Cada 24h (RPO cumplido)
    sweep       = "rate(14 days)"       # Full quincenal (Father)
    grandfather = "cron(0 3 1 */3 ? *)" # Cada 3 meses (trimestral)
  }

  # ========================================================================
  # NO CRÍTICO: Solo full mensuales (SIN incrementales)
  # ========================================================================
  NoCritico = {
    # incremental: OMITIDO (ahorro del 100% en incrementales)
    sweep = "rate(30 days)" # Full mensual
    # grandfather: OMITIDO (ahorro)
  }
}


# ----------------------------------------------------------------------------
# VALIDACIONES S3
# ----------------------------------------------------------------------------

min_deep_archive_offset_days = 90 # Mínimo requerido por S3



