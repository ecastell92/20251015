terraform {
  required_version = ">= 1.4.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

locals {
  name_prefix = var.name_prefix
  tags_common = merge(
    {
      Project       = "AuroraMiniTest"
      Environment   = var.environment
      ManagedBy     = "Terraform"
      BackupEnabled = "true"
    },
    { (var.backup_criticality_key) = var.backup_criticality_value },
    var.additional_tags
  )
}

resource "aws_db_subnet_group" "aurora" {
  name       = "${local.name_prefix}-subnets"
  subnet_ids = var.private_subnet_ids

  tags = merge(local.tags_common, { Name = "${local.name_prefix}-db-subnets" })
}

resource "aws_security_group" "aurora" {
  name        = "${local.name_prefix}-sg"
  description = "Aurora MySQL access"
  vpc_id      = var.vpc_id

  # Acceso MySQL desde CIDRs permitidos (si se define)
  dynamic "ingress" {
    for_each = var.allowed_cidr_blocks
    content {
      description = "MySQL"
      from_port   = 3306
      to_port     = 3306
      protocol    = "tcp"
      cidr_blocks = [ingress.value]
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags_common, { Name = "${local.name_prefix}-sg" })
}

resource "random_password" "master" {
  length           = 20
  special          = false
  override_char_set = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#%*+-_"
}

resource "aws_rds_cluster" "this" {
  cluster_identifier              = "${local.name_prefix}-cluster"
  engine                          = "aurora-mysql"
  engine_mode                     = "provisioned"
  # engine_version               = var.engine_version  # opcional

  database_name                   = var.database_name
  master_username                 = var.master_username
  master_password                 = coalesce(var.master_password, random_password.master.result)

  backup_retention_period         = var.backup_retention_period
  preferred_backup_window         = var.preferred_backup_window
  copy_tags_to_snapshot           = true

  db_subnet_group_name            = aws_db_subnet_group.aurora.name
  vpc_security_group_ids          = [aws_security_group.aurora.id]

  storage_encrypted               = true
  deletion_protection             = false
  skip_final_snapshot             = true
  enabled_cloudwatch_logs_exports = ["error", "slowquery"]

  tags = merge(local.tags_common, { Name = "${local.name_prefix}-cluster" })
}

resource "aws_rds_cluster_instance" "writer" {
  identifier              = "${local.name_prefix}-writer-1"
  cluster_identifier      = aws_rds_cluster.this.id
  instance_class          = var.instance_class
  engine                  = aws_rds_cluster.this.engine
  engine_version          = aws_rds_cluster.this.engine_version
  publicly_accessible     = false
  apply_immediately       = true
  performance_insights_enabled = true

  tags = merge(local.tags_common, { Name = "${local.name_prefix}-writer-1" })
}
