# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURACIÓN BÁSICA
# ─────────────────────────────────────────────────────────────────────────────

# ============================================================================
# Root Module - Variables
# ASCII-only comments for consistent readability across IDE/CI
# ============================================================================

variable "aws_region" {
  description = "Región de AWS donde se despliegan todos los recursos"
  type        = string
  default     = "eu-west-1"
}

variable "environment" {
  description = "Entorno de despliegue (dev, staging, prod)"
  type        = string

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "El ambiente debe ser: dev, staging, o prod."
  }
}

variable "tenant" {
  description = "Nombre corto del tenant o unidad de negocio"
  type        = string
}

variable "iniciativa" {
  description = "Nombre corto de la iniciativa que usa el sistema de backup"
  type        = string
}

variable "cuenta" {
  description = "ID de la cuenta de AWS donde se despliegan los recursos"
  type        = string
}

# ─────────────────────────────────────────────────────────────────────────────
# BUCKET CENTRAL
# ─────────────────────────────────────────────────────────────────────────────

# variable "central_backup_bucket_name" {
#   description = "Nombre COMPLETO del bucket central de backups (debe ser globalmente único)"
#   type        = string

#   validation {
#     condition     = can(regex("^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$", var.central_backup_bucket_name))
#     error_message = "El nombre del bucket debe cumplir con las reglas de S3: minúsculas, números, guiones, 3-63 caracteres."
#   }
# }

variable "central_backup_vault_name" {
  description = "Nombre del AWS Backup Vault"
  type        = string
}

variable "sufijo_recursos" {
  description = "Sufijo para asegurar unicidad en nombres de recursos"
  type        = string
}

# ─────────────────────────────────────────────────────────────────────────────
# REGLAS GFS (Grandfather-Father-Son)
# ─────────────────────────────────────────────────────────────────────────────

variable "gfs_rules" {
  description = <<-EOT
    Configuración de retención GFS por criticidad.
    
    Estructura por criticidad:
    - enable: Habilitar reglas GFS
    - start_storage_class: Clase inicial (STANDARD, GLACIER_IR, GLACIER)
    - son_retention_days: Retención de incrementales (Son)
    - father_da_days: Días antes de DEEP_ARCHIVE para Father
    - father_retention_days: Retención total de Father
    - father_archive_class: Clase de archivo para Father
    - grandfather_da_days: Días antes de DEEP_ARCHIVE para Grandfather
    - grandfather_retention_days: Retención total de Grandfather
    - grandfather_archive_class: Clase de archivo para Grandfather
  EOT

  type = map(object({
    enable                     = bool
    start_storage_class        = string
    son_retention_days         = number
    father_da_days             = number
    father_retention_days      = number
    father_archive_class       = string
    grandfather_da_days        = number
    grandfather_retention_days = number
    grandfather_archive_class  = string
  }))

  validation {
    condition = alltrue([
      for k, v in var.gfs_rules : (
        v.enable == false ||
        (v.father_da_days == 0 || v.father_da_days >= 90) &&
        (v.grandfather_da_days == 0 || v.grandfather_da_days >= 90)
      )
    ])
    error_message = "Las transiciones a DEEP_ARCHIVE deben ser >= 90 días o 0 para deshabilitarlas."
  }
}



# ─────────────────────────────────────────────────────────────────────────────
# SEGURIDAD (Opcional)
# ─────────────────────────────────────────────────────────────────────────────

variable "enable_object_lock" {
  description = "Habilitar S3 Object Lock en el bucket (requiere recreación del bucket)"
  type        = bool
  default     = false
}

variable "object_lock_mode" {
  description = "Modo de Object Lock: COMPLIANCE o GOVERNANCE"
  type        = string
  default     = "COMPLIANCE"

  validation {
    condition     = contains(["COMPLIANCE", "GOVERNANCE"], var.object_lock_mode)
    error_message = "El modo debe ser COMPLIANCE o GOVERNANCE."
  }
}

variable "object_lock_retention_days" {
  description = "Días de retención por defecto de Object Lock (0 = deshabilitado)"
  type        = number
  default     = 0
}

variable "deny_delete_enabled" {
  description = "Habilitar política de denegación de borrado"
  type        = bool
  default     = false
}

variable "allow_delete_principals" {
  description = "Lista de ARNs de IAM permitidos para borrar (breakglass)"
  type        = list(string)
  default     = []
}

variable "require_mfa_for_delete" {
  description = "Requerir MFA para operaciones de borrado"
  type        = bool
  default     = false
}

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURACIÓN DE BACKUPS
# ─────────────────────────────────────────────────────────────────────────────

variable "criticality_tag" {
  description = "Tag key que define la criticidad en los recursos"
  type        = string
  default     = "BackupCriticality"
}

variable "allowed_prefixes" {
  description = "Prefijos permitidos por criticidad para backups incrementales"
  type        = map(list(string))
  default = {
    Critico      = []
    MenosCritico = []
    NoCritico    = []
  }
}

variable "schedule_expressions" {
  description = "Expresiones de schedule por criticidad (incremental, sweep, grandfather)"
  type = map(object({
    incremental = optional(string)
    sweep       = string
    grandfather = optional(string)
  }))
}

variable "force_full_on_first_run" {
  description = "Si true, la primera corrida incremental se ejecuta como FULL"
  type        = bool
  default     = false
}

variable "fallback_max_objects" {
  description = "Límite máximo de objetos en fallback (null = sin límite)"
  type        = number
  default     = 100000
}

variable "fallback_time_limit_seconds" {
  description = "Tiempo máximo (segundos) para fallback (null = sin límite)"
  type        = number
  default     = 300
}

variable "backup_tags" {
  description = "Tags aplicados a recursos de backup para cost allocation"
  type        = map(string)
  default     = {}
}

// ---------------------------------------------------------------------------
// BACKUP CONFIGURATIONS (Lambda) - toggles y filtros
// ---------------------------------------------------------------------------

variable "backup_config_log_level" {
  description = "Nivel de log para la Lambda de backup de configuraciones"
  type        = string
  default     = "INFO"
}

variable "backup_config_tag_filter_key" {
  description = "Tag key para filtrar buckets/recursos que exporta la Lambda de configuraciones"
  type        = string
  default     = "BackupEnabled"
}

variable "backup_config_tag_filter_value" {
  description = "Valor del tag para filtrar recursos en la Lambda de configuraciones"
  type        = string
  default     = "true"
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


variable "min_deep_archive_offset_days" {
  description = "Offset mínimo entre GLACIER_IR y DEEP_ARCHIVE (requisito S3)"
  type        = number
  default     = 90

  validation {
    condition     = var.min_deep_archive_offset_days >= 90
    error_message = "S3 requiere mínimo 90 días entre GLACIER_IR y DEEP_ARCHIVE."
  }
}

// ---------------------------------------------------------------------------
// Central-resources: limpieza operativa (expuesto en root)
// ---------------------------------------------------------------------------

variable "cleanup_inventory_source_days" {
  description = "Dias para expirar inventarios de origen en el bucket central"
  type        = number
}

variable "cleanup_batch_reports_days" {
  description = "Dias para expirar reportes de S3 Batch en el bucket central"
  type        = number
}

variable "cleanup_checkpoints_days" {
  description = "Dias para expirar checkpoints en el bucket central"
  type        = number
}

variable "cleanup_manifests_temp_days" {
  description = "Dias para expirar manifiestos temporales en el bucket central"
  type        = number
}

# ─────────────────────────────────────────────────────────────────────────────
# LIFECYCLE RULES LEGACY (DEPRECATED)
# ─────────────────────────────────────────────────────────────────────────────

variable "lifecycle_rules" {
  description = "DEPRECATED: Usar gfs_rules. Se mantiene por compatibilidad."
  type = map(object({
    glacier_transition_days             = number
    deep_archive_transition_days        = number
    expiration_days                     = number
    incremental_expiration_days         = number
    incremental_glacier_transition_days = number
    use_glacier_ir                      = bool
  }))

  default = {
    Critico      = { glacier_transition_days = 0, deep_archive_transition_days = 90, expiration_days = 365, incremental_expiration_days = 14, incremental_glacier_transition_days = 0, use_glacier_ir = false }
    MenosCritico = { glacier_transition_days = 0, deep_archive_transition_days = 90, expiration_days = 90, incremental_expiration_days = 7, incremental_glacier_transition_days = 0, use_glacier_ir = false }
    NoCritico    = { glacier_transition_days = 0, deep_archive_transition_days = 0, expiration_days = 90, incremental_expiration_days = 0, incremental_glacier_transition_days = 0, use_glacier_ir = false }
  }
}

variable "disable_window_checkpoint" {
  description = "Deshabilitar checkpoints de ventana en backups incrementales"
  type        = bool
  default     = true
}

# Prefijos/sufijos a excluir en incrementales (opcional)
variable "exclude_key_prefixes" {
  description = "Prefijos a excluir en incrementales. VACÍO por defecto = copiar todo menos exclusiones técnicas."
  type        = list(string)
  default     = [] # ✅ CORREGIDO: Vacío por defecto
}

variable "exclude_key_suffixes" {
  description = "Sufijos a excluir. Por defecto SOLO marcadores de carpeta."
  type        = list(string)
  default     = ["/"] # ✅ CORREGIDO: Solo marcadores de carpeta
}

# Nivel de log para Lambda incremental
variable "incremental_log_level" {
  description = "Nivel de log para la Lambda incremental (DEBUG, INFO, WARNING, ERROR)"
  type        = string
  default     = "INFO"
}

# KMS en origen
variable "source_kms_key_arns" {
  description = "Lista de ARNs de CMKs usadas por buckets origen para permitir kms:Decrypt en S3 Batch"
  type        = list(string)
  default     = []
}

variable "kms_allow_viaservice" {
  description = "Permitir kms:Decrypt vía condición kms:ViaService=s3.<region>.amazonaws.com"
  type        = bool
  default     = true
}

# Retención de configuraciones (backup/configurations)
variable "cleanup_configurations_days" {
  description = "Dias para expirar JSON de configuraciones (backup/configurations)"
  type        = number
  default     = 90
}

# AWS Backup (RDS/DynamoDB)
variable "enable_backup_rds" {
  description = "Habilitar planes de AWS Backup para RDS (por tags)"
  type        = bool
  default     = false
}

variable "enable_backup_dynamodb" {
  description = "Habilitar planes de AWS Backup para DynamoDB (por tags)"
  type        = bool
  default     = false
}

# Habilitar el pipeline de backups de datos S3 (Lambdas + Step Functions + Scheduler)
variable "enable_s3_backups" {
  description = "Habilitar despliegue de pipeline S3 (incremental + barridos)"
  type        = bool
  default     = true
}

# Controla si se crea el bucket central S3 (si solo usas RDS/DynamoDB ponlo en false)
variable "enable_central_bucket" {
  description = "Crear el bucket central de S3 (recursos S3 del modulo central_resources)"
  type        = bool
  default     = true
}


variable "enable_cloudwatch_dashboard" {
  description = "Habilitar dashboard de CloudWatch para monitoreo de backups"
  type        = bool
  default     = false
}
