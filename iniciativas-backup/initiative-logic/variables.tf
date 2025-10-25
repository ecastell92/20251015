# ============================================================================
# Initiative Logic Module - Variables
# ASCII-only comments for consistent readability across IDE/CI
# ============================================================================

variable "aws_region" {
  description = "The AWS region for this initiative"
  type        = string
}

variable "iniciativa" {
  description = "Short name of the initiative using the backup system"
  type        = string
}

variable "environment" {
  description = "Deployment environment tag (e.g., DEV, PRO)"
  type        = string
}

variable "tenant" {
  description = "Short name of the tenant or business unit"
  type        = string
}

# ─────────────────────────────────────────────────────────────────────────────
# BUCKET CENTRAL
# ─────────────────────────────────────────────────────────────────────────────

variable "central_backup_bucket_name" {
  description = "Nombre del bucket central de backups"
  type        = string
}

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURACIÓN DE BACKUPS
# ─────────────────────────────────────────────────────────────────────────────

variable "criticality_tag" {
  description = "Tag key que define criticidad"
  type        = string
}

variable "allowed_prefixes" {
  description = "Prefijos permitidos por criticidad"
  type        = map(list(string))
  default = {
    Critico      = [""],
    MenosCritico = [""],
    NoCritico    = [""],
  }
}

variable "exclude_key_prefixes" {
  description = "Prefijos a excluir en incrementales (p. ej. temporales)"
  type        = list(string)
  default     = ["temporary/", "sparkHistoryLogs/"]
}

variable "exclude_key_suffixes" {
  description = "Sufijos a excluir en incrementales (p. ej. .inprogress o marcadores de carpeta)"
  type        = list(string)
  default     = [".inprogress", "/"]
}

variable "schedule_expressions" {
  description = "Expresiones de schedule por criticidad"
  type = map(object({
    incremental = optional(string)
    sweep       = string
    grandfather = optional(string)
  }))
}

variable "backup_tags" {
  description = "Tags para recursos de backup"
  type        = map(string)
}

# ---------------------------------------------------------------------------
# MONITOREO / DASHBOARD
# ---------------------------------------------------------------------------

variable "enable_cloudwatch_dashboard" {
  description = "Crear un CloudWatch Dashboard con métricas de Lambdas, SQS, Step Functions, S3 y coste (Billing)"
  type        = bool
  default     = true
}

# ---------------------------------------------------------------------------
# BACKUP CONFIGURATIONS (Lambda) - toggles y filtros
# ---------------------------------------------------------------------------

variable "backup_config_log_level" {
  description = "Nivel de log para la Lambda de backup de configuraciones"
  type        = string
  default     = "INFO"
}

variable "backup_config_tag_filter_key" {
  description = "Tag key para filtrar buckets/recursos a exportar"
  type        = string
  default     = "BackupEnabled"
}

variable "backup_config_tag_filter_value" {
  description = "Valor del tag para filtrar recursos a exportar"
  type        = string
  default     = "true"
}


variable "sufijo_recursos" {
  description = "Sufijo para nombres únicos"
  type        = string
}

# ─────────────────────────────────────────────────────────────────────────────
# CONTROL DE BACKUPS
# ─────────────────────────────────────────────────────────────────────────────

variable "force_full_on_first_run" {
  description = "Forzar full en primera corrida incremental"
  type        = bool
}

variable "fallback_max_objects" {
  description = "Límite de objetos en fallback"
  type        = number
}

variable "fallback_time_limit_seconds" {
  description = "Tiempo máximo para fallback"
  type        = number
}

variable "backup_config_include_glue" {
  description = "Incluir export de configuraciones de AWS Glue"
  type        = bool
  default     = true
}

variable "backup_config_include_athena" {
  description = "Incluir export de configuraciones de AWS Athena"
  type        = bool
  default     = true
}

variable "backup_config_include_lambda" {
  description = "Incluir export de configuraciones de AWS Lambda"
  type        = bool
  default     = true
}

variable "backup_config_include_iam" {
  description = "Incluir export de configuraciones de IAM"
  type        = bool
  default     = true
}

variable "backup_config_include_stepfunctions" {
  description = "Incluir export de configuraciones de Step Functions"
  type        = bool
  default     = true
}

variable "backup_config_include_eventbridge" {
  description = "Incluir export de configuraciones de EventBridge"
  type        = bool
  default     = true
}

variable "backup_config_include_dynamodb" {
  description = "Incluir export de configuraciones de DynamoDB"
  type        = bool
  default     = false
}

variable "backup_config_include_rds" {
  description = "Incluir export de configuraciones de RDS"
  type        = bool
  default     = false
}

# Optional: KMS keys used to encrypt source S3 objects. If provided,
# S3 Batch Operations role will get kms:Decrypt permissions to read them.
variable "source_kms_key_arns" {
  description = "Lista de ARNs de llaves KMS usadas por buckets origen (para permitir kms:Decrypt en copias Batch)"
  type        = list(string)
  default     = []
}

variable "kms_allow_viaservice" {
  description = "Permitir kms:Decrypt para cualquier CMK en la región vía servicio S3 (condicionado por kms:ViaService). Útil cuando hay múltiples llaves en origen."
  type        = bool
  default     = true
}

# Controla si la lambda incremental usa checkpoints por ventana
variable "disable_window_checkpoint" {
  description = "Deshabilitar checkpoint por ventana en incrementales (evita saltar objetos posteriores en la misma ventana)"
  type        = bool
  default     = true
}
# Control de log para la Lambda incremental
variable "incremental_log_level" {
  description = "Nivel de log para la Lambda incremental (DEBUG, INFO, WARNING, ERROR)"
  type        = string
  default     = "INFO"
}
