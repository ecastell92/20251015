// ============================================================================
// Initiative Logic Project - CORREGIDO
// ============================================================================
// CAMBIOS:
// 1. CENTRAL_ACCOUNT_ID habilitada en find_resources
// 2. Variables de frecuencia para incremental_backup
// 3. Frecuencias extraídas desde schedule_expressions
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

// -----------------------------------------------------------------------------
// Current account info
data "aws_caller_identity" "current" {}

// -----------------------------------------------------------------------------
// Locals
locals {
  prefijo_recursos = "${var.tenant}-${lower(var.environment)}"
  sufijo_recursos  = "${lower(var.iniciativa)}-${var.sufijo_recursos}"

  central_backup_bucket_arn = "arn:aws:s3:::${var.central_backup_bucket_name}"

  # Extraer frecuencias en horas desde schedule_expressions
  # Admite formatos con espacios/mayúsculas y también "days" → horas
  # Ejemplos:
  #   rate(12 hours)  => 12
  #   rate( 24 HOURS ) => 24
  #   rate(2 days)    => 48
  backup_frequencies = {
    for k, v in var.schedule_expressions : k => (
      v.incremental == null || trimspace(v.incremental) == "" ? 0 : (
        can(regex("(?i)^rate\\(\\s*(\\d+)\\s*hours?\\s*\\)$", trimspace(v.incremental))) ?
        tonumber(regex("(?i)^rate\\(\\s*(\\d+)\\s*hours?\\s*\\)$", trimspace(v.incremental))[0]) : (
          can(regex("(?i)^rate\\(\\s*(\\d+)\\s*days?\\s*\\)$", trimspace(v.incremental))) ?
          tonumber(regex("(?i)^rate\\(\\s*(\\d+)\\s*days?\\s*\\)$", trimspace(v.incremental))[0]) * 24 : 0
        )
      )
    )
  }

  # Criticidades con event-driven (S3→SQS): 0 < horas <= 24
  notif_criticalities = [
    for k, h in local.backup_frequencies : k
    if try(h, 0) > 0 && try(h, 0) <= 24
  ]

  # Hora para ejecución única de la lambda de configuración (~5 minutos después de apply)
  backup_configurations_once_time = formatdate("YYYY-MM-DD'T'HH:mm:ss", timeadd(timestamp(), "5m"))
}

// -----------------------------------------------------------------------------
// IAM Roles and Policies

// --- Incremental Backup Lambda ---
resource "aws_iam_role" "incremental_backup" {
  name = "${local.prefijo_recursos}-iam-role-incremental-bck-${local.sufijo_recursos}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Action    = "sts:AssumeRole",
      Effect    = "Allow",
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "lambda_backup_policy" {
  role = aws_iam_role.incremental_backup.name

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Sid      = "AllowReadBucketTags",
        Effect   = "Allow",
        Action   = ["s3:GetBucketTagging"],
        Resource = "arn:aws:s3:::*"
      },
      {
        Sid    = "AllowReadSourceObjects",
        Effect = "Allow",
        Action = [
          "s3:GetObject",
          "s3:GetObjectVersion"
        ],
        Resource = "arn:aws:s3:::*/*"
      },
      {
        Sid      = "AllowLogging",
        Effect   = "Allow",
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"],
        Resource = "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:*"
      },
      {
        Sid      = "AllowSQSPolling",
        Effect   = "Allow",
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"],
        Resource = aws_sqs_queue.s3_events_queue.arn
      },
      {
        Sid    = "AllowWriteToCentralBackup"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:PutObjectAcl",
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Resource = [
          local.central_backup_bucket_arn,
          "${local.central_backup_bucket_arn}/*"
        ]
      },
      {
        Sid    = "AllowBatchJobSubmission",
        Effect = "Allow",
        Action = [
          "s3control:CreateJob",
          "s3control:DescribeJob",
          "s3control:ListJobs",
          "s3:CreateJob",
          "s3:DescribeJob",
          "s3:ListJobs"
        ],
        Resource = "*"
      },
      {
        Sid      = "AllowPassBatchRole",
        Effect   = "Allow",
        Action   = ["iam:PassRole"],
        Resource = aws_iam_role.batch_job_role.arn
      },
    ]
  })
}

// -----------------------------------------------------------------------------
// Find Resources Lambda
resource "aws_iam_role" "find_resources" {
  name = "${local.prefijo_recursos}-iam-role-find-resources-${local.sufijo_recursos}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Action    = "sts:AssumeRole",
      Effect    = "Allow",
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })

  tags = {
    Initiative  = var.iniciativa
    Environment = var.environment
  }
}

resource "aws_iam_role_policy" "find_resources" {
  name = "${local.prefijo_recursos}-iam-policy-find-resources-${local.sufijo_recursos}"
  role = aws_iam_role.find_resources.name

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Sid      = "AllowTaggingAPI",
        Effect   = "Allow",
        Action   = ["tag:GetResources"],
        Resource = "*"
      },
      {
        Sid      = "AllowReadBucketTags",
        Effect   = "Allow",
        Action   = ["s3:GetBucketTagging"],
        Resource = "arn:aws:s3:::*"
      },
      {
        Sid    = "AllowS3InventoryAndNotifications",
        Effect = "Allow",
        Action = [
          "s3:GetBucketNotification",
          "s3:PutBucketNotification",
          "s3:GetBucketNotificationConfiguration",
          "s3:PutBucketNotificationConfiguration",
          "s3:GetBucketInventoryConfiguration",
          "s3:PutBucketInventoryConfiguration",
          "s3:GetInventoryConfiguration",
          "s3:PutInventoryConfiguration",
          "s3:DeleteBucketInventoryConfiguration"
        ],
        Resource = "arn:aws:s3:::*"
      },
      {
        Sid    = "AllowSourceBucketPolicyManagement",
        Effect = "Allow",
        Action = [
          "s3:GetBucketPolicy",
          "s3:PutBucketPolicy"
        ],
        Resource = "arn:aws:s3:::*"
      },
      {
        Sid    = "AllowCentralBucketPolicyUpdate",
        Effect = "Allow",
        Action = [
          "s3:GetBucketPolicy",
          "s3:PutBucketPolicy"
        ],
        Resource = [
          "arn:aws:s3:::${var.central_backup_bucket_name}",
          "arn:aws:s3:::${var.central_backup_bucket_name}/*"
        ]
      },
      {
        Sid    = "AllowWriteInventoryToCentral",
        Effect = "Allow",
        Action = ["s3:PutObject", "s3:GetObject", "s3:ListBucket"],
        Resource = [
          "arn:aws:s3:::${var.central_backup_bucket_name}",
          "arn:aws:s3:::${var.central_backup_bucket_name}/*"
        ]
      },
      {
        Sid    = "AllowLogging",
        Effect = "Allow",
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ],
        Resource = "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:*"
      },
      {
        Sid      = "AllowSTS",
        Effect   = "Allow",
        Action   = ["sts:GetCallerIdentity"],
        Resource = "*"
      }
    ]
  })
}

// -----------------------------------------------------------------------------
// Filter Inventory Lambda
resource "aws_iam_role" "filter_inventory" {
  name = "${local.prefijo_recursos}-iam-role-filter-inventory-${local.sufijo_recursos}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Action    = "sts:AssumeRole",
      Effect    = "Allow",
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })

  tags = {
    Initiative  = var.iniciativa
    Environment = var.environment
  }
}

resource "aws_iam_policy" "filter_inventory_lambda_policy" {
  name        = "${local.prefijo_recursos}-filter-inventory-policy-${local.sufijo_recursos}"
  description = "Permisos para que la Lambda filter_inventory lea y escriba manifests de S3 Inventory"
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Sid    = "S3ReadWriteInventory",
        Effect = "Allow",
        Action = ["s3:ListBucket", "s3:GetObject", "s3:PutObject"],
        Resource = [
          "arn:aws:s3:::*",
          "arn:aws:s3:::*/*"
        ]
      },
      {
        Sid    = "AllowLogging",
        Effect = "Allow",
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ],
        Resource = "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "filter_inventory_lambda_policy_attach" {
  role       = aws_iam_role.filter_inventory.name
  policy_arn = aws_iam_policy.filter_inventory_lambda_policy.arn
}

// -----------------------------------------------------------------------------
// Batch Job ROLE
resource "aws_iam_role" "batch_job_role" {
  name = "${local.prefijo_recursos}-iam-role-batch-job-${local.sufijo_recursos}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect    = "Allow",
        Principal = { Service = "batchoperations.s3.amazonaws.com" },
        Action    = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Initiative  = var.iniciativa
    Environment = var.environment
  }
}

resource "aws_iam_role_policy" "batch_job_role_policy" {
  name = "${local.prefijo_recursos}-iam-policy-batch-job-role-${local.sufijo_recursos}"
  role = aws_iam_role.batch_job_role.name

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = concat([
      {
        Sid      = "AllowReadFromSourceBuckets",
        Effect   = "Allow",
        Action   = ["s3:GetObject"],
        Resource = "arn:aws:s3:::*/*"
      },
      {
        Sid    = "AllowWriteToCentralBucket",
        Effect = "Allow",
        Action = ["s3:PutObject", "s3:ListBucket"],
        Resource = [
          local.central_backup_bucket_arn,
          "${local.central_backup_bucket_arn}/*"
        ]
      },
      {
        Sid    = "AllowReadManifestFromManifestsBucket",
        Effect = "Allow",
        Action = ["s3:GetObject", "s3:GetObjectVersion", "s3:ListBucket"],
        Resource = [
          local.central_backup_bucket_arn,
          "${local.central_backup_bucket_arn}/*"
        ]
      }
    ], length(var.source_kms_key_arns) > 0 ? [
      {
        Sid    = "AllowKMSToReadSourceObjects",
        Effect = "Allow",
        Action = [
          "kms:Decrypt",
          "kms:DescribeKey",
          "kms:ReEncryptFrom",
          "kms:GenerateDataKey"
        ],
        Resource = var.source_kms_key_arns
      }
    ] : [], var.kms_allow_viaservice ? [
      {
        Sid    = "AllowKMSDecryptViaS3Service",
        Effect = "Allow",
        Action = [
          "kms:Decrypt",
          "kms:DescribeKey",
          "kms:ReEncryptFrom",
          "kms:GenerateDataKey"
        ],
        Resource = "*",
        Condition = {
          StringEquals = {
            "kms:ViaService" : "s3.${var.aws_region}.amazonaws.com"
          }
        }
      }
    ] : [])
  })
}

// -----------------------------------------------------------------------------
// Launch Batch Job Lambda
resource "aws_iam_role" "launch_batch_job" {
  name = "${local.prefijo_recursos}-iam-role-launch-batch-job-${local.sufijo_recursos}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Action    = "sts:AssumeRole",
      Effect    = "Allow",
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })

  tags = {
    Initiative  = var.iniciativa
    Environment = var.environment
  }
}

resource "aws_iam_role_policy" "launch_batch_job" {
  name = "${local.prefijo_recursos}-iam-policy-launch-batch-job-${local.sufijo_recursos}"
  role = aws_iam_role.launch_batch_job.name
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Sid    = "AllowS3ControlCreateJob",
        Effect = "Allow",
        Action = [
          "s3control:CreateJob",
          "s3control:DescribeJob",
          "s3control:ListJobs",
          "s3:CreateJob",
          "s3:DescribeJob",
          "s3:ListJobs"
        ],
        Resource = "*"
      },
      {
        Sid      = "AllowPassBatchJobRole",
        Effect   = "Allow",
        Action   = ["iam:PassRole"],
        Resource = aws_iam_role.batch_job_role.arn
      },
      {
        Sid    = "AllowS3ReadWrite",
        Effect = "Allow",
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket"
        ],
        Resource = [
          local.central_backup_bucket_arn,
          "${local.central_backup_bucket_arn}/*"
        ]
      },
      {
        Sid    = "AllowLogs",
        Effect = "Allow",
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ],
        Resource = "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:*"
      }
    ]
  })
}

// -----------------------------------------------------------------------------
// SQS Queue for S3 events
resource "aws_sqs_queue" "s3_events_queue" {
  name                       = "${local.prefijo_recursos}-s3-events-${local.sufijo_recursos}"
  visibility_timeout_seconds = 900
  receive_wait_time_seconds  = 10

  # Dead Letter Queue configuration
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.s3_events_dlq.arn
    maxReceiveCount     = 3
  })

  tags = {
    Initiative  = var.iniciativa
    Environment = var.environment
  }

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect    = "Allow",
        Principal = { Service = "s3.amazonaws.com" },
        Action    = "sqs:SendMessage",
        Resource  = "arn:aws:sqs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:${local.prefijo_recursos}-s3-events-${local.sufijo_recursos}",
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      }
    ]
  })
}

// -----------------------------------------------------------------------------
// Lambda Functions
data "archive_file" "filter_inventory_zip" {
  type        = "zip"
  source_dir  = "${path.module}/lambdas/filter_inventory"
  output_path = "${path.module}/build/filter_inventory.zip"
}

data "archive_file" "find_resources_zip" {
  type        = "zip"
  source_dir  = "${path.module}/lambdas/find_resources"
  output_path = "${path.module}/build/find_resources.zip"
}

resource "aws_lambda_function" "find_resources" {
  function_name    = "${local.prefijo_recursos}-find-resources-${local.sufijo_recursos}"
  filename         = data.archive_file.find_resources_zip.output_path
  source_code_hash = data.archive_file.find_resources_zip.output_base64sha256
  handler          = "lambda_function.lambda_handler"
  runtime          = "python3.11"
  role             = aws_iam_role.find_resources.arn
  timeout          = 900

  environment {
    variables = {
      LOG_LEVEL                        = "INFO"
      SQS_QUEUE_ARN                    = aws_sqs_queue.s3_events_queue.arn
      CENTRAL_BACKUP_BUCKET            = var.central_backup_bucket_name
      CENTRAL_ACCOUNT_ID               = var.central_account_id
      CRITICALITIES_WITH_NOTIFICATIONS = join(",", local.notif_criticalities)
    }
  }

  tags = {
    Initiative  = var.iniciativa
    Environment = var.environment
  }
}

resource "aws_lambda_function" "filter_inventory" {
  function_name    = "${local.prefijo_recursos}-filter-inventory-${local.sufijo_recursos}"
  filename         = data.archive_file.filter_inventory_zip.output_path
  source_code_hash = data.archive_file.filter_inventory_zip.output_base64sha256
  handler          = "lambda_function.lambda_handler"
  runtime          = "python3.11"
  role             = aws_iam_role.filter_inventory.arn
  timeout          = 900

  environment {
    variables = {
      LOG_LEVEL                   = "INFO"
      ALLOWED_PREFIXES            = jsonencode(var.allowed_prefixes)
      BACKUP_BUCKET               = var.central_backup_bucket_name
      FORCE_FULL_ON_FIRST_RUN     = tostring(var.force_full_on_first_run)
      FALLBACK_MAX_OBJECTS        = var.fallback_max_objects == null ? "" : tostring(var.fallback_max_objects)
      FALLBACK_TIME_LIMIT_SECONDS = var.fallback_time_limit_seconds == null ? "" : tostring(var.fallback_time_limit_seconds)
    }
  }

  tags = {
    Initiative  = var.iniciativa
    Environment = var.environment
  }
}

data "archive_file" "launch_batch_job_zip" {
  type        = "zip"
  source_dir  = "${path.module}/lambdas/launch_batch_job"
  output_path = "${path.module}/build/launch_batch_job.zip"
}

resource "aws_lambda_function" "launch_batch_job" {
  function_name    = "${local.prefijo_recursos}-launch-batch-job-${local.sufijo_recursos}"
  filename         = data.archive_file.launch_batch_job_zip.output_path
  source_code_hash = data.archive_file.launch_batch_job_zip.output_base64sha256
  handler          = "lambda_function.lambda_handler"
  runtime          = "python3.11"
  role             = aws_iam_role.launch_batch_job.arn
  timeout          = 300

  environment {
    variables = {
      LOG_LEVEL            = "INFO"
      ACCOUNT_ID           = data.aws_caller_identity.current.account_id
      BACKUP_BUCKET_ARN    = local.central_backup_bucket_arn
      BATCH_ROLE_ARN       = aws_iam_role.batch_job_role.arn
      S3_BACKUP_INICIATIVA = var.iniciativa
    }
  }

  tags = {
    Initiative  = var.iniciativa
    Environment = var.environment
  }
}

data "archive_file" "incremental_backup_zip" {
  type        = "zip"
  source_dir  = "${path.module}/lambdas/incremental_backup"
  output_path = "${path.module}/build/incremental_backup.zip"
}

resource "aws_lambda_function" "incremental_backup" {
  function_name    = "${local.prefijo_recursos}-incremental-backup-${local.sufijo_recursos}"
  filename         = data.archive_file.incremental_backup_zip.output_path
  source_code_hash = data.archive_file.incremental_backup_zip.output_base64sha256
  handler          = "lambda_function.lambda_handler"
  runtime          = "python3.11"
  role             = aws_iam_role.incremental_backup.arn
  memory_size      = 512
  timeout          = 300

  environment {
    variables = merge(
      {
        LOG_LEVEL              = "INFO"
        BACKUP_BUCKET          = var.central_backup_bucket_name
        BACKUP_BUCKET_ARN      = local.central_backup_bucket_arn
        INICIATIVA             = var.iniciativa
        ALLOWED_PREFIXES       = jsonencode(var.allowed_prefixes)
        CRITICALITY_TAG_KEY    = var.criticality_tag
        GENERATION_INCREMENTAL = "son"
        ACCOUNT_ID             = data.aws_caller_identity.current.account_id
        BATCH_ROLE_ARN         = aws_iam_role.batch_job_role.arn
      },

      {
        for criticality, freq_hours in local.backup_frequencies :
        "BACKUP_FREQUENCY_HOURS_${upper(criticality)}" => tostring(freq_hours)
      }
    )
  }

  tags = {
    Initiative  = var.iniciativa
    Environment = var.environment
  }
}

// -----------------------------------------------------------------------------
// Restore from Backup - Lambda (S3-only, sin DynamoDB)
// -----------------------------------------------------------------------------

resource "aws_iam_role" "restore_from_backup" {
  name = "${local.prefijo_recursos}-iam-role-restore-${local.sufijo_recursos}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Action    = "sts:AssumeRole",
      Effect    = "Allow",
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })

  tags = {
    Initiative  = var.iniciativa
    Environment = var.environment
  }
}

resource "aws_iam_role_policy" "restore_from_backup" {
  name = "${local.prefijo_recursos}-iam-policy-restore-${local.sufijo_recursos}"
  role = aws_iam_role.restore_from_backup.name

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Sid    = "AllowReadCentralBackup",
        Effect = "Allow",
        Action = [
          "s3:GetObject",
          "s3:ListBucket"
        ],
        Resource = [
          local.central_backup_bucket_arn,
          "${local.central_backup_bucket_arn}/*"
        ]
      },
      {
        Sid    = "AllowWriteToSourceBuckets",
        Effect = "Allow",
        Action = [
          "s3:PutObject",
          "s3:PutObjectAcl"
        ],
        Resource = "arn:aws:s3:::*/*"
      },
      {
        Sid    = "AllowLogging",
        Effect = "Allow",
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ],
        Resource = "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:*"
      }
    ]
  })
}

data "archive_file" "restore_from_backup_zip" {
  type        = "zip"
  source_dir  = "${path.module}/lambdas/restore_from_backup"
  output_path = "${path.module}/build/restore_from_backup.zip"
}

resource "aws_lambda_function" "restore_from_backup" {
  function_name    = "${local.prefijo_recursos}-restore-from-backup-${local.sufijo_recursos}"
  filename         = data.archive_file.restore_from_backup_zip.output_path
  source_code_hash = data.archive_file.restore_from_backup_zip.output_base64sha256
  handler          = "lambda_function.lambda_handler"
  runtime          = "python3.11"
  role             = aws_iam_role.restore_from_backup.arn
  timeout          = 900
  memory_size      = 512

  environment {
    variables = {
      LOG_LEVEL      = "INFO"
      CENTRAL_BUCKET = var.central_backup_bucket_name
      INITIATIVE     = var.iniciativa
    }
  }

  tags = {
    Initiative  = var.iniciativa
    Environment = var.environment
  }
}

resource "aws_lambda_event_source_mapping" "sqs_event" {
  event_source_arn = aws_sqs_queue.s3_events_queue.arn
  function_name    = aws_lambda_function.incremental_backup.function_name

  # Optimized batching
  batch_size                         = 256
  maximum_batching_window_in_seconds = 60

  # Report per-item failures back to SQS for retries
  function_response_types = ["ReportBatchItemFailures"]

  # Control concurrency for event source mapping
  scaling_config {
    maximum_concurrency = 10
  }
}

// -----------------------------------------------------------------------------
// Dead Letter Queue for failed S3 event messages
resource "aws_sqs_queue" "s3_events_dlq" {
  name                      = "${local.prefijo_recursos}-s3-events-dlq-${local.sufijo_recursos}"
  message_retention_seconds = 1209600 # 14 days

  tags = {
    Initiative  = var.iniciativa
    Environment = var.environment
    Purpose     = "Dead Letter Queue para eventos S3 fallidos"
  }
}

// -----------------------------------------------------------------------------
// CloudWatch Log Groups with retention for each Lambda
resource "aws_cloudwatch_log_group" "find_resources" {
  name              = "/aws/lambda/${aws_lambda_function.find_resources.function_name}"
  retention_in_days = 7

  tags = {
    Initiative  = var.iniciativa
    Environment = var.environment
    CostCenter  = "optimized"
  }
}

resource "aws_cloudwatch_log_group" "filter_inventory" {
  name              = "/aws/lambda/${aws_lambda_function.filter_inventory.function_name}"
  retention_in_days = 7

  tags = {
    Initiative  = var.iniciativa
    Environment = var.environment
    CostCenter  = "optimized"
  }
}

resource "aws_cloudwatch_log_group" "launch_batch_job" {
  name              = "/aws/lambda/${aws_lambda_function.launch_batch_job.function_name}"
  retention_in_days = 7

  tags = {
    Initiative  = var.iniciativa
    Environment = var.environment
    CostCenter  = "optimized"
  }
}

resource "aws_cloudwatch_log_group" "incremental_backup" {
  name              = "/aws/lambda/${aws_lambda_function.incremental_backup.function_name}"
  retention_in_days = 7

  tags = {
    Initiative  = var.iniciativa
    Environment = var.environment
    CostCenter  = "optimized"
  }
}

resource "aws_cloudwatch_log_group" "backup_configurations" {
  name              = "/aws/lambda/${aws_lambda_function.backup_configurations.function_name}"
  retention_in_days = 14

  tags = {
    Initiative  = var.iniciativa
    Environment = var.environment
    CostCenter  = "optimized"
  }
}

// -----------------------------------------------------------------------------
// SNS Topic and alarms for failures
resource "aws_sns_topic" "backup_alerts" {
  name = "${local.prefijo_recursos}-backup-alerts-${local.sufijo_recursos}"

  tags = {
    Initiative  = var.iniciativa
    Environment = var.environment
  }
}

resource "aws_sns_topic_subscription" "backup_alerts_email" {
  topic_arn = aws_sns_topic.backup_alerts.arn
  protocol  = "email"
  endpoint  = "tu-email@example.com"
}

resource "aws_cloudwatch_metric_alarm" "dlq_messages" {
  alarm_name          = "${local.prefijo_recursos}-dlq-has-messages"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 300
  statistic           = "Average"
  threshold           = 0
  alarm_description   = "Dead Letter Queue tiene mensajes fallidos"
  alarm_actions       = [aws_sns_topic.backup_alerts.arn]

  dimensions = {
    QueueName = aws_sqs_queue.s3_events_dlq.name
  }

  tags = {
    Initiative  = var.iniciativa
    Environment = var.environment
  }
}

resource "aws_cloudwatch_metric_alarm" "incremental_backup_errors" {
  alarm_name          = "${local.prefijo_recursos}-incremental-backup-errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Sum"
  threshold           = 5
  alarm_description   = "Lambda incremental_backup tiene más de 5 errores en 5 minutos"
  alarm_actions       = [aws_sns_topic.backup_alerts.arn]

  dimensions = {
    FunctionName = aws_lambda_function.incremental_backup.function_name
  }

  tags = {
    Initiative  = var.iniciativa
    Environment = var.environment
  }
}

resource "aws_cloudwatch_metric_alarm" "step_function_failures" {
  alarm_name          = "${local.prefijo_recursos}-backup-step-function-failures"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ExecutionsFailed"
  namespace           = "AWS/States"
  period              = 300
  statistic           = "Sum"
  threshold           = 0
  alarm_description   = "Step Function de backup ha fallado"
  alarm_actions       = [aws_sns_topic.backup_alerts.arn]

  dimensions = {
    StateMachineArn = aws_sfn_state_machine.backup_orchestrator.arn
  }

  tags = {
    Initiative  = var.iniciativa
    Environment = var.environment
  }
}

// -----------------------------------------------------------------------------
// Step Function State Machine
resource "aws_iam_role" "step_function" {
  name = "${local.prefijo_recursos}-backup-step-role-${local.sufijo_recursos}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action    = "sts:AssumeRole",
        Effect    = "Allow",
        Principal = { Service = "states.amazonaws.com" }
      }
    ]
  })

  tags = {
    Initiative  = var.iniciativa
    Environment = var.environment
  }
}

resource "aws_iam_role_policy" "step_function" {
  name = "${local.prefijo_recursos}-backup-step-policy-${local.sufijo_recursos}"
  role = aws_iam_role.step_function.name
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Sid    = "AllowLambdaInvoke",
        Effect = "Allow",
        Action = ["lambda:InvokeFunction"],
        Resource = [
          aws_lambda_function.filter_inventory.arn,
          aws_lambda_function.launch_batch_job.arn,
          aws_lambda_function.find_resources.arn
        ]
      }
    ]
  })
}

resource "aws_sfn_state_machine" "backup_orchestrator" {
  name     = "${local.prefijo_recursos}-s3-backup-orchestrator-${local.sufijo_recursos}"
  role_arn = aws_iam_role.step_function.arn
  definition = jsonencode({
    Comment = "Backup orchestrator for S3 using inventory and Batch Ops",
    StartAt = "FindResources",
    States = {
      "FindResources" = {
        "Type"       = "Task",
        "Resource"   = aws_lambda_function.find_resources.arn,
        "ResultPath" = "$.BucketsResult",
        "Next"       = "MapBuckets"
      },
      "MapBuckets" = {
        "Type"           = "Map",
        "ItemsPath"      = "$.BucketsResult.Buckets",
        "MaxConcurrency" = 5,
        "Parameters" = {
          "source_bucket.$"      = "$$.Map.Item.Value.source_bucket",
          "inventory_key.$"      = "$$.Map.Item.Value.inventory_key",
          "criticality.$"        = "$$.Map.Item.Value.criticality",
          "backup_bucket.$"      = "$$.Map.Item.Value.backup_bucket",
          "backup_type.$"        = "$.BackupType",
          "generation.$"         = "$.Generation",
          "target_criticality.$" = "$.Criticality"
        },
        "Iterator" = {
          "StartAt" = "CheckBucketCriticality",
          "States" = {
            "CheckBucketCriticality" = {
              "Type" = "Choice",
              "Choices" = [
                {
                  "Variable"         = "$.criticality",
                  "StringEqualsPath" = "$.target_criticality",
                  "Next"             = "GenerateManifest"
                }
              ],
              "Default" = "SkipBucket"
            },
            "SkipBucket" = {
              "Type" = "Pass",
              "End"  = true
            },
            "GenerateManifest" = {
              "Type"       = "Task",
              "Resource"   = aws_lambda_function.filter_inventory.arn,
              "ResultPath" = "$.ManifestResult",
              "Next"       = "CheckManifest"
            },
            "CheckManifest" = {
              "Type" = "Choice",
              "Choices" = [
                {
                  "Variable"     = "$.ManifestResult.status",
                  "StringEquals" = "SUCCESS",
                  "Next"         = "LaunchBatchJob"
                }
              ],
              "Default" = "EndBucket"
            },
            "LaunchBatchJob" = {
              "Type"     = "Task",
              "Resource" = aws_lambda_function.launch_batch_job.arn,
              "Parameters" = {
                "status.$"        = "$.ManifestResult.status",
                "manifest.$"      = "$.ManifestResult.manifest",
                "manifest_key.$"  = "$.ManifestResult.manifest_key",
                "source_bucket.$" = "$.ManifestResult.source_bucket",
                "backup_type.$"   = "$.backup_type",
                "generation.$"    = "$.generation",
                "criticality.$"   = "$.ManifestResult.criticality"
              },
              "End" = true
            },
            "EndBucket" = {
              "Type" = "Pass",
              "End"  = true
            }
          }
        },
        "End" = true
      }
    }
  })
  tags = var.backup_tags
}

// -----------------------------------------------------------------------------
// EventBridge Scheduler
resource "aws_scheduler_schedule_group" "backup_schedules" {
  name = "${local.prefijo_recursos}-schedules-${local.sufijo_recursos}"

  tags = {
    Initiative  = var.iniciativa
    Environment = var.environment
  }
}

resource "aws_iam_role" "scheduler_execution_role" {
  name = "${local.prefijo_recursos}-scheduler-role-${local.sufijo_recursos}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect    = "Allow",
      Principal = { Service = "scheduler.amazonaws.com" },
      Action    = "sts:AssumeRole"
    }]
  })

  tags = {
    Initiative  = var.iniciativa
    Environment = var.environment
  }
}

resource "aws_iam_role_policy" "scheduler_policy" {
  name = "${local.prefijo_recursos}-scheduler-policy-${local.sufijo_recursos}"
  role = aws_iam_role.scheduler_execution_role.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Sid      = "AllowStartStateMachine",
        Effect   = "Allow",
        Action   = ["states:StartExecution"],
        Resource = aws_sfn_state_machine.backup_orchestrator.arn
      },
      {
        Sid      = "AllowInvokeBackupConfigurationsLambda",
        Effect   = "Allow",
        Action   = ["lambda:InvokeFunction"],
        Resource = aws_lambda_function.backup_configurations.arn
      },
      {
        Sid      = "AllowInvokeFindResourcesLambda",
        Effect   = "Allow",
        Action   = ["lambda:InvokeFunction"],
        Resource = aws_lambda_function.find_resources.arn
      },
      {
        Sid      = "AllowPassRoleToSFN",
        Effect   = "Allow",
        Action   = ["iam:PassRole"],
        Resource = aws_iam_role.step_function.arn
      }
    ]
  })
}

resource "aws_scheduler_schedule" "incremental_schedules" {
  # Solo agenda incrementales cuando la frecuencia es > 24h (manifest_diff)
  for_each = {
    for k, v in var.schedule_expressions :
    k => v
    if try(v.incremental, null) != null
    && trimspace(v.incremental) != ""
    && lookup(local.backup_frequencies, k, 0) > 24
  }

  name        = "${local.prefijo_recursos}-inc-${lower(each.key)}-${local.sufijo_recursos}"
  group_name  = aws_scheduler_schedule_group.backup_schedules.name
  description = "Backup incremental para ${each.key}"

  flexible_time_window { mode = "OFF" }

  schedule_expression = each.value.incremental

  target {
    arn      = aws_sfn_state_machine.backup_orchestrator.arn
    role_arn = aws_iam_role.scheduler_execution_role.arn

    input = jsonencode({
      BackupType  = "incremental"
      Criticality = each.key
      Generation  = "son"
      Schedule    = each.value.incremental
    })
  }
}

resource "aws_scheduler_schedule" "sweep_schedules" {
  for_each = var.schedule_expressions

  name        = "${local.prefijo_recursos}-sweep-${lower(each.key)}-${local.sufijo_recursos}"
  group_name  = aws_scheduler_schedule_group.backup_schedules.name
  description = "Backup completo (sweep) para ${each.key}"

  flexible_time_window { mode = "OFF" }

  schedule_expression = each.value.sweep

  target {
    arn      = aws_sfn_state_machine.backup_orchestrator.arn
    role_arn = aws_iam_role.scheduler_execution_role.arn

    input = jsonencode({
      BackupType  = "full"
      Criticality = each.key
      Generation  = "father"
      Schedule    = each.value.sweep
    })
  }
}

resource "aws_scheduler_schedule" "grandfather_schedules" {
  for_each = { for k, v in var.schedule_expressions : k => v if try(v.grandfather, null) != null && trimspace(v.grandfather) != "" }

  name        = "${local.prefijo_recursos}-grandfather-${lower(each.key)}-${local.sufijo_recursos}"
  group_name  = aws_scheduler_schedule_group.backup_schedules.name
  description = "Backup completo (grandfather) para ${each.key}"

  flexible_time_window { mode = "OFF" }

  schedule_expression = each.value.grandfather

  target {
    arn      = aws_sfn_state_machine.backup_orchestrator.arn
    role_arn = aws_iam_role.scheduler_execution_role.arn

    input = jsonencode({
      BackupType  = "full"
      Criticality = each.key
      Generation  = "grandfather"
      Schedule    = each.value.grandfather
    })
  }
}

// ============================================================================
// Backup de Configuraciones AWS
// ============================================================================

resource "aws_iam_role" "backup_configurations" {
  name = "${local.prefijo_recursos}-iam-role-backup-configs-${local.sufijo_recursos}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Action    = "sts:AssumeRole",
      Effect    = "Allow",
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })

  tags = {
    Initiative  = var.iniciativa
    Environment = var.environment
  }
}

resource "aws_iam_role_policy" "backup_configurations" {
  name = "${local.prefijo_recursos}-iam-policy-backup-configs-${local.sufijo_recursos}"
  role = aws_iam_role.backup_configurations.name

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Sid    = "AllowS3WriteConfigurations",
        Effect = "Allow",
        Action = [
          "s3:PutObject",
          "s3:GetObject"
        ],
        Resource = "${local.central_backup_bucket_arn}/backup/criticality=Critico/backup_type=configurations/*"
      },
      {
        Sid    = "AllowS3ReadBucketConfigurations",
        Effect = "Allow",
        Action = [
          "s3:GetBucketPolicy",
          "s3:GetBucketTagging",
          "s3:GetLifecycleConfiguration",
          "s3:GetEncryptionConfiguration",
          "s3:GetBucketVersioning",
          "s3:ListBucketInventoryConfigurations",
          "s3:GetBucketNotificationConfiguration",
          "s3:GetBucketNotification",
          "s3:GetBucketCors",
          "s3:GetReplicationConfiguration",
          "s3:ListBucket"
        ],
        Resource = "arn:aws:s3:::*"
      },
      {
        Sid    = "AllowS3PutBucketNotifications",
        Effect = "Allow",
        Action = [
          "s3:PutBucketNotificationConfiguration",
          "s3:PutBucketNotification"
        ],
        Resource = "arn:aws:s3:::*"
      },
      {
        Sid    = "AllowGlueReadAll",
        Effect = "Allow",
        Action = [
          "glue:GetDatabases",
          "glue:GetTables",
          "glue:GetJobs",
          "glue:GetCrawlers",
          "glue:GetConnections",
          "glue:GetTriggers",
          "glue:ListWorkflows",
          "glue:GetWorkflow"
        ],
        Resource = "*"
      },
      {
        Sid    = "AllowAthenaReadAll",
        Effect = "Allow",
        Action = [
          "athena:ListWorkGroups",
          "athena:GetWorkGroup",
          "athena:ListDataCatalogs",
          "athena:GetDataCatalog",
          "athena:ListNamedQueries",
          "athena:GetNamedQuery",
          "athena:ListPreparedStatements",
          "athena:GetPreparedStatement"
        ],
        Resource = "*"
      },
      {
        Sid    = "AllowLambdaReadAll",
        Effect = "Allow",
        Action = [
          "lambda:ListFunctions",
          "lambda:GetFunction",
          "lambda:GetFunctionConfiguration",
          "lambda:ListEventSourceMappings",
          "lambda:ListTags"
        ],
        Resource = "*"
      },
      {
        Sid    = "AllowIAMReadRoles",
        Effect = "Allow",
        Action = [
          "iam:ListRoles",
          "iam:GetRole",
          "iam:ListAttachedRolePolicies",
          "iam:ListRolePolicies",
          "iam:GetRolePolicy"
        ],
        Resource = "*"
      },
      {
        Sid    = "AllowStepFunctionsReadAll",
        Effect = "Allow",
        Action = [
          "states:ListStateMachines",
          "states:DescribeStateMachine"
        ],
        Resource = "*"
      },
      {
        Sid    = "AllowEventsReadAll",
        Effect = "Allow",
        Action = [
          "events:ListRules",
          "events:DescribeRule",
          "events:ListTargetsByRule"
        ],
        Resource = "*"
      },
      {
        Sid    = "AllowDynamoDBReadAll",
        Effect = "Allow",
        Action = [
          "dynamodb:ListTables",
          "dynamodb:DescribeTable"
        ],
        Resource = "*"
      },
      {
        Sid    = "AllowRDSReadAll",
        Effect = "Allow",
        Action = [
          "rds:DescribeDBInstances",
          "rds:DescribeDBClusters",
          "rds:DescribeDBParameterGroups",
          "rds:DescribeDBSubnetGroups"
        ],
        Resource = "*"
      },
      {
        Sid    = "AllowResourceTaggingAPI",
        Effect = "Allow",
        Action = [
          "tag:GetResources"
        ],
        Resource = "*"
      },
      {
        Sid    = "AllowLogging",
        Effect = "Allow",
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ],
        Resource = "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:*"
      }
    ]
  })
}

data "archive_file" "backup_configurations_zip" {
  type        = "zip"
  source_dir  = "${path.module}/lambdas/backup_configurations"
  output_path = "${path.module}/build/backup_configurations.zip"
}

resource "aws_lambda_function" "backup_configurations" {
  function_name    = "${local.prefijo_recursos}-backup-configurations-${local.sufijo_recursos}"
  filename         = data.archive_file.backup_configurations_zip.output_path
  source_code_hash = data.archive_file.backup_configurations_zip.output_base64sha256
  handler          = "lambda_function.lambda_handler"
  runtime          = "python3.11"
  role             = aws_iam_role.backup_configurations.arn
  timeout          = 900
  memory_size      = 512

  environment {
    variables = {
      LOG_LEVEL             = var.backup_config_log_level
      BACKUP_BUCKET         = var.central_backup_bucket_name
      INICIATIVA            = var.iniciativa
      TAG_FILTER_KEY        = var.backup_config_tag_filter_key
      TAG_FILTER_VALUE      = var.backup_config_tag_filter_value
      INCLUDE_GLUE          = tostring(var.backup_config_include_glue)
      INCLUDE_ATHENA        = tostring(var.backup_config_include_athena)
      INCLUDE_LAMBDA        = tostring(var.backup_config_include_lambda)
      INCLUDE_IAM           = tostring(var.backup_config_include_iam)
      INCLUDE_STEPFUNCTIONS = tostring(var.backup_config_include_stepfunctions)
      INCLUDE_EVENTBRIDGE   = tostring(var.backup_config_include_eventbridge)
      INCLUDE_DYNAMODB      = tostring(var.backup_config_include_dynamodb)
      INCLUDE_RDS           = tostring(var.backup_config_include_rds)
    }
  }

  tags = {
    Initiative  = var.iniciativa
    Environment = var.environment
  }
}

resource "aws_scheduler_schedule" "backup_configurations_weekly" {
  name        = "${local.prefijo_recursos}-backup-configs-weekly-${local.sufijo_recursos}"
  group_name  = aws_scheduler_schedule_group.backup_schedules.name
  description = "Trigger weekly backup of AWS configurations"

  flexible_time_window { mode = "OFF" }
  schedule_expression = "cron(0 2 ? * SUN *)"

  target {
    arn      = aws_lambda_function.backup_configurations.arn
    role_arn = aws_iam_role.scheduler_execution_role.arn
    input    = jsonencode({ action = "run" })
  }
}

resource "aws_scheduler_schedule" "backup_configurations_once" {
  name        = "${local.prefijo_recursos}-backup-configs-once-${local.sufijo_recursos}"
  group_name  = aws_scheduler_schedule_group.backup_schedules.name
  description = "One-shot run after deploy for backup configurations"

  flexible_time_window { mode = "OFF" }
  schedule_expression = "at(${local.backup_configurations_once_time})"

  target {
    arn      = aws_lambda_function.backup_configurations.arn
    role_arn = aws_iam_role.scheduler_execution_role.arn
    input    = jsonencode({ action = "run-once" })
  }

  lifecycle {
    # Evitar drift por cambio de timestamp en futuros plans
    ignore_changes = [schedule_expression]
  }
}

resource "aws_scheduler_schedule" "find_resources_once" {
  name        = "${local.prefijo_recursos}-find-resources-once-${local.sufijo_recursos}"
  group_name  = aws_scheduler_schedule_group.backup_schedules.name
  description = "One-shot run after deploy to configure S3→SQS notifications"

  flexible_time_window { mode = "OFF" }
  schedule_expression = "at(${local.backup_configurations_once_time})"

  target {
    arn      = aws_lambda_function.find_resources.arn
    role_arn = aws_iam_role.scheduler_execution_role.arn
    input    = jsonencode({})
  }

  lifecycle {
    # Evitar drift por cambio de timestamp en futuros plans
    ignore_changes = [schedule_expression]
  }
}

output "backup_configurations_lambda_arn" {
  description = "ARN de la Lambda de backup de configuraciones"
  value       = aws_lambda_function.backup_configurations.arn
}

output "backup_frequency_configuration" {
  description = "Frecuencias configuradas para incrementales"
  value       = local.backup_frequencies
}

