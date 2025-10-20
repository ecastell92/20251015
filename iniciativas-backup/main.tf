// ============================================================================
// Main Root Module - Orchestration
// ============================================================================
// Este módulo raíz orquesta el despliegue de:
// 1. Central Resources (bucket central, lifecycle, seguridad)
// 2. Initiative Logic (lambdas, step functions, schedules)
//
// Usar desde la raíz del proyecto:
//   terraform init
//   terraform plan
//   terraform apply
// ============================================================================

terraform {
  required_version = ">= 1.4.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }

  # Descomentar para usar remote state en S3
  # backend "s3" {
  #   bucket         = "tu-bucket-terraform-state"
  #   key            = "backup-s3/terraform.tfstate"
  #   region         = "eu-west-1"
  #   encrypt        = true
  #   dynamodb_table = "terraform-state-lock"
  # }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "S3BackupOptimized"
      ManagedBy   = "Terraform"
      Environment = var.environment
      Tenant      = var.tenant
      CostCenter  = "optimized"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.name
  central_account_id = coalesce(var.central_account_id, var.cuenta, data.aws_caller_identity.current.account_id)
}

// ============================================================================
// MÓDULO 1: CENTRAL RESOURCES
// ============================================================================
// Crea el bucket central, lifecycle policies, seguridad

module "central_resources" {
  source = "./central-resources"

  # Configuración básica
  aws_region  = var.aws_region
  environment = var.environment
  tenant      = var.tenant

  # Bucket central
  central_backup_bucket_name = var.central_backup_bucket_name
  central_backup_vault_name  = var.central_backup_vault_name
  sufijo_recursos            = var.sufijo_recursos

  # Reglas GFS optimizadas
  gfs_rules = var.gfs_rules

  # Validaciones S3
  min_deep_archive_offset_days = var.min_deep_archive_offset_days

  # Seguridad (opcional)
  enable_object_lock         = var.enable_object_lock
  object_lock_mode           = var.object_lock_mode
  object_lock_retention_days = var.object_lock_retention_days
  deny_delete_enabled        = var.deny_delete_enabled
  allow_delete_principals    = var.allow_delete_principals
  require_mfa_for_delete     = var.require_mfa_for_delete

  # Legacy lifecycle rules (deprecated)
  lifecycle_rules = var.lifecycle_rules
}

// ============================================================================
// MÓDULO 2: INITIATIVE LOGIC
// ============================================================================
// Crea Lambdas, Step Functions, EventBridge Scheduler, SQS
// DEPENDE de central_resources (bucket debe existir primero)

module "initiative_logic" {
  source = "./initiative-logic"

  # Configuración básica
  aws_region         = var.aws_region
  iniciativa         = var.iniciativa
  environment        = var.environment
  tenant             = var.tenant
  central_account_id = local.central_account_id

  # Referencia al bucket central (output del módulo anterior)
  central_backup_bucket_name = module.central_resources.central_backup_bucket_name

  # Configuración de backups
  criticality_tag  = var.criticality_tag
  allowed_prefixes = var.allowed_prefixes

  # Schedules por criticidad
  schedule_expressions = var.schedule_expressions

  # Control de primera corrida y fallback
  force_full_on_first_run     = var.force_full_on_first_run
  fallback_max_objects        = var.fallback_max_objects
  fallback_time_limit_seconds = var.fallback_time_limit_seconds

  # Tags para cost allocation
  backup_tags = var.backup_tags

  # Sufijo para nombres únicos
  sufijo_recursos = var.sufijo_recursos

  # DEPENDENCIA EXPLÍCITA: Esperar a que central_resources termine
  #depends_on = [module.central_resources]
}

// ============================================================================
// OUTPUTS
// ============================================================================

output "deployment_summary" {
  description = "Resumen del despliegue completo"
  value = {
    account_id  = local.account_id
    region      = local.region
    environment = var.environment

    central_resources = {
      bucket_name = module.central_resources.central_backup_bucket_name
      bucket_arn  = module.central_resources.central_backup_bucket_arn
      vault_arn   = module.central_resources.backup_vault_arn
    }

    initiative_logic = {
      state_machine_arn             = module.initiative_logic.state_machine_arn
      find_resources_lambda_arn     = module.initiative_logic.find_resources_lambda_arn
      incremental_backup_lambda_arn = module.initiative_logic.incremental_backup_lambda_arn
      sqs_queue_url                 = module.initiative_logic.sqs_queue_url
    }

    optimization = {
      versioning_status          = "Suspended"
      operational_cleanup_days   = 7
      son_retention_critico      = var.gfs_rules["Critico"].son_retention_days
      son_retention_menoscritico = var.gfs_rules["MenosCritico"].son_retention_days
      estimated_monthly_savings  = "65-68%"
    }
  }
}

output "validation_commands" {
  description = "Comandos para validar el despliegue"
  value       = <<-EOT
  
  ========================================
  🔍 COMANDOS DE VALIDACIÓN
  ========================================
  
  # Ver lifecycle configuration
  aws s3api get-bucket-lifecycle-configuration \
    --bucket ${module.central_resources.central_backup_bucket_name} \
    --output yaml
  
  # Ver versionado (debe estar Suspended)
  aws s3api get-bucket-versioning \
    --bucket ${module.central_resources.central_backup_bucket_name}
  
  # Ver schedules
  aws scheduler list-schedules \
    --group-name ${var.tenant}-${lower(var.environment)}-schedules-${var.sufijo_recursos}
  
  # Ver logs de find_resources
  aws logs tail /aws/lambda/${var.tenant}-${lower(var.environment)}-find-resources-${var.sufijo_recursos} \
    --follow --format short
  
  # Ver S3 Batch Jobs
  aws s3control list-jobs \
    --account-id ${local.account_id} \
    --job-statuses Active InProgress
  
  ========================================
  ✅ DESPLIEGUE COMPLETADO
  ========================================
  
  Bucket Central: ${module.central_resources.central_backup_bucket_name}
  State Machine: ${module.initiative_logic.state_machine_arn}
  SQS Queue: ${module.initiative_logic.sqs_queue_url}
  
  Próximos pasos:
  1. Etiquetar buckets origen con BackupEnabled=true
  2. Monitorear logs de Lambdas
  3. Verificar que se ejecutan los schedules
  4. Revisar AWS Cost Explorer después de 7 días
  
  EOT
}

output "central_bucket_name" {
  description = "Nombre del bucket central (para usar en otros módulos)"
  value       = module.central_resources.central_backup_bucket_name
}

output "central_bucket_arn" {
  description = "ARN del bucket central (para usar en otros módulos)"
  value       = module.central_resources.central_backup_bucket_arn
}

output "state_machine_arn" {
  description = "ARN de la Step Function orquestadora"
  value       = module.initiative_logic.state_machine_arn
}

output "cost_optimization_summary" {
  description = "Resumen de optimizaciones de costos aplicadas"
  value = {
    versioning_status          = "Suspended"
    operational_files_cleanup  = "7 days"
    son_retention_critico      = "${var.gfs_rules["Critico"].son_retention_days} days"
    son_retention_menoscritico = "${var.gfs_rules["MenosCritico"].son_retention_days} days"
    son_retention_nocritico    = "${var.gfs_rules["NoCritico"].son_retention_days} days"
    nocritico_incrementals     = "disabled"
    estimated_savings          = "65-68%"
  }
}
