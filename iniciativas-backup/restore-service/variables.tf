variable "aws_region" {
  description = "Región AWS donde se desplegará el servicio de restore."
  type        = string
  default     = "eu-west-1"
}

variable "tenant" {
  description = "Identificador corto del tenant o unidad de negocio."
  type        = string
}

variable "environment" {
  description = "Nombre del entorno (dev, staging, prod, etc.)."
  type        = string
}

variable "iniciativa" {
  description = "Nombre corto de la iniciativa."
  type        = string
}

variable "sufijo_recursos" {
  description = "Sufijo para garantizar unicidad en los nombres."
  type        = string
}

variable "manifest_bucket_name" {
  description = "Bucket S3 donde se almacenarán (o se encuentran) los manifests."
  type        = string
}

variable "manifest_prefix" {
  description = "Prefijo por defecto para los manifests generados."
  type        = string
  default     = "restore-manifests/"
}

variable "report_suffix" {
  description = "Sufijo que se añadirá al prefijo destino para los reportes de S3 Batch."
  type        = string
  default     = "batch-reports/"
}

variable "batch_operations_role_name" {
  description = "Nombre del IAM Role que utiliza S3 Batch Operations (service-linked por defecto)."
  type        = string
  default     = "service-role/AWSBatchOperationsRole"
}

variable "lambda_timeout" {
  description = "Timeout en segundos para las Lambdas de generate/start."
  type        = number
  default     = 900
}

variable "lambda_memory" {
  description = "Memoria asignada (MB) a las Lambdas de restore."
  type        = number
  default     = 512
}

variable "tags" {
  description = "Tags adicionales aplicados a todos los recursos."
  type        = map(string)
  default     = {}
}
