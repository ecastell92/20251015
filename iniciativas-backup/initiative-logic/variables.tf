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

variable "central_account_id" {
  description = "AWS Account ID de la cuenta central donde reside el bucket de backups"
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
