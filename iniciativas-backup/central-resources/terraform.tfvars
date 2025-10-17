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
    start_storage_class        = "GLACIER_IR"
    son_retention_days         = 45
    father_da_days             = 180             # 180d en IR, luego DA
    father_retention_days      = 1825            # 5 años total
    father_archive_class       = "DEEP_ARCHIVE"
    grandfather_da_days        = 180             # 180d en IR, luego DA
    grandfather_retention_days = 1825            # 5 años total
    grandfather_archive_class  = "DEEP_ARCHIVE"
  }

  # MENOS CRITICO: 5 años, IR 90d -> DA
  MenosCritico = {
    enable                     = true
    start_storage_class        = "GLACIER_IR"
    son_retention_days         = 30
    father_da_days             = 90              # 90d en IR, luego DA
    father_retention_days      = 1825            # 5 años total
    father_archive_class       = "DEEP_ARCHIVE"
    grandfather_da_days        = 90              # 90d en IR, luego DA
    grandfather_retention_days = 1825            # 5 años total
    grandfather_archive_class  = "DEEP_ARCHIVE"
  }

  # NO CRITICO: Directo a GLACIER, eliminar a 90d
  NoCritico = {
    enable                     = true
    start_storage_class        = "GLACIER"
    son_retention_days         = 0
    father_da_days             = 0
    father_retention_days      = 90              # mínimo GLACIER (90d)
    father_archive_class       = "GLACIER"
    grandfather_da_days        = 0
    grandfather_retention_days = 90              # mínimo GLACIER (90d)
    grandfather_archive_class  = "GLACIER"
  }
}

# ----------------------------------------------------------------------------
# LIFECYCLE RULES LEGACY (Por compatibilidad - DEPRECATED)
# ----------------------------------------------------------------------------
# NOTA: Estas reglas están deshabilitadas cuando gfs_rules.enable=true

lifecycle_rules = {
  Critico = {
    glacier_transition_days             = 0
    deep_archive_transition_days        = 90
    expiration_days                     = 1825
    incremental_expiration_days         = 45
    incremental_glacier_transition_days = 0
    use_glacier_ir                      = true
  }
  
  MenosCritico = {
    glacier_transition_days             = 0
    deep_archive_transition_days        = 90
    expiration_days                     = 1095
    incremental_expiration_days         = 30
    incremental_glacier_transition_days = 0
    use_glacier_ir                      = true
  }
  
  NoCritico = {
    glacier_transition_days             = 0
    deep_archive_transition_days        = 0
    expiration_days                     = 90
    incremental_expiration_days         = 21
    incremental_glacier_transition_days = 0
    use_glacier_ir                      = false
  }
}

# ----------------------------------------------------------------------------
# VALIDACIONES S3
# ----------------------------------------------------------------------------

min_deep_archive_offset_days = 90  # Mínimo requerido por S3

