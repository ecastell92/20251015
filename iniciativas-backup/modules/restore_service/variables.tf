variable "aws_region" {
  description = "Región AWS donde se despliega el servicio de restore."
  type        = string
}

variable "tenant" {
  description = "Identificador corto del tenant."
  type        = string
}

variable "environment" {
  description = "Nombre del entorno (dev, staging, prod)."
  type        = string
}

variable "iniciativa" {
  description = "Nombre corto de la iniciativa."
  type        = string
}

variable "sufijo_recursos" {
  description = "Sufijo usado para garantizar unicidad en nombres."
  type        = string
}

variable "central_backup_bucket_name" {
  description = "Bucket central donde, por defecto, se almacenan los manifests de restore."
  type        = string
}

variable "manifest_prefix" {
  description = "Prefijo por defecto para manifests generados."
  type        = string
  default     = "restore-manifests/"
}

variable "report_suffix" {
  description = "Sufijo que se añadirá al prefijo destino para los reportes de S3 Batch."
  type        = string
  default     = "batch-reports/"
}

variable "batch_operations_role_name" {
  description = "Nombre del IAM Role usado por S3 Batch Operations (service-linked)."
  type        = string
  default     = "service-role/AWSBatchOperationsRole"
}

variable "lambda_timeout" {
  description = "Timeout (segundos) para las funciones Lambda de restore."
  type        = number
  default     = 900
}

variable "lambda_memory" {
  description = "Memoria (MB) para las funciones Lambda de restore."
  type        = number
  default     = 512
}

variable "tags" {
  description = "Tags adicionales aplicados a los recursos."
  type        = map(string)
  default     = {}
}
