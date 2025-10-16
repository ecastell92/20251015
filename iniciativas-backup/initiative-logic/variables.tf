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


variable "central_backup_bucket_name" {
  description = "Name of the central backup S3 bucket"
  type        = string
}

variable "criticality_tag" {
  description = "Tag key that defines backup criticality on resources"
  type        = string
  default     = "BackupCriticality"
}

variable "allowed_prefixes" {
  description = "Mapping of criticality to list of allowed S3 prefixes for event‑driven backups"
  type        = map(list(string))
  default = {
    Critico      = [""],
    MenosCritico = [""],
    NoCritico    = [""],
  }
}

variable "schedule_expressions" {
  description = "Schedules por criticidad: incremental (opcional) y sweep (full)"
  type = map(object({
    incremental = optional(string)
    sweep       = string
    grandfather = optional(string)
  }))
}

variable "backup_tags" {
  description = "Map of tags applied to backup resources for cost allocation"
  type        = map(string)
  default     = {}
}

# Control de primera corrida y fallback del inventario
variable "force_full_on_first_run" {
  description = "Si true, la primera corrida incremental se ejecuta como FULL (sin filtrar por checkpoint)"
  type        = bool
  default     = false
}

variable "fallback_max_objects" {
  description = "Límite máximo de objetos a incluir en el manifiesto generado por fallback (null = sin límite)"
  type        = number
  default     = null
}

variable "fallback_time_limit_seconds" {
  description = "Tiempo máximo (segundos) para generar manifiesto por fallback (null = sin límite)"
  type        = number
  default     = null
}

variable "central_account_id" {
  description = "AWS Account ID of the central backup account"
  type        = string
}


variable "sufijo_recursos" {
  description = "Suffix to ensure unique names for global resources"
  type        = string
}
