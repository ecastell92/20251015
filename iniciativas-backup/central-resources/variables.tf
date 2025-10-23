// ============================================================================
// Variables del Módulo: Central Resources - VERSIÓN CORREGIDA
// ============================================================================

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURACIÓN BÁSICA
# ─────────────────────────────────────────────────────────────────────────────

# ============================================================================
# Central Resources Module - Variables
# ASCII-only comments for consistent readability across IDE/CI
# ============================================================================

variable "aws_region" {
  description = "Región de AWS donde se despliegan los recursos centrales"
  type        = string
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
  description = "Nombre de la Iniciativa"
  type        = string
}

# ─────────────────────────────────────────────────────────────────────────────
# BUCKET CENTRAL - NOMENCLATURA UNIFICADA
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

# Controla si se crea el bucket central de S3 (si solo usas RDS/DynamoDB, desactivarlo)
variable "enable_central_bucket" {
  description = "Crear bucket y recursos S3 en este modulo"
  type        = bool
  default     = true
}

variable "sufijo_recursos" {
  description = "Sufijo para asegurar unicidad en nombres de recursos"
  type        = string
  default     = "v1"
}

# ─────────────────────────────────────────────────────────────────────────────
# REGLAS GFS
# ─────────────────────────────────────────────────────────────────────────────

variable "gfs_rules" {
  description = "Configuración GFS por criticidad"
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
}

# ─────────────────────────────────────────────────────────────────────────────
# VALIDACIONES S3
# ─────────────────────────────────────────────────────────────────────────────

variable "min_deep_archive_offset_days" {
  description = "Offset mínimo entre GLACIER_IR y DEEP_ARCHIVE"
  type        = number
}

# ---------------------------------------------------------------------------
# LIMPIEZA DE ARCHIVOS OPERACIONALES (configurable)
# ---------------------------------------------------------------------------

variable "cleanup_inventory_source_days" {
  description = "Días para expirar inventarios de origen en el bucket central"
  type        = number
  default     = 7
}

variable "cleanup_batch_reports_days" {
  description = "Días para expirar reportes de S3 Batch en el bucket central"
  type        = number
  default     = 7
}

variable "cleanup_checkpoints_days" {
  description = "Días para expirar checkpoints en el bucket central"
  type        = number
  default     = 7
}

variable "cleanup_manifests_temp_days" {
  description = "Días para expirar manifiestos temporales en el bucket central"
  type        = number
  default     = 7
}

# Retención para respaldos de configuraciones (backup/configurations)
variable "cleanup_configurations_days" {
  description = "Días para expirar los JSON de configuraciones guardados bajo backup/configurations"
  type        = number
  default     = 90
}


# ─────────────────────────────────────────────────────────────────────────────
# SEGURIDAD
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

  validation {
    condition     = var.object_lock_retention_days >= 0
    error_message = "La retención debe ser >= 0."
  }
}

variable "deny_delete_enabled" {
  description = "Habilitar política de denegación de borrado con excepciones breakglass"
  type        = bool
  default     = false
}

variable "allow_delete_principals" {
  description = "Lista de ARNs de IAM permitidos para borrar (breakglass)"
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for arn in var.allow_delete_principals : can(regex("^arn:aws:iam::[0-9]{12}:(role|user)/", arn))
    ])
    error_message = "Los ARNs deben ser válidos ARNs de IAM role o user."
  }
}

variable "require_mfa_for_delete" {
  description = "Requerir MFA para operaciones de borrado"
  type        = bool
  default     = true
}

# ─────────────────────────────────────────────────────────────────────────────
# REGLAS DE LIFECYCLE LEGACY (Para compatibilidad - DEPRECATED)
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
    Critico      = { glacier_transition_days = 0, deep_archive_transition_days = 90, expiration_days = 1825, incremental_expiration_days = 45, incremental_glacier_transition_days = 0, use_glacier_ir = true }
    MenosCritico = { glacier_transition_days = 0, deep_archive_transition_days = 90, expiration_days = 1095, incremental_expiration_days = 30, incremental_glacier_transition_days = 0, use_glacier_ir = true }
    NoCritico    = { glacier_transition_days = 0, deep_archive_transition_days = 0, expiration_days = 90, incremental_expiration_days = 21, incremental_glacier_transition_days = 0, use_glacier_ir = false }
  }
}
