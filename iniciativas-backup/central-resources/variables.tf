// -----------------------------------------------------------------------------
// Variables for the central resources module
//
// These variables allow the central account owner to customize resource names
// and set the region where resources are deployed.

variable "aws_region" {
  description = "The AWS region where the central backup resources will be provisioned"
  type        = string
}

variable "central_backup_vault_name" {
  description = "Name of the AWS Backup vault used to store snapshots"
  type        = string
}

variable "environment" {
  description = "Deployment environment tag (e.g., dev, prod)"
  type        = string
}


variable "lifecycle_rules" {
  description = "Lifecycle rules by criticidad"
  type = map(object({
    glacier_transition_days             = number
    deep_archive_transition_days        = number
    expiration_days                     = number
    incremental_expiration_days         = number
    incremental_glacier_transition_days = number
    use_glacier_ir                      = bool
  }))
}

# GFS lifecycle (por criticidad). Si enable=true para una criticidad,
# se aplican reglas específicas Son/Father/Grandfather para esa criticidad
# y se omiten las reglas genéricas de 'lifecycle_rules' para esa clave.
variable "gfs_rules" {
  description = "Grandfather-Father-Son lifecycle settings by criticidad"
  type = map(object({
    enable                      = bool
    start_storage_class         = string          # p.ej. GLACIER_IR
    son_retention_days          = number
    father_da_days              = number          # días a DEEP_ARCHIVE
    father_retention_days       = number
    father_archive_class        = string          # p.ej. DEEP_ARCHIVE
    grandfather_da_days         = number
    grandfather_retention_days  = number
    grandfather_archive_class   = string          # p.ej. DEEP_ARCHIVE
  }))
  default = {
    Critico = {
      enable                     = true
      start_storage_class        = "GLACIER_IR"
      son_retention_days         = 45
      father_da_days             = 90
      father_retention_days      = 1825
      father_archive_class       = "DEEP_ARCHIVE"
      grandfather_da_days        = 90
      grandfather_retention_days = 1825
      grandfather_archive_class  = "DEEP_ARCHIVE"
    }
    MenosCritico = {
      enable                     = true
      start_storage_class        = "GLACIER_IR"
      son_retention_days         = 30
      father_da_days             = 90
      father_retention_days      = 1825
      father_archive_class       = "DEEP_ARCHIVE"
      grandfather_da_days        = 90
      grandfather_retention_days = 1825
      grandfather_archive_class  = "DEEP_ARCHIVE"
    }
    NoCritico = {
      enable                     = true
      start_storage_class        = "GLACIER_IR"
      son_retention_days         = 21
      father_da_days             = 0
      father_retention_days      = 90
      father_archive_class       = "DEEP_ARCHIVE"
      grandfather_da_days        = 0
      grandfather_retention_days = 365
      grandfather_archive_class  = "DEEP_ARCHIVE"
    }
  }
}


variable "central_backup_bucket_name_part" {
  description = "Part of the name of the S3 bucket used for centralized backup storage"
  type        = string

}

variable "tenant" {
  description = "Short name of the tenant or business unit"
  type        = string
}

variable "sufijo_recursos" {
  description = "Suffix to append to resource names to ensure uniqueness"
  type        = string
}

# Object Lock (opcional)
variable "enable_object_lock" {
  description = "Enable S3 Object Lock on central backup bucket (requires bucket creation with this flag)"
  type        = bool
  default     = false
}

variable "object_lock_mode" {
  description = "Default Object Lock retention mode (COMPLIANCE or GOVERNANCE)"
  type        = string
  default     = "COMPLIANCE"
}

variable "object_lock_retention_days" {
  description = "Default Object Lock retention in days"
  type        = number
  default     = 0
}

# Offset mínimo exigido por S3 entre transiciones a GLACIER_IR y DEEP_ARCHIVE
variable "min_deep_archive_offset_days" {
  description = "Minimum days between earlier transition and DEEP_ARCHIVE (S3 requires >= 90 when transitioning from GLACIER_IR)"
  type        = number
  default     = 90
}

# Bucket policy anti-borrado (opcional)
variable "deny_delete_enabled" {
  description = "Deny delete operations on central bucket, with optional breakglass exceptions"
  type        = bool
  default     = false
}

variable "allow_delete_principals" {
  description = "List of IAM ARNs allowed to delete (breakglass)"
  type        = list(string)
  default     = []
}

variable "require_mfa_for_delete" {
  description = "Require MFA for delete operations when breakglass is used"
  type        = bool
  default     = true
}
