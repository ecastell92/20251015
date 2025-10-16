// ============================================================================
// Central Resources Project - CORREGIDO
// ============================================================================
// Cambios:
// - Eliminada configuración duplicada gfs_menoscritico
// - Sin referencias a KMS (solo AES256)
// - Todas las rules GFS están en la configuración dinámica
// ============================================================================

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  required_version = ">= 1.4.0"
}

provider "aws" {
  region = var.aws_region
}

data "aws_caller_identity" "current" {}

locals {
  central_backup_bucket_name = "${var.tenant}-${lower(var.environment)}-${var.central_backup_bucket_name_part}-${var.sufijo_recursos}-notinet"
}

# ----------------------------------------------------------------------------
# Bucket central de backups (único para todo)
# ----------------------------------------------------------------------------
resource "aws_s3_bucket" "central_backup" {
  bucket              = local.central_backup_bucket_name
  force_destroy       = false
  object_lock_enabled = var.enable_object_lock

  tags = {
    Name        = "central-backup"
    Environment = var.environment
  }
}

resource "aws_s3_bucket_public_access_block" "central_backup" {
  bucket                  = aws_s3_bucket.central_backup.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "central_backup" {
  bucket = aws_s3_bucket.central_backup.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# Cifrado con AES256 (sin KMS)
resource "aws_s3_bucket_server_side_encryption_configuration" "central_backup" {
  bucket = aws_s3_bucket.central_backup.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Object Lock default retention (opcional)
resource "aws_s3_bucket_object_lock_configuration" "central_backup" {
  count  = var.enable_object_lock && var.object_lock_retention_days > 0 ? 1 : 0
  bucket = aws_s3_bucket.central_backup.id

  rule {
    default_retention {
      mode = upper(var.object_lock_mode)
      days = var.object_lock_retention_days
    }
  }
}

# ----------------------------------------------------------------------------
# Lifecycle Policies diferenciadas por criticidad
# ÚNICA CONFIGURACIÓN - Las reglas GFS están incluidas aquí dinámicamente
# ----------------------------------------------------------------------------
resource "aws_s3_bucket_lifecycle_configuration" "central_backup" {
  bucket = aws_s3_bucket.central_backup.id

  # Retención de respaldos completos por criticidad (cuando GFS no está habilitado)
  dynamic "rule" {
    for_each = { for k, v in var.lifecycle_rules : k => v if !try(var.gfs_rules[k].enable, false) }
    content {
      id     = "${rule.key}-full-retention"
      status = "Enabled"
      filter { prefix = "backup/criticality=${rule.key}/backup_type=full/" }

      dynamic "transition" {
        for_each = rule.value.use_glacier_ir ? [1] : []
        content {
          days          = rule.value.glacier_transition_days
          storage_class = "GLACIER_IR"
        }
      }

      dynamic "transition" {
        for_each = rule.value.deep_archive_transition_days > 0 ? [1] : []
        content {
          days          = rule.value.deep_archive_transition_days
          storage_class = "DEEP_ARCHIVE"
        }
      }

      expiration {
        days = rule.value.expiration_days
      }
    }
  }

  # Retención corta de respaldos incrementales (cuando GFS no está habilitado)
  dynamic "rule" {
    for_each = {
      for name, cfg in var.lifecycle_rules : name => cfg
      if cfg.incremental_expiration_days > 0 && !try(var.gfs_rules[name].enable, false)
    }
    content {
      id     = "${rule.key}-incremental-retention"
      status = "Enabled"
      filter { prefix = "backup/criticality=${rule.key}/backup_type=incremental/" }

      dynamic "transition" {
        for_each = rule.value.use_glacier_ir ? [1] : []
        content {
          days          = rule.value.incremental_glacier_transition_days
          storage_class = "GLACIER_IR"
        }
      }

      expiration {
        days = rule.value.incremental_expiration_days
      }

      noncurrent_version_expiration {
        noncurrent_days = 1
      }
    }
  }

  # Limpieza de archivos temporales y operacionales
  rule {
    id     = "cleanup-inventory-source"
    status = "Enabled"
    filter { prefix = "inventory-source/" }
    expiration { days = 30 }
    noncurrent_version_expiration { noncurrent_days = 1 }
  }

  rule {
    id     = "cleanup-batch-reports"
    status = "Enabled"
    filter { prefix = "reports/" }
    expiration { days = 90 }
    noncurrent_version_expiration { noncurrent_days = 1 }
  }

  rule {
    id     = "cleanup-checkpoints"
    status = "Enabled"
    filter { prefix = "checkpoints/" }
    expiration { days = 90 }
    noncurrent_version_expiration { noncurrent_days = 1 }
  }

  rule {
    id     = "cleanup-manifests-temp"
    status = "Enabled"
    filter { prefix = "manifests/temp/" }
    expiration { days = 7 }
    noncurrent_version_expiration { noncurrent_days = 1 }
  }

  # === Reglas GFS (Son) - Incrementales diarios ===
  dynamic "rule" {
    for_each = { for k, v in var.gfs_rules : k => v if v.enable }
    content {
      id     = "${rule.key}-gfs-son"
      status = "Enabled"
      filter { prefix = "backup/criticality=${rule.key}/backup_type=incremental/generation=son/" }

      transition {
        days          = 0
        storage_class = rule.value.start_storage_class
      }

      expiration { days = rule.value.son_retention_days }
    }
  }

  # === Reglas GFS (Father) - Full quincenales/semanales ===
  dynamic "rule" {
    for_each = { for k, v in var.gfs_rules : k => v if v.enable }
    content {
      id     = "${rule.key}-gfs-father"
      status = "Enabled"
      filter { prefix = "backup/criticality=${rule.key}/backup_type=full/generation=father/" }

      transition {
        days          = 0
        storage_class = rule.value.start_storage_class
      }

      dynamic "transition" {
        for_each = rule.value.father_da_days > 0 ? [1] : []
        content {
          days          = rule.value.father_da_days
          storage_class = rule.value.father_archive_class
        }
      }

      expiration { days = rule.value.father_retention_days }
    }
  }

  # === Reglas GFS (Grandfather) - Full mensuales/trimestrales ===
  dynamic "rule" {
    for_each = { for k, v in var.gfs_rules : k => v if v.enable }
    content {
      id     = "${rule.key}-gfs-grandfather"
      status = "Enabled"
      filter { prefix = "backup/criticality=${rule.key}/backup_type=full/generation=grandfather/" }

      transition {
        days          = 0
        storage_class = rule.value.start_storage_class
      }

      dynamic "transition" {
        for_each = rule.value.grandfather_da_days > 0 ? [1] : []
        content {
          days          = rule.value.grandfather_da_days
          storage_class = rule.value.grandfather_archive_class
        }
      }

      expiration { days = rule.value.grandfather_retention_days }
    }
  }
}

# ----------------------------------------------------------------------------
# Bucket Policy cross-account + S3 Inventory + Batch Ops
# Sin referencias a KMS - Solo AES256
# ----------------------------------------------------------------------------
resource "aws_s3_bucket_policy" "central_backup" {
  bucket = aws_s3_bucket.central_backup.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = concat([
      {
        Sid       = "AllowSameAccountUpdateBucketPolicy",
        Effect    = "Allow",
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" },
        Action = [
          "s3:GetBucketPolicy",
          "s3:PutBucketPolicy"
        ],
        Resource = aws_s3_bucket.central_backup.arn
      },
      {
        Sid    = "AllowS3InventoryReports",
        Effect = "Allow",
        Principal = {
          Service = "s3.amazonaws.com"
        },
        Action   = "s3:PutObject",
        Resource = "${aws_s3_bucket.central_backup.arn}/inventory-source/*",
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id,
            "s3:x-amz-acl"      = "bucket-owner-full-control"
          },
          ArnLike = {
            "aws:SourceArn" = "arn:aws:s3:::*"
          }
        }
      },
      {
        Sid    = "AllowS3InventoryGetBucketAcl",
        Effect = "Allow",
        Principal = {
          Service = "s3.amazonaws.com"
        },
        Action = [
          "s3:GetBucketAcl",
          "s3:GetBucketLocation"
        ],
        Resource = aws_s3_bucket.central_backup.arn
      },
      {
        Sid       = "AllowWorkerRolesObjectAccess",
        Effect    = "Allow",
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" },
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:DeleteObject"
        ],
        Resource = "${aws_s3_bucket.central_backup.arn}/*"
      },
      {
        Sid       = "AllowWorkerRolesListBucket",
        Effect    = "Allow",
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" },
        Action    = "s3:ListBucket",
        Resource  = aws_s3_bucket.central_backup.arn
      },
      {
        Sid    = "AllowBatchOperationsObjectAccess",
        Effect = "Allow",
        Principal = {
          Service = "batchoperations.s3.amazonaws.com"
        },
        Action = [
          "s3:GetObject",
          "s3:PutObject"
        ],
        Resource = "${aws_s3_bucket.central_backup.arn}/*",
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      },
      {
        Sid    = "AllowBatchOperationsListBucket",
        Effect = "Allow",
        Principal = {
          Service = "batchoperations.s3.amazonaws.com"
        },
        Action   = "s3:ListBucket",
        Resource = aws_s3_bucket.central_backup.arn,
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      }
      ],
      var.deny_delete_enabled ? (
        length(var.allow_delete_principals) > 0 ? [
          {
            Sid       = "DenyDeleteForNonBreakglass",
            Effect    = "Deny",
            Principal = "*",
            Action    = ["s3:DeleteObject", "s3:DeleteObjectVersion", "s3:AbortMultipartUpload"],
            Resource  = "${aws_s3_bucket.central_backup.arn}/*",
            Condition = {
              StringNotEquals = {
                "aws:PrincipalArn" = var.allow_delete_principals
              }
            }
          }
          ] : [
          {
            Sid       = "DenyAllDelete",
            Effect    = "Deny",
            Principal = "*",
            Action    = ["s3:DeleteObject", "s3:DeleteObjectVersion", "s3:AbortMultipartUpload"],
            Resource  = "${aws_s3_bucket.central_backup.arn}/*"
          }
        ]
      ) : [],
      var.deny_delete_enabled && var.require_mfa_for_delete ? [
        {
          Sid       = "DenyDeleteWithoutMFA",
          Effect    = "Deny",
          Principal = "*",
          Action    = ["s3:DeleteObject", "s3:DeleteObjectVersion", "s3:AbortMultipartUpload"],
          Resource  = "${aws_s3_bucket.central_backup.arn}/*",
          Condition = {
            Bool = { "aws:MultiFactorAuthPresent" = false }
          }
        }
    ] : [])
  })
}

# ----------------------------------------------------------------------------
# Backup Vault
# ----------------------------------------------------------------------------
resource "aws_backup_vault" "central" {
  name = var.central_backup_vault_name

  tags = {
    Name        = "central-backup-vault"
    Environment = var.environment
  }
}

# ----------------------------------------------------------------------------
# Outputs
# ----------------------------------------------------------------------------
output "central_backup_bucket_name" {
  value       = aws_s3_bucket.central_backup.bucket
  description = "Nombre del bucket central (usado para backups, manifiestos, reportes y checkpoints)"
}

output "central_backup_bucket_arn" {
  value       = aws_s3_bucket.central_backup.arn
  description = "ARN del bucket central"
}
