// -----------------------------------------------------------------------------
// Variables for the initiative logic project
//
// Each initiative deploys its own copy of this module into its account. These
// variables configure the initiative name, environment, and references to
// central resources such as the backup bucket and KMS key.

variable "aws_region" {
  description = "The AWS region for this initiative"
  type        = string
}

variable "iniciativa" {
  description = "Short name of the initiative using the backup system"
  type        = string
}

variable "environment" {
  description = "Deployment environment tag (e.g., dev, prod)"
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
