# ============================================================================
# Initiative Logic - ESTRATEGIA ECONÓMICA
# ============================================================================
# Schedules optimizados para cumplir RPO con mínimo costo
# ============================================================================

# ----------------------------------------------------------------------------
# CONFIGURACIÓN BÁSICA
# ----------------------------------------------------------------------------

aws_region         = "eu-west-1"
iniciativa         = "mvp"
environment        = "dev"
tenant             = "00"
central_account_id = "905418243844"

central_backup_bucket_name = "00-dev-s3-bucket-central-bck-001-aws-notinet"

criticality_tag = "BackupCriticality"
sufijo_recursos = "bck-001-aws-notinet"

# ----------------------------------------------------------------------------
# PREFIJOS PERMITIDOS (Vacío = todos los objetos)
# ----------------------------------------------------------------------------

allowed_prefixes = {
  Critico      = [] # Todos los objetos
  MenosCritico = [] # Todos los objetos
  NoCritico    = [] # Todos los objetos
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
# TAGS PARA REPORTES DE COSTOS
# ----------------------------------------------------------------------------

backup_tags = {
  ManagedBy    = "Terraform"
  Project      = "DataPlatformBackup"
  Environment  = "dev"
  Initiative   = "mvp"
  CostStrategy = "optimized"
}

# ----------------------------------------------------------------------------
# CONTROL DE PRIMERA CORRIDA Y FALLBACK
# ----------------------------------------------------------------------------

# FALSE: Incrementales siempre son incrementales (no forzar full en primera corrida)
force_full_on_first_run = false

# Límites para fallback cuando no hay S3 Inventory aún
fallback_max_objects        = 100000 # Máximo 100k objetos en fallback
fallback_time_limit_seconds = 300    # Máximo 5 minutos de listado

# ============================================================================
# NOTAS IMPORTANTES
# ============================================================================
#
# 1. **NoCritico sin incrementales**: Solo se hacen full mensuales
#    - Ahorra ~90% de costos en buckets no críticos
#
# 2. **Father quincenal para MenosCritico**: vs semanal = 50% menos full backups
#
# 3. **Grandfather deshabilitado en NoCritico**: Ahorro adicional
#
# 4. **Retención mínima**: Ver central-resources/terraform.tfvars
#    - Crítico: 14d incrementales, 1 año full, 2 años auditoría
#    - MenosCritico: 7d incrementales, 90d full, 1 año auditoría
#    - NoCritico: Solo 90d full
#
# ============================================================================
