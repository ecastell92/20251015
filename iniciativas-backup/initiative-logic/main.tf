// ============================================================================
// Initiative Logic Project
//
// Deploys logic required to protect S3 buckets in an initiative account.
// Creates SQS queues, Lambda functions, IAM roles and policies, a Step Function
// state machine and EventBridge Scheduler to orchestrate backups.
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
      # Permisos para copias directas: leer objetos de origen y escribir en bucket central
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
        Sid    = "AllowWriteToCentralBackup",
        Effect = "Allow",
        Action = [
          "s3:PutObject",
          "s3:PutObjectAcl"
        ],
        Resource = [
          "${local.central_backup_bucket_arn}",
          "${local.central_backup_bucket_arn}/*"
        ]
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
      # Permiso para escribir los manifiestos
      {
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
// Find Resources Lambda (crea inventarios en los buckets origen)
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
      # Permite listar buckets con etiquetas
      {
        Sid      = "AllowTaggingAPI",
        Effect   = "Allow",
        Action   = ["tag:GetResources"],
        Resource = "*"
      },
      # Permisos sobre S3 buckets origen para configurar inventario y notificaciones
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
          "s3:PutInventoryConfiguration"
        ],
        Resource = "arn:aws:s3:::*"
      },
      # Permisos para leer y actualizar policy de buckets origen (necesario para inventory)
      {
        Sid    = "AllowSourceBucketPolicyManagement",
        Effect = "Allow",
        Action = [
          "s3:GetBucketPolicy",
          "s3:PutBucketPolicy"
        ],
        Resource = "arn:aws:s3:::*"
      },
      # Permitir leer y actualizar la policy del bucket central
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
      # Permisos de lectura/escritura de inventarios al bucket central
      {
        Sid    = "AllowWriteInventoryToCentral",
        Effect = "Allow",
        Action = ["s3:PutObject", "s3:GetObject", "s3:ListBucket"],
        Resource = [
          "arn:aws:s3:::${var.central_backup_bucket_name}",
          "arn:aws:s3:::${var.central_backup_bucket_name}/*"
        ]
      },
      # Logs
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
      # Identidad de la cuenta
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
// Batch Job ROLE (usado por S3 Batch Operations)
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
    Statement = [
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
    ]
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
  visibility_timeout_seconds = 120
  receive_wait_time_seconds  = 10
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
      LOG_LEVEL             = "INFO"
      SQS_QUEUE_ARN         = aws_sqs_queue.s3_events_queue.arn
      CENTRAL_BACKUP_BUCKET = var.central_backup_bucket_name
      CENTRAL_ACCOUNT_ID    = var.central_account_id
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
  memory_size      = 256
  timeout          = 120

  environment {
    variables = {
      LOG_LEVEL              = "INFO"
      BACKUP_BUCKET          = var.central_backup_bucket_name
      BACKUP_BUCKET_ARN      = local.central_backup_bucket_arn
      INICIATIVA             = var.iniciativa
      ALLOWED_PREFIXES       = jsonencode(var.allowed_prefixes)
      CRITICALITY_TAG_KEY    = var.criticality_tag
      GENERATION_INCREMENTAL = "son"
      ACCOUNT_ID             = data.aws_caller_identity.current.account_id
      BATCH_ROLE_ARN         = aws_iam_role.batch_job_role.arn
    }
  }

  tags = {
    Initiative  = var.iniciativa
    Environment = var.environment
  }
}


resource "aws_lambda_event_source_mapping" "sqs_event" {
  event_source_arn                   = aws_sqs_queue.s3_events_queue.arn
  function_name                      = aws_lambda_function.incremental_backup.function_name
  batch_size                         = 10
  maximum_batching_window_in_seconds = 20
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
// EventBridge Scheduler para SWEEP programado según criticidad
// -----------------------------------------------------------------------------
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
        Sid      = "AllowPassRoleToSFN",
        Effect   = "Allow",
        Action   = ["iam:PassRole"],
        Resource = aws_iam_role.step_function.arn
      }
    ]
  })
}

resource "aws_scheduler_schedule" "incremental_schedules" {
  # Solo crear schedules incrementales cuando se haya definido 'incremental'
  for_each = { for k, v in var.schedule_expressions : k => v if try(v.incremental, null) != null && trimspace(v.incremental) != "" }

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
  # Solo crear schedules de grandfather cuando se haya definido
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




# ============================================================================
# Backup de Configuraciones AWS
# ============================================================================

# Lambda Role
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

# Lambda Policy
resource "aws_iam_role_policy" "backup_configurations" {
  name = "${local.prefijo_recursos}-iam-policy-backup-configs-${local.sufijo_recursos}"
  role = aws_iam_role.backup_configurations.name

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      # S3 - Write configurations
      {
        Sid    = "AllowS3WriteConfigurations",
        Effect = "Allow",
        Action = [
          "s3:PutObject",
          "s3:GetObject"
        ],
        Resource = "${local.central_backup_bucket_arn}/backup/criticality=Critico/backup_type=configurations/*"
      },
      # S3 - Read all bucket configurations
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
          "s3:GetBucketCors",
          "s3:GetReplicationConfiguration",
          "s3:ListBucket"
        ],
        Resource = "arn:aws:s3:::*"
      },
      # Glue - Read all
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
      # Athena - Read all
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
      # Lambda - Read all
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
      # IAM - Read roles and policies
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
      # Step Functions - Read
      {
        Sid    = "AllowStepFunctionsReadAll",
        Effect = "Allow",
        Action = [
          "states:ListStateMachines",
          "states:DescribeStateMachine"
        ],
        Resource = "*"
      },
      # EventBridge - Read
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
      # DynamoDB - Read (opcional)
      {
        Sid    = "AllowDynamoDBReadAll",
        Effect = "Allow",
        Action = [
          "dynamodb:ListTables",
          "dynamodb:DescribeTable"
        ],
        Resource = "*"
      },
      # RDS - Read (opcional)
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
      # Resource Groups Tagging API
      {
        Sid    = "AllowResourceTaggingAPI",
        Effect = "Allow",
        Action = [
          "tag:GetResources"
        ],
        Resource = "*"
      },
      # CloudWatch Logs
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

# Lambda Function
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
  timeout          = 900 # 15 minutos
  memory_size      = 512

  environment {
    variables = {
      LOG_LEVEL             = "INFO"
      BACKUP_BUCKET         = var.central_backup_bucket_name
      INICIATIVA            = var.iniciativa # AÑADIDO: Variable iniciativa
      TAG_FILTER_KEY        = "BackupEnabled"
      TAG_FILTER_VALUE      = "true"
      INCLUDE_GLUE          = "true"
      INCLUDE_ATHENA        = "true" # AÑADIDO: Incluir Athena
      INCLUDE_LAMBDA        = "true"
      INCLUDE_IAM           = "true"
      INCLUDE_STEPFUNCTIONS = "true"
      INCLUDE_EVENTBRIDGE   = "true"
      INCLUDE_DYNAMODB      = "false" # Cambiar a true si usas DynamoDB
      INCLUDE_RDS           = "false" # Cambiar a true si usas RDS
    }
  }

  tags = {
    Initiative  = var.iniciativa
    Environment = var.environment
  }
}

# EventBridge Rule - Semanal
resource "aws_cloudwatch_event_rule" "backup_configurations_weekly" {
  name                = "${local.prefijo_recursos}-backup-configs-weekly-${local.sufijo_recursos}"
  description         = "Trigger weekly backup of AWS configurations"
  schedule_expression = "cron(0 2 ? * SUN *)" # Domingos a las 2 AM UTC

  tags = {
    Initiative  = var.iniciativa
    Environment = var.environment
  }
}

resource "aws_cloudwatch_event_target" "backup_configurations_weekly" {
  rule      = aws_cloudwatch_event_rule.backup_configurations_weekly.name
  target_id = "BackupConfigurationsLambda"
  arn       = aws_lambda_function.backup_configurations.arn
}

resource "aws_lambda_permission" "allow_eventbridge_backup_configurations" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.backup_configurations.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.backup_configurations_weekly.arn
}

# Output
output "backup_configurations_lambda_arn" {
  description = "ARN de la Lambda de backup de configuraciones"
  value       = aws_lambda_function.backup_configurations.arn
}
