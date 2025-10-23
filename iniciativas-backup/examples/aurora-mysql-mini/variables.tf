variable "aws_region" {
  description = "AWS region"
  type        = string
}

variable "environment" {
  description = "Environment tag (dev|staging|prod)"
  type        = string
  default     = "dev"
}

variable "name_prefix" {
  description = "Prefix for resource names"
  type        = string
  default     = "aurora-mini"
}

variable "vpc_id" {
  description = "VPC ID where Aurora will be deployed"
  type        = string
}

variable "private_subnet_ids" {
  description = "List of private subnet IDs (2+ AZs recommended)"
  type        = list(string)
}

variable "allowed_cidr_blocks" {
  description = "CIDR blocks allowed to connect to Aurora MySQL (3306)"
  type        = list(string)
  default     = []
}

variable "database_name" {
  description = "Initial database name"
  type        = string
  default     = "testdb"
}

variable "master_username" {
  description = "Master user name"
  type        = string
  default     = "admin"
}

variable "master_password" {
  description = "Master user password (if omitted, a random one is generated)"
  type        = string
  default     = null
  sensitive   = true
}

variable "backup_retention_period" {
  description = "Aurora PITR retention days (7-35)"
  type        = number
  default     = 14
}

variable "preferred_backup_window" {
  description = "Daily backup window (UTC), e.g., 01:00-02:00"
  type        = string
  default     = "01:00-02:00"
}

variable "instance_class" {
  description = "Aurora instance class"
  type        = string
  default     = "db.t4g.medium"
}

variable "backup_criticality_key" {
  description = "Tag key used by AWS Backup selection for criticality"
  type        = string
  default     = "BackupCriticality"
}

variable "backup_criticality_value" {
  description = "Criticality value (Critico|MenosCritico|NoCritico)"
  type        = string
  default     = "MenosCritico"
}

variable "additional_tags" {
  description = "Extra tags to add to all resources"
  type        = map(string)
  default     = {}
}

