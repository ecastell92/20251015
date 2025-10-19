# ============================================================================
# Configuración de Variables - ROOT LEVEL (CORREGIDO)
# ============================================================================
# Este archivo contiene TODAS las variables necesarias para desplegar
# la solución de backups S3 desde el directorio raíz.
#
# Los archivos terraform.tfvars en central-resources/ e initiative-logic/
# deben renombrarse a .example ya que NO se usan cuando se ejecuta desde root.
# ============================================================================

# ----------------------------------------------------------------------------
# CONFIGURACIÓN BÁSICA
# ----------------------------------------------------------------------------

aws_region  = "eu-west-1"
environment = "dev"
tenant      = "00"
iniciativa  = "mvp"

# ----------------------------------------------------------------------------
# RECURSOS CENTRALES
# ----------------------------------------------------------------------------

# Nombre COMPLETO del bucket central (debe ser globalmente único)
central_backup_bucket_name = "00-dev-s3-bucket-central-bck-001-aws-notinet"

# Nombre del AWS Backup Vault
central_backup_vault_name = "00-dev-s3-aws-vault-bck-001-aws"

# ✅ CORREGIDO: Unificado el sufijo para consistencia
# Antes había dos valores: "bck-001-aws" y "bck-001-aws-notinet"
sufijo_recursos = "bck-001-aws-notinet"

# ----------------------------------------------------------------------------
# CONFIGURACIÓN DE BACKUPS
# ----------------------------------------------------------------------------

# Tag key que define la criticidad en los recursos de origen
criticality_tag = "BackupCriticality"

# Prefijos permitidos por criticidad (vacío = todos los objetos)
allowed_prefixes = {
  Critico      = [] # Todos los objetos del bucket
  MenosCritico = [] # Todos los objetos del bucket
  NoCritico    = [] # Todos los objetos del bucket
}

# Tags para cost allocation y reportes
backup_tags = {
  ManagedBy    = "Terraform"
  Project      = "DataPlatformBackup"
  Environment  = "dev"
  Initiative   = "mvp"
  CostStrategy = "optimized"
  Owner        = "DataEngineering"
}

# ----------------------------------------------------------------------------
# CONTROL DE PRIMERA CORRIDA Y FALLBACK
# ----------------------------------------------------------------------------

# Si true, la primera corrida incremental se ejecuta como FULL
# FALSE recomendado: permite que incrementales sean siempre incrementales
force_full_on_first_run = false

# Límites para fallback cuando aún no existe S3 Inventory
fallback_max_objects        = 100000 # Máximo 100k objetos en fallback
fallback_time_limit_seconds = 300    # Máximo 5 minutos de listado

# ----------------------------------------------------------------------------
# REGLAS GFS (Grandfather-Father-Son) POR CRITICIDAD
# ----------------------------------------------------------------------------

gfs_rules = {
  # ========================================================================
  # CRÍTICO: RPO 12h - Retención máxima
  # ========================================================================
  Critico = {
    enable              = true
    start_storage_class = "GLACIER_IR" # Acceso rápido para incrementales

    # Son (Incrementales diarios)
    son_retention_days = 14 # 2 semanas de incrementales

    # Father (Full semanales)
    father_da_days        = 90  # A DEEP_ARCHIVE después de 90d (mínimo S3)
    father_retention_days = 365 # 1 año de retención total
    father_archive_class  = "DEEP_ARCHIVE"

    # Grandfather (Full mensuales - auditoría)
    grandfather_da_days        = 0   # A DEEP_ARCHIVE inmediatamente
    grandfather_retention_days = 730 # 2 años de auditoría
    grandfather_archive_class  = "DEEP_ARCHIVE"
  }

  # ========================================================================
  # MENOS CRÍTICO: RPO 24h - Retención media
  # ========================================================================
  MenosCritico = {
    enable              = true
    start_storage_class = "GLACIER_IR" # Acceso rápido para incrementales

    # Son (Incrementales diarios)
    son_retention_days = 7 # 1 semana de incrementales

    # Father (Full quincenales)
    father_da_days = 90 # A DEEP_ARCHIVE después de 90d
    # ✅ CORREGIDO: Aumentado de 91 a 120 para margen de seguridad
    # 91 días estaba muy cerca del mínimo de 90d para DEEP_ARCHIVE
    father_retention_days = 120 # ~4 meses de retención
    father_archive_class  = "DEEP_ARCHIVE"

    # Grandfather (Full trimestrales)
    grandfather_da_days        = 0   # A DEEP_ARCHIVE inmediatamente
    grandfather_retention_days = 365 # 1 año de auditoría
    grandfather_archive_class  = "DEEP_ARCHIVE"
  }

  # ========================================================================
  # NO CRÍTICO: Solo full mensuales - Retención mínima
  # ========================================================================
  NoCritico = {
    enable              = true
    start_storage_class = "GLACIER" # Más barato (no hay incrementales)

    # Son (Sin incrementales - ahorro de costos)
    son_retention_days = 0 # No genera incrementales

    # Father (Full mensuales únicamente)
    father_da_days        = 0  # Quedarse en GLACIER (no a DA)
    father_retention_days = 90 # Mínimo GLACIER (90 días)
    father_archive_class  = "GLACIER"

    # Grandfather (Deshabilitado - ahorro de costos)
    grandfather_da_days        = 0
    grandfather_retention_days = 0 # Sin retención larga
    grandfather_archive_class  = "GLACIER"
  }
}

# ----------------------------------------------------------------------------
# SCHEDULES DE BACKUP POR CRITICIDAD
# ----------------------------------------------------------------------------

schedule_expressions = {
  # ========================================================================
  # CRÍTICO: RPO 12h
  # ========================================================================
  Critico = {
    incremental = "rate(12 hours)"    # Cada 12h (cumple RPO)
    sweep       = "rate(7 days)"      # Full semanal (Father)
    grandfather = "cron(0 3 1 * ? *)" # 1ro de cada mes a las 3 AM UTC
  }

  # ========================================================================
  # MENOS CRÍTICO: RPO 24h
  # ========================================================================
  MenosCritico = {
    incremental = "rate(24 hours)"      # Cada 24h (cumple RPO)
    sweep       = "rate(14 days)"       # Full quincenal (Father)
    grandfather = "cron(0 3 1 */3 ? *)" # Cada 3 meses (trimestral) a las 3 AM UTC
  }

  # ========================================================================
  # NO CRÍTICO: Solo full mensuales (SIN incrementales para ahorro)
  # ========================================================================
  NoCritico = {
    # incremental: OMITIDO intencionalmente (ahorra ~90% en este tier)
    sweep = "rate(30 days)" # Full mensual únicamente
    # grandfather: OMITIDO intencionalmente (ahorro adicional)
  }
}

# ----------------------------------------------------------------------------
# VALIDACIONES DE S3
# ----------------------------------------------------------------------------

# Mínimo requerido por S3 entre GLACIER_IR y DEEP_ARCHIVE
min_deep_archive_offset_days = 90

# ----------------------------------------------------------------------------
# SEGURIDAD (OPCIONAL - Por defecto deshabilitado)
# ----------------------------------------------------------------------------

# Object Lock - Protección WORM (Write Once Read Many)
# ⚠️ IMPORTANTE: Habilitar esto requiere RECREAR el bucket
enable_object_lock         = false
object_lock_mode           = "COMPLIANCE" # O "GOVERNANCE"
object_lock_retention_days = 0            # 0 = deshabilitado

# Políticas de denegación de borrado
deny_delete_enabled     = false
allow_delete_principals = [] # ARNs de roles/users breakglass
require_mfa_for_delete  = false

# ----------------------------------------------------------------------------
# LIFECYCLE RULES LEGACY (DEPRECATED - Mantener para compatibilidad)
# ----------------------------------------------------------------------------
# ⚠️ NOTA: Estas reglas están deshabilitadas cuando gfs_rules.enable=true
# Se mantienen solo para compatibilidad con versiones anteriores

lifecycle_rules = {
  Critico = {
    glacier_transition_days             = 0
    deep_archive_transition_days        = 90
    expiration_days                     = 365
    incremental_expiration_days         = 14
    incremental_glacier_transition_days = 0
    use_glacier_ir                      = true
  }

  MenosCritico = {
    glacier_transition_days             = 0
    deep_archive_transition_days        = 90
    expiration_days                     = 120 # ✅ CORREGIDO: Era 90
    incremental_expiration_days         = 7
    incremental_glacier_transition_days = 0
    use_glacier_ir                      = true
  }

  NoCritico = {
    glacier_transition_days             = 0
    deep_archive_transition_days        = 0
    expiration_days                     = 90
    incremental_expiration_days         = 0
    incremental_glacier_transition_days = 0
    use_glacier_ir                      = false
  }
}

# ============================================================================
# NOTAS DE CONFIGURACIÓN
# ============================================================================
#
# 1. ESTRUCTURA DE COSTOS OPTIMIZADA:
#    - Crítico: Incrementales cada 12h + Full semanal + Auditoría mensual
#    - MenosCrítico: Incrementales cada 24h + Full quincenal + Auditoría trimestral
#    - NoCrítico: Solo Full mensual (sin incrementales ni grandfather)
#    - Ahorro estimado: 65-68% vs configuración estándar
#
# 2. RETENCIONES GFS:
#    - Son (incrementales): 7-14 días según criticidad
#    - Father (full regulares): 90-365 días según criticidad
#    - Grandfather (auditoría): 365-730 días para Crítico/MenosCrítico, 0 para NoCrítico
#
# 3. TRANSICIONES A DEEP_ARCHIVE:
#    - S3 requiere MÍNIMO 90 días entre GLACIER_IR y DEEP_ARCHIVE
#    - Father: 90 días de offset (configurado)
#    - Grandfather: Inmediato a DEEP_ARCHIVE (0 días)
#
# 4. ESTRATEGIA POR CRITICIDAD:
#    - Tag "BackupCriticality" en buckets origen determina el tier
#    - Valores válidos: "Critico", "MenosCritico", "NoCritico"
#    - Buckets sin tag → default "MenosCritico"
#
# 5. FALLBACK DE INVENTARIO:
#    - Límites activos solo cuando S3 Inventory aún no está disponible
#    - Después del primer inventario diario, estos límites no aplican
#    - Previene timeouts en buckets muy grandes en primera ejecución
#
# 6. SEGURIDAD:
#    - Por defecto: Sin Object Lock (más flexible, menos costo)
#    - Cifrado: AES256 por defecto en bucket central
#    - Opción de habilitar Object Lock si se requiere compliance estricto
#
# 7. EJECUCIÓN:
#    - Desde directorio raíz: terraform init && terraform plan
#    - Los tfvars de central-resources/ e initiative-logic/ son IGNORADOS
#    - Solo este archivo se lee cuando se ejecuta desde root
#
# ============================================================================
