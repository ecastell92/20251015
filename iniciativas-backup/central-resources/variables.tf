// ============================================================================
// Variables del Módulo: Central Resources - VERSIÓN CORREGIDA
// ============================================================================

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURACIÓN BÁSICA
# ─────────────────────────────────────────────────────────────────────────────

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

# ─────────────────────────────────────────────────────────────────────────────
# BUCKET CENTRAL - NOMENCLATURA UNIFICADA
# ─────────────────────────────────────────────────────────────────────────────

variable "central_backup_bucket_name" {
  description = "Nombre COMPLETO del bucket central de backups (debe ser globalmente único)"
  type        = string
  
  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$", var.central_backup_bucket_name))
    error_message = "El nombre del bucket debe cumplir con las reglas de S3: minúsculas, números, guiones, 3-63 caracteres."
  }
}

variable "central_backup_vault_name" {
  description = "Nombre del AWS Backup Vault"
  type        = string
}

variable "sufijo_recursos" {
  description = "Sufijo para asegurar unicidad en nombres de recursos"
  type        = string
  default     = "v1"
}

# ─────────────────────────────────────────────────────────────────────────────
# REGLAS GFS (Grandfather-Father-Son) POR CRITICIDAD
# ─────────────────────────────────────────────────────────────────────────────

variable "gfs_rules" {
  description = <<-EOT
    Configuración de retención GFS por criticidad.
    
    Estructura:
    - enable: Habilitar reglas GFS para esta criticidad
    - start_storage_class: Clase de almacenamiento inicial (GLACIER_IR recomendado)
    - son_retention_days: Retención de backups incrementales (Son) en días
    - father_da_days: Días antes de transición a DEEP_ARCHIVE para Father (mínimo 90)
    - father_retention_days: Retención total de backups Father en días
    - father_archive_class: Clase de archivo para Father (DEEP_ARCHIVE)
    - grandfather_da_days: Días antes de transición a DEEP_ARCHIVE para Grandfather
    - grandfather_retention_days: Retención total de backups Grandfather en días
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
  
  default = {
    Critico = {
      enable                     = true
      start_storage_class        = "GLACIER_IR"
      son_retention_days         = 45      # 45 días de incrementales
      father_da_days             = 90      # Transición a DEEP_ARCHIVE a los 90 días
      father_retention_days      = 1825    # 5 años de retención
      father_archive_class       = "DEEP_ARCHIVE"
      grandfather_da_days        = 90
      grandfather_retention_days = 2555    # 7 años de retención
      grandfather_archive_class  = "DEEP_ARCHIVE"
    }
    
    MenosCritico = {
      enable                     = true
      start_storage_class        = "GLACIER_IR"
      son_retention_days         = 30      # 30 días de incrementales
      father_da_days             = 90
      father_retention_days      = 1095    # 3 años
      father_archive_class       = "DEEP_ARCHIVE"
      grandfather_da_days        = 90
      grandfather_retention_days = 1825    # 5 años
      grandfather_archive_class  = "DEEP_ARCHIVE"
    }
    
    NoCritico = {
      enable                     = true
      start_storage_class        = "GLACIER_IR"
      son_retention_days         = 0       # Sin incrementales
      father_da_days             = 0       # Sin transición a DEEP_ARCHIVE
      father_retention_days      = 365     # 1 año
      father_archive_class       = "GLACIER_IR"
      grandfather_da_days        = 0
      grandfather_retention_days = 730     # 2 años
      grandfather_archive_class  = "GLACIER_IR"
    }
  }
  
  validation {
    condition = alltrue([
      for k, v in var.gfs_rules : (
        v.enable == false ||
        (v.father_da_days == 0 || v.father_da_days >= 90) &&
        (v.grandfather_da_days == 0 || v.grandfather_da_days >= 90)
      )
    ])
    error_message = "Las transiciones a DEEP_ARCHIVE deben ser >= 90 días (requisito de S3) o 0 para deshabilitarlas."
  }
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
# VALIDACIONES DE S3
# ─────────────────────────────────────────────────────────────────────────────

variable "min_deep_archive_offset_days" {
  description = "Offset mínimo en días entre transiciones a GLACIER_IR y DEEP_ARCHIVE (requisito de S3)"
  type        = number
  default     = 90
  
  validation {
    condition     = var.min_deep_archive_offset_days >= 90
    error_message = "S3 requiere mínimo 90 días entre GLACIER_IR y DEEP_ARCHIVE."
  }
}
