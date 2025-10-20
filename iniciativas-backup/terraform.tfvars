# ============================================================================
# CONFIGURACIÓN DE BACKUPS S3 - TERRAFORM.TFVARS
# ============================================================================
# Este archivo contiene la configuración principal del sistema de backups.
# CAMBIAR VALORES AQUÍ ACTUALIZA TODO EL SISTEMA AUTOMÁTICAMENTE
# ============================================================================

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURACIÓN BÁSICA
# ─────────────────────────────────────────────────────────────────────────────

aws_region  = "eu-west-1"
environment = "dev"
tenant      = "00"
iniciativa  = "mvp"
cuenta      = "905418243844"

# ID de la cuenta CENTRAL donde vive el bucket de backups.
# Si coincide con la cuenta actual, manténlo igual que "cuenta".
central_account_id = "905418243844"


# ─────────────────────────────────────────────────────────────────────────────
# BUCKET CENTRAL (REQUERIDO)
# ─────────────────────────────────────────────────────────────────────────────

central_backup_bucket_name = "00-dev-s3-bucket-central-bck-001-aws-notinet"
central_backup_vault_name  = "00-dev-s3-aws-vault-bck-001-aws"
sufijo_recursos            = "bck-001-aws-notinet"

# ─────────────────────────────────────────────────────────────────────────────
# SCHEDULES POR CRITICIDAD (REQUERIDO)
# ─────────────────────────────────────────────────────────────────────────────
# Define cuándo se ejecutan los backups para cada nivel de criticidad
# 
# incremental: Backups incrementales (opcional - solo si RPO < 24h)
# sweep:       Backups full regulares (Father generation)
# grandfather: Backups full de larga retención (opcional)
# ─────────────────────────────────────────────────────────────────────────────

schedule_expressions = {
  # ========================================================================
  # CRÍTICO: RPO 12 horas
  # ========================================================================
  Critico = {
    incremental = "rate(12 hours)"    # Cada 12h
    sweep       = "rate(7 days)"      # Full semanal
    grandfather = "cron(0 3 1 * ? *)" # Full mensual (1er día, 3 AM UTC)
  }

  # ========================================================================
  # MENOS CRÍTICO: RPO 24 horas
  # ========================================================================
  MenosCritico = {
    incremental = "rate(24 hours)"      # Cada 24h
    sweep       = "rate(14 days)"       # Full quincenal
    grandfather = "cron(0 3 1 */3 ? *)" # Full trimestral
  }

  # ========================================================================
  # NO CRÍTICO: Solo full mensuales (SIN incrementales para ahorrar)
  # ========================================================================
  NoCritico = {
    # incremental: OMITIDO intencionalmente (ahorro de costos)
    sweep = "rate(30 days)" # Full mensual únicamente
    # grandfather: OMITIDO intencionalmente (ahorro de costos)
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# REGLAS GFS POR CRITICIDAD (REQUERIDO)
# ─────────────────────────────────────────────────────────────────────────────
# Grandfather-Father-Son: Define retenciones y storage classes
# 
# Son:         Incrementales diarios
# Father:      Full semanales/quincenales
# Grandfather: Full mensuales/trimestrales para auditoría
# ─────────────────────────────────────────────────────────────────────────────

gfs_rules = {
  # ══════════════════════════════════════════════════════════════════════════
  # CRÍTICO: Retención extendida (14d/365d/730d)
  # ══════════════════════════════════════════════════════════════════════════
  Critico = {
    enable              = true
    start_storage_class = "GLACIER_IR" # Acceso rápido

    # Son: Incrementales cada 12h
    son_retention_days = 14 # 2 semanas

    # Father: Full semanales
    father_da_days        = 90  # Transición a DEEP_ARCHIVE a los 90d
    father_retention_days = 365 # Retener 1 año
    father_archive_class  = "DEEP_ARCHIVE"

    # Grandfather: Full mensuales (auditoría)
    grandfather_da_days        = 0   # DEEP_ARCHIVE inmediato
    grandfather_retention_days = 730 # Retener 2 años
    grandfather_archive_class  = "DEEP_ARCHIVE"
  }

  # ══════════════════════════════════════════════════════════════════════════
  # MENOS CRÍTICO: Retención moderada (7d/120d/365d)
  # ══════════════════════════════════════════════════════════════════════════
  MenosCritico = {
    enable              = true
    start_storage_class = "GLACIER_IR"

    # Son: Incrementales cada 24h
    son_retention_days = 7 # 1 semana

    # Father: Full quincenales
    father_da_days        = 90  # Transición a DEEP_ARCHIVE
    father_retention_days = 120 # ~4 meses
    father_archive_class  = "DEEP_ARCHIVE"

    # Grandfather: Full trimestrales
    grandfather_da_days        = 0   # DEEP_ARCHIVE inmediato
    grandfather_retention_days = 365 # 1 año
    grandfather_archive_class  = "DEEP_ARCHIVE"
  }

  # ══════════════════════════════════════════════════════════════════════════
  # NO CRÍTICO: Retención mínima (solo 90d full, sin incrementales)
  # ══════════════════════════════════════════════════════════════════════════
  NoCritico = {
    enable              = true
    start_storage_class = "GLACIER" # Más barato (sin recuperación rápida)

    # Son: Sin incrementales (ahorro máximo)
    son_retention_days = 0

    # Father: Solo full mensuales
    father_da_days        = 0  # Permanecer en GLACIER
    father_retention_days = 90 # Mínimo requerido por GLACIER
    father_archive_class  = "GLACIER"

    # Grandfather: Deshabilitado (ahorro)
    grandfather_da_days        = 0
    grandfather_retention_days = 0
    grandfather_archive_class  = "GLACIER"
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURACIÓN DE TAGS Y PREFIJOS
# ─────────────────────────────────────────────────────────────────────────────

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

# ─────────────────────────────────────────────────────────────────────────────
# CONTROL DE PRIMERA CORRIDA Y FALLBACK
# ─────────────────────────────────────────────────────────────────────────────

force_full_on_first_run     = false  # Incrementales siempre son incrementales
fallback_max_objects        = 100000 # Límite en fallback (sin inventario)
fallback_time_limit_seconds = 300    # 5 minutos máximo

# ─────────────────────────────────────────────────────────────────────────────
# VALIDACIONES Y SEGURIDAD
# ─────────────────────────────────────────────────────────────────────────────

min_deep_archive_offset_days = 90 # Requisito S3: mínimo entre GLACIER_IR y DA

# Seguridad (opcional - por defecto deshabilitado)
enable_object_lock         = false
object_lock_mode           = "COMPLIANCE"
object_lock_retention_days = 0
deny_delete_enabled        = false
allow_delete_principals    = []
require_mfa_for_delete     = false

# ─────────────────────────────────────────────────────────────────────────────
# LIFECYCLE RULES LEGACY (DEPRECATED - mantener por compatibilidad)
# ─────────────────────────────────────────────────────────────────────────────

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
    expiration_days                     = 120
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

# ═════════════════════════════════════════════════════════════════════════════
#  EJEMPLOS DE CONFIGURACIÓN
# ═════════════════════════════════════════════════════════════════════════════

# ─────────────────────────────────────────────────────────────────────────────
# EJEMPLO 1: RPO MÁS AGRESIVO (6 HORAS PARA CRÍTICO)
# ─────────────────────────────────────────────────────────────────────────────
#
# backup_frequencies = {
#   critical_hours      = 6   # Cada 6 horas (event-driven)
#   less_critical_hours = 24
#   non_critical_hours  = 168
# }
#
# RESULTADO AUTOMÁTICO:
# ├─ Crítico: rate(6 hours)
# ├─ Método: incremental_backup (event-driven)
# ├─ Storage: GLACIER_IR
# ├─ Retención: 14 días incrementales
# └─ RPO: 6 horas

# ─────────────────────────────────────────────────────────────────────────────
# EJEMPLO 2: CAMBIAR A MANIFEST DIFF PARA MENOS CRÍTICO
# ─────────────────────────────────────────────────────────────────────────────
#
# backup_frequencies = {
#   critical_hours      = 12
#   less_critical_hours = 36  # Más de 24h → cambia a manifest diff
#   non_critical_hours  = 168
# }
#
# RESULTADO AUTOMÁTICO:
# ├─ Menos Crítico: rate(36 hours)
# ├─ Método: filter_inventory (manifest diff)
# ├─ Usa checkpoint para comparación
# ├─ Storage: GLACIER_IR
# └─ Retención: 7 días incrementales

# ─────────────────────────────────────────────────────────────────────────────
# EJEMPLO 3: BACKUPS MENSUALES PARA NO CRÍTICO
# ─────────────────────────────────────────────────────────────────────────────
#
# backup_frequencies = {
#   critical_hours      = 12
#   less_critical_hours = 24
#   non_critical_hours  = 720  # 30 días
# }
#
# RESULTADO AUTOMÁTICO:
# ├─ No Crítico: rate(720 hours)
# ├─ Método: manifest_diff (solo full)
# ├─ Sin incrementales automáticos
# ├─ Storage: GLACIER
# └─ Retención: 90 días

# ═════════════════════════════════════════════════════════════════════════════
# 🔍 CÓMO FUNCIONA EL ROUTING AUTOMÁTICO
# ═════════════════════════════════════════════════════════════════════════════
#
# El sistema decide automáticamente el método de backup:
#
# ┌──────────────────────────────────────────────────────────────────────────┐
# │ PASO 1: Usuario cambia backup_frequencies                               │
# └──────────────────────────────────────────────────────────────────────────┘
#                                   │
#                                   ▼
# ┌──────────────────────────────────────────────────────────────────────────┐
# │ PASO 2: Terraform evalúa: frecuencia < 24h ?                            │
# └──────────────────────────────────────────────────────────────────────────┘
#                     │                                │
#                     │ SÍ                             │ NO
#                     ▼                                ▼
#     ┌───────────────────────────┐      ┌──────────────────────────────┐
#     │ METHOD: event_driven      │      │ METHOD: manifest_diff        │
#     │                           │      │                              │
#     │ - Habilita Lambda         │      │ - Usa filter_inventory       │
#     │   incremental_backup      │      │ - Compara con checkpoint     │
#     │ - Configura SQS trigger   │      │ - Schedule via EventBridge   │
#     │ - Genera schedule rate(Xh)│      │ - Genera schedule rate(Xh)   │
#     └───────────────────────────┘      └──────────────────────────────┘
#                     │                                │
#                     └────────────┬───────────────────┘
#                                  │
#                                  ▼
#             ┌─────────────────────────────────────────┐
#             │ PASO 3: Aplica storage class y          │
#             │         retenciones según criticidad    │
#             └─────────────────────────────────────────┘
#
# ═════════════════════════════════════════════════════════════════════════════

# ═════════════════════════════════════════════════════════════════════════════
# 💡 TIPS DE CONFIGURACIÓN
# ═════════════════════════════════════════════════════════════════════════════
#
# 1. CAMBIAR FRECUENCIAS:
#    - Solo modificar backup_frequencies
#    - El resto se adapta automáticamente
#
# 2. VALIDAR CAMBIOS:
#    terraform plan | grep -A 20 "backup_configuration_summary"
#
# 3. MONITOREAR MÉTODO USADO:
#    - Logs de Lambda incremental_backup → event-driven
#    - Logs de Lambda filter_inventory → manifest_diff
#
# 4. COSTOS:
#    - Event-driven: Más API calls, mejor RPO
#    - Manifest diff: Menos API calls, RPO más relajado
#
# 5. RECOMENDACIONES POR RPO:
#    - RPO < 1h:  No recomendado (demasiados incrementales)
#    - RPO 4-12h: Óptimo para crítico (event-driven)
#    - RPO 24h:   Óptimo para menos crítico (event-driven o manifest)
#    - RPO >24h:  Usar manifest diff (más eficiente)
#
# ═════════════════════════════════════════════════════════════════════════════
