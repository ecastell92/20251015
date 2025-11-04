terraform {
  required_version = ">= 1.4.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

module "restore_service" {
  source = "../modules/restore_service"

  aws_region                 = var.aws_region
  tenant                     = var.tenant
  environment                = var.environment
  iniciativa                 = var.iniciativa
  sufijo_recursos            = var.sufijo_recursos
  central_backup_bucket_name = var.manifest_bucket_name
  manifest_prefix            = var.manifest_prefix
  report_suffix              = var.report_suffix
  batch_operations_role_name = var.batch_operations_role_name
  lambda_timeout             = var.lambda_timeout
  lambda_memory              = var.lambda_memory
  tags                       = var.tags
}
