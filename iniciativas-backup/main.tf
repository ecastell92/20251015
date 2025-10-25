
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
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
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
  # Nombres comunes para recursos locales (usados por planes de AWS Backup)
  prefijo_recursos = "${var.tenant}-${lower(var.environment)}"
  sufijo_recursos  = "${lower(var.iniciativa)}-${var.sufijo_recursos}"
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
  iniciativa  = var.iniciativa

  # Bucket central
  #central_backup_bucket_name = var.central_backup_bucket_name
  central_backup_vault_name = var.central_backup_vault_name
  sufijo_recursos           = var.sufijo_recursos
  enable_central_bucket     = var.enable_central_bucket

  # Reglas GFS optimizadas
  gfs_rules = var.gfs_rules

  # Validaciones S3
  min_deep_archive_offset_days = var.min_deep_archive_offset_days

  # Limpieza operativa (passthrough)
  cleanup_inventory_source_days = var.cleanup_inventory_source_days
  cleanup_batch_reports_days    = var.cleanup_batch_reports_days
  cleanup_checkpoints_days      = var.cleanup_checkpoints_days
  cleanup_manifests_temp_days   = var.cleanup_manifests_temp_days
  cleanup_configurations_days   = var.cleanup_configurations_days

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
  count  = var.enable_s3_backups ? 1 : 0
  source = "./initiative-logic"

  # Configuración básica
  aws_region  = var.aws_region
  iniciativa  = var.iniciativa
  environment = var.environment
  tenant      = var.tenant

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

  # Controles adicionales de incremental
  incremental_log_level     = var.incremental_log_level
  disable_window_checkpoint = var.disable_window_checkpoint
  exclude_key_prefixes      = var.exclude_key_prefixes
  exclude_key_suffixes      = var.exclude_key_suffixes
  source_kms_key_arns       = var.source_kms_key_arns
  kms_allow_viaservice      = var.kms_allow_viaservice

  # Tags para cost allocation
  backup_tags = var.backup_tags

  # Config Lambda (toggles y filtros)
  backup_config_log_level             = var.backup_config_log_level
  backup_config_tag_filter_key        = var.backup_config_tag_filter_key
  backup_config_tag_filter_value      = var.backup_config_tag_filter_value
  backup_config_include_glue          = var.backup_config_include_glue
  backup_config_include_athena        = var.backup_config_include_athena
  backup_config_include_lambda        = var.backup_config_include_lambda
  backup_config_include_iam           = var.backup_config_include_iam
  backup_config_include_stepfunctions = var.backup_config_include_stepfunctions
  backup_config_include_eventbridge   = var.backup_config_include_eventbridge
  backup_config_include_dynamodb      = var.backup_config_include_dynamodb
  backup_config_include_rds           = var.backup_config_include_rds

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

    initiative_logic = var.enable_s3_backups ? {
      state_machine_arn             = module.initiative_logic[0].state_machine_arn
      find_resources_lambda_arn     = module.initiative_logic[0].find_resources_lambda_arn
      incremental_backup_lambda_arn = module.initiative_logic[0].incremental_backup_lambda_arn
      sqs_queue_url                 = module.initiative_logic[0].sqs_queue_url
    } : null

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
  ${var.enable_s3_backups && var.enable_central_bucket ? "aws s3api get-bucket-lifecycle-configuration \\\n+    --bucket ${module.central_resources.central_backup_bucket_name} \\\n+    --output yaml" : "(S3 deshabilitado: no hay lifecycle)"}
  
  # Ver versionado (debe estar Suspended)
  ${var.enable_s3_backups && var.enable_central_bucket ? "aws s3api get-bucket-versioning \\\n+    --bucket ${module.central_resources.central_backup_bucket_name}" : "(S3 deshabilitado: no hay versionado)"}
  
  # Ver schedules
  ${var.enable_s3_backups ? "aws scheduler list-schedules \\\n+    --group-name ${var.tenant}-${lower(var.environment)}-schedules-${var.sufijo_recursos}" : "(S3 deshabilitado: no hay schedules)"}
  
  # Ver logs de find_resources
  ${var.enable_s3_backups ? "aws logs tail /aws/lambda/${var.tenant}-${lower(var.environment)}-find-resources-${var.sufijo_recursos} \\\n+    --follow --format short" : "(S3 deshabilitado: no hay Lambdas S3)"}
  
  # Ver S3 Batch Jobs
  aws s3control list-jobs \
    --account-id ${local.account_id} \
    --job-statuses Active InProgress
  
  ========================================
  ✅ DESPLIEGUE COMPLETADO
  ========================================
  
  Bucket Central: ${var.enable_s3_backups && var.enable_central_bucket ? module.central_resources.central_backup_bucket_name : "(S3 deshabilitado)"}
  State Machine (Backups): ${var.enable_s3_backups ? module.initiative_logic[0].state_machine_arn : "(S3 deshabilitado)"}
  State Machine (Restauración): ${var.enable_s3_backups ? module.initiative_logic[0].restore_state_machine_arn : "(S3 deshabilitado)"}
  SQS Queue: ${var.enable_s3_backups ? module.initiative_logic[0].sqs_queue_url : "(S3 deshabilitado)"}
  
  Próximos pasos:
  1. Etiquetar buckets origen con BackupEnabled=true
  2. Monitorear logs de Lambdas
  3. Verificar que se ejecutan los schedules
  4. Revisar AWS Cost Explorer después de 7 días
  
  EOT
}

// ============================================================================
// AWS Backup Plans for RDS and DynamoDB (by tags, similar a GFS de S3)
// ============================================================================

locals {
  backup_plans_enabled = var.enable_backup_rds || var.enable_backup_dynamodb
  gfs_enabled_by_crit  = { for k, v in var.gfs_rules : k => v if v.enable }
}

resource "aws_iam_role" "backup_service" {
  count = local.backup_plans_enabled ? 1 : 0
  name  = "${local.prefijo_recursos}-aws-backup-role-${local.sufijo_recursos}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect    = "Allow",
      Principal = { Service = "backup.amazonaws.com" },
      Action    = "sts:AssumeRole"
    }]
  })
  tags = {
    Initiative  = var.iniciativa
    Environment = var.environment
  }
}

resource "aws_iam_role_policy_attachment" "backup_service_attach_backup" {
  count      = local.backup_plans_enabled ? 1 : 0
  role       = aws_iam_role.backup_service[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
}

resource "aws_iam_role_policy_attachment" "backup_service_attach_restore" {
  count      = local.backup_plans_enabled ? 1 : 0
  role       = aws_iam_role.backup_service[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForRestores"
}

resource "aws_backup_plan" "gfs" {
  for_each = local.backup_plans_enabled ? local.gfs_enabled_by_crit : {}

  name = "${local.prefijo_recursos}-plan-${lower(each.key)}-${local.sufijo_recursos}"

  # Ensure the backup vault is created before the plan rules reference it
  depends_on = [
    module.central_resources
  ]

  dynamic "rule" {
    # Solo crear regla diaria si la retención de Son > 0
    for_each = each.value.son_retention_days > 0 ? [1] : []
    content {
      rule_name         = "daily-son-${each.key}"
      target_vault_name = var.central_backup_vault_name
      schedule          = "cron(0 2 * * ? *)" // diario 02:00 UTC
      lifecycle {
        delete_after = each.value.son_retention_days
      }
    }
  }

  dynamic "rule" {
    # Solo crear regla semanal si la retención de Father > 0
    for_each = each.value.father_retention_days > 0 ? [1] : []
    content {
      rule_name         = "weekly-father-${each.key}"
      target_vault_name = var.central_backup_vault_name
      schedule          = "cron(0 3 ? * SUN *)" // semanal domingo 03:00 UTC
      lifecycle {
        delete_after = each.value.father_retention_days
      }
    }
  }

  dynamic "rule" {
    for_each = each.value.grandfather_retention_days > 0 ? [1] : []
    content {
      rule_name         = "monthly-grandfather-${each.key}"
      target_vault_name = var.central_backup_vault_name
      schedule          = "cron(0 4 1 * ? *)" // mensual día 1 04:00 UTC
      lifecycle {
        delete_after = each.value.grandfather_retention_days
      }
    }
  }

  tags = {
    Initiative  = var.iniciativa
    Environment = var.environment
  }
}

resource "aws_backup_selection" "gfs" {
  for_each = local.backup_plans_enabled ? local.gfs_enabled_by_crit : {}

  name         = "${local.prefijo_recursos}-sel-${lower(each.key)}-${local.sufijo_recursos}"
  plan_id      = aws_backup_plan.gfs[each.key].id
  iam_role_arn = aws_iam_role.backup_service[0].arn

  selection_tag {
    type  = "STRINGEQUALS"
    key   = "BackupEnabled"
    value = "true"
  }

  selection_tag {
    type  = "STRINGEQUALS"
    key   = var.criticality_tag
    value = each.key
  }
}

// ============================================================================
// Destroy-time cleanup: remove S3 Inventory + S3→SQS notifications from sources
// ============================================================================

resource "null_resource" "cleanup_s3_backup_configs" {
  triggers = {
    // Change this value to force re-evaluation; not used at create-time.
    version = "1"
  }

  provisioner "local-exec" {
    when = destroy
    # Destroy-time provisioners cannot reference variables/resources. The
    # script defaults to BackupEnabled=true so we omit args here.
    command = "python scripts/cleanup_s3_backup_configs.py --yes"
  }
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
  value       = var.enable_s3_backups ? module.initiative_logic[0].state_machine_arn : null
}

output "restore_state_machine_arn" {
  description = "ARN de la Step Function de restauración"
  value       = var.enable_s3_backups ? module.initiative_logic[0].restore_state_machine_arn : null
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
