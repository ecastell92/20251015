// ============================================================================
// Central Resources Project - VERSIÓN CORREGIDA FINAL
// ============================================================================
// CAMBIOS PRINCIPALES:
// 1. Nomenclatura unificada: central_backup_bucket_name (consistente)
// 2. Sin referencias a KMS (solo AES256)
// 3. Reglas GFS optimizadas y validadas
// 4. Outputs exportados correctamente
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

# ============================================================================
# LOCALS - Nomenclatura Unificada
# ============================================================================

locals {
  # Nombre completo del bucket central (ÚNICO EN TODO EL CÓDIGO)
  central_backup_bucket_name = var.central_backup_bucket_name

  # ARN del bucket central
  central_backup_bucket_arn = "arn:aws:s3:::${local.central_backup_bucket_name}"

  # Prefijo para recursos
  resource_prefix = "${var.tenant}-${lower(var.environment)}"

  # Tags comunes
  common_tags = {
    Name        = "central-backup"
    Environment = var.environment
    ManagedBy   = "Terraform"
    Initiative  = "backup-s3"
  }
}

# ============================================================================
# BUCKET CENTRAL DE BACKUPS (ÚNICO)
# ============================================================================

resource "aws_s3_bucket" "central_backup" {
  bucket              = local.central_backup_bucket_name
  force_destroy       = true
  object_lock_enabled = var.enable_object_lock

  tags = local.common_tags
}

# ============================================================================
# CONFIGURACIÓN DE SEGURIDAD
# ============================================================================

# Bloqueo de acceso público
resource "aws_s3_bucket_public_access_block" "central_backup" {
  bucket = aws_s3_bucket.central_backup.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Ownership controls
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
    bucket_key_enabled = true
  }
}

# Versionado (recomendado para backups)
resource "aws_s3_bucket_versioning" "central_backup" {
  bucket = aws_s3_bucket.central_backup.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Object Lock (opcional)
resource "aws_s3_bucket_object_lock_configuration" "central_backup" {
  count = var.enable_object_lock && var.object_lock_retention_days > 0 ? 1 : 0

  bucket = aws_s3_bucket.central_backup.id

  rule {
    default_retention {
      mode = upper(var.object_lock_mode)
      days = var.object_lock_retention_days
    }
  }
}

# ============================================================================
# LIFECYCLE POLICIES - GFS POR CRITICIDAD
# ============================================================================

resource "aws_s3_bucket_lifecycle_configuration" "central_backup" {
  bucket = aws_s3_bucket.central_backup.id

  # ─────────────────────────────────────────────────────────────────────────
  # REGLAS GFS (Grandfather-Father-Son)
  # ─────────────────────────────────────────────────────────────────────────

  # === SON: Backups incrementales diarios ===
  dynamic "rule" {
    for_each = { for k, v in var.gfs_rules : k => v if v.enable && v.son_retention_days > 0 }

    content {
      id     = "${rule.key}-gfs-son"
      status = "Enabled"

      filter {
        prefix = "backup/criticality=${rule.key}/backup_type=incremental/generation=son/"
      }

      # Transición inmediata a storage class inicial
      transition {
        days          = 0
        storage_class = rule.value.start_storage_class
      }

      # Expiración según retención configurada
      expiration {
        days = rule.value.son_retention_days
      }

      # Limpiar versiones antiguas
      noncurrent_version_expiration {
        noncurrent_days = 30
      }
    }
  }

  # === FATHER: Backups full semanales/quincenales ===
  dynamic "rule" {
    for_each = { for k, v in var.gfs_rules : k => v if v.enable }

    content {
      id     = "${rule.key}-gfs-father"
      status = "Enabled"

      filter {
        prefix = "backup/criticality=${rule.key}/backup_type=full/generation=father/"
      }

      # Transición inmediata a storage class inicial
      transition {
        days          = 0
        storage_class = rule.value.start_storage_class
      }

      # Transición a DEEP_ARCHIVE (si configurado y respetando mínimo 90 días)
      dynamic "transition" {
        for_each = rule.value.father_da_days > 0 ? [1] : []

        content {
          days          = max(rule.value.father_da_days, var.min_deep_archive_offset_days)
          storage_class = rule.value.father_archive_class
        }
      }

      # Expiración según retención
      expiration {
        days = rule.value.father_retention_days
      }

      noncurrent_version_expiration {
        noncurrent_days = 30
      }
    }
  }

  # === GRANDFATHER: Backups full mensuales/trimestrales/semestrales ===
  dynamic "rule" {
    for_each = { for k, v in var.gfs_rules : k => v if v.enable }

    content {
      id     = "${rule.key}-gfs-grandfather"
      status = "Enabled"

      filter {
        prefix = "backup/criticality=${rule.key}/backup_type=full/generation=grandfather/"
      }

      # Transición inmediata
      transition {
        days          = 0
        storage_class = rule.value.start_storage_class
      }

      # Transición a DEEP_ARCHIVE para retención larga
      dynamic "transition" {
        for_each = rule.value.grandfather_da_days > 0 ? [1] : []

        content {
          days          = max(rule.value.grandfather_da_days, var.min_deep_archive_offset_days)
          storage_class = rule.value.grandfather_archive_class
        }
      }

      # Expiración después de retención larga (ej: 7 años)
      expiration {
        days = rule.value.grandfather_retention_days
      }

      noncurrent_version_expiration {
        noncurrent_days = 30
      }
    }
  }

  # ─────────────────────────────────────────────────────────────────────────
  # REGLAS DE LIMPIEZA (Archivos operacionales)
  # ─────────────────────────────────────────────────────────────────────────

  # Inventarios origen
  rule {
    id     = "cleanup-inventory-source"
    status = "Enabled"

    filter {
      prefix = "inventory-source/"
    }

    expiration {
      days = 21
    }

    noncurrent_version_expiration {
      noncurrent_days = 1
    }
  }

  # Reportes de S3 Batch
  rule {
    id     = "cleanup-batch-reports"
    status = "Enabled"

    filter {
      prefix = "reports/"
    }

    expiration {
      days = 21
    }

    noncurrent_version_expiration {
      noncurrent_days = 1
    }
  }

  # Checkpoints
  rule {
    id     = "cleanup-checkpoints"
    status = "Enabled"

    filter {
      prefix = "checkpoints/"
    }

    expiration {
      days = 21
    }

    noncurrent_version_expiration {
      noncurrent_days = 1
    }
  }

  # Manifiestos temporales
  rule {
    id     = "cleanup-manifests-temp"
    status = "Enabled"

    filter {
      prefix = "manifests/temp/"
    }

    expiration {
      days = 21
    }

    noncurrent_version_expiration {
      noncurrent_days = 1
    }
  }

  depends_on = [aws_s3_bucket_versioning.central_backup]
}

# ============================================================================
# BUCKET POLICY
# ============================================================================

resource "aws_s3_bucket_policy" "central_backup" {
  bucket = aws_s3_bucket.central_backup.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        # Permitir gestión de bucket policy por la cuenta
        {
          Sid    = "AllowSameAccountUpdateBucketPolicy"
          Effect = "Allow"
          Principal = {
            AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
          }
          Action = [
            "s3:GetBucketPolicy",
            "s3:PutBucketPolicy"
          ]
          Resource = aws_s3_bucket.central_backup.arn
        },

        # Permitir que S3 Inventory escriba reportes
        {
          Sid    = "AllowS3InventoryReports"
          Effect = "Allow"
          Principal = {
            Service = "s3.amazonaws.com"
          }
          Action   = "s3:PutObject"
          Resource = "${aws_s3_bucket.central_backup.arn}/inventory-source/*"
          Condition = {
            StringEquals = {
              "aws:SourceAccount" = data.aws_caller_identity.current.account_id
              "s3:x-amz-acl"      = "bucket-owner-full-control"
            }
            ArnLike = {
              "aws:SourceArn" = "arn:aws:s3:::*"
            }
          }
        },

        # Permitir que S3 Inventory lea ACL del bucket
        {
          Sid    = "AllowS3InventoryGetBucketAcl"
          Effect = "Allow"
          Principal = {
            Service = "s3.amazonaws.com"
          }
          Action = [
            "s3:GetBucketAcl",
            "s3:GetBucketLocation"
          ]
          Resource = aws_s3_bucket.central_backup.arn
        },

        # Permitir acceso a workers (Lambdas, Batch)
        {
          Sid    = "AllowWorkerRolesObjectAccess"
          Effect = "Allow"
          Principal = {
            AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
          }
          Action = [
            "s3:PutObject",
            "s3:GetObject",
            "s3:DeleteObject"
          ]
          Resource = "${aws_s3_bucket.central_backup.arn}/*"
        },

        # Permitir listado del bucket
        {
          Sid    = "AllowWorkerRolesListBucket"
          Effect = "Allow"
          Principal = {
            AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
          }
          Action   = "s3:ListBucket"
          Resource = aws_s3_bucket.central_backup.arn
        },

        # Permitir que S3 Batch Operations lea/escriba
        {
          Sid    = "AllowBatchOperationsObjectAccess"
          Effect = "Allow"
          Principal = {
            Service = "batchoperations.s3.amazonaws.com"
          }
          Action = [
            "s3:GetObject",
            "s3:PutObject"
          ]
          Resource = "${aws_s3_bucket.central_backup.arn}/*"
          Condition = {
            StringEquals = {
              "aws:SourceAccount" = data.aws_caller_identity.current.account_id
            }
          }
        },

        # Permitir que S3 Batch Operations liste
        {
          Sid    = "AllowBatchOperationsListBucket"
          Effect = "Allow"
          Principal = {
            Service = "batchoperations.s3.amazonaws.com"
          }
          Action   = "s3:ListBucket"
          Resource = aws_s3_bucket.central_backup.arn
          Condition = {
            StringEquals = {
              "aws:SourceAccount" = data.aws_caller_identity.current.account_id
            }
          }
        }
      ],

      # Política anti-borrado (opcional)
      var.deny_delete_enabled ? (
        length(var.allow_delete_principals) > 0 ? [
          {
            Sid    = "DenyDeleteForNonBreakglass"
            Effect = "Deny"
            Principal = {
              AWS = "*"
            }
            Action = [
              "s3:DeleteObject",
              "s3:DeleteObjectVersion",
              "s3:AbortMultipartUpload"
            ]
            Resource = "${aws_s3_bucket.central_backup.arn}/*"
            Condition = {
              StringNotEquals = {
                "aws:PrincipalArn" = var.allow_delete_principals
              }
            }
          }
          ] : [
          {
            Sid    = "DenyAllDelete"
            Effect = "Deny"
            Principal = {
              AWS = "*"
            }
            Action = [
              "s3:DeleteObject",
              "s3:DeleteObjectVersion",
              "s3:AbortMultipartUpload"
            ]
            Resource = "${aws_s3_bucket.central_backup.arn}/*"
          }
        ]
      ) : [],

      # Requerir MFA para delete (opcional)
      var.deny_delete_enabled && var.require_mfa_for_delete ? [
        {
          Sid    = "DenyDeleteWithoutMFA"
          Effect = "Deny"
          Principal = {
            AWS = "*"
          }
          Action = [
            "s3:DeleteObject",
            "s3:DeleteObjectVersion",
            "s3:AbortMultipartUpload"
          ]
          Resource = "${aws_s3_bucket.central_backup.arn}/*"
          Condition = {
            Bool = {
              "aws:MultiFactorAuthPresent" = "false"
            }
          }
        }
      ] : []
    )
  })
}

# ============================================================================
# BACKUP VAULT (AWS Backup)
# ============================================================================

resource "aws_backup_vault" "central" {
  name = var.central_backup_vault_name

  tags = merge(
    local.common_tags,
    {
      Name = var.central_backup_vault_name
    }
  )
}

# ============================================================================
# OUTPUTS
# ============================================================================

output "central_backup_bucket_name" {
  description = "Nombre del bucket central de backups (USAR EN TODO EL CÓDIGO)"
  value       = aws_s3_bucket.central_backup.bucket
}

output "central_backup_bucket_arn" {
  description = "ARN del bucket central de backups"
  value       = aws_s3_bucket.central_backup.arn
}

output "central_backup_bucket_region" {
  description = "Región del bucket central"
  value       = var.aws_region
}

output "backup_vault_arn" {
  description = "ARN del AWS Backup Vault"
  value       = aws_backup_vault.central.arn
}
