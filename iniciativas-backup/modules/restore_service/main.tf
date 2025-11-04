terraform {
  required_version = ">= 1.4.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

locals {
  name_prefix       = "${var.tenant}-${lower(var.environment)}"
  name_suffix       = "${lower(var.iniciativa)}-${var.sufijo_recursos}"
  lambda_base_name  = "${local.name_prefix}-restore-${local.name_suffix}"
  manifest_prefix   = var.manifest_prefix
  report_suffix     = var.report_suffix
  merged_tags       = merge(var.tags, { Initiative = var.iniciativa, Environment = var.environment })
}

# ---------------------------------------------------------------------------
# IAM Role compartido para las lambdas de restore
# ---------------------------------------------------------------------------

resource "aws_iam_role" "restore_lambda" {
  name = "${local.lambda_base_name}-iam-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Principal = {
          Service = "lambda.amazonaws.com"
        },
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy" "restore_lambda" {
  role = aws_iam_role.restore_lambda.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Sid    = "AllowS3ReadWriteManifests",
        Effect = "Allow",
        Action = [
          "s3:ListBucket",
          "s3:GetObject",
          "s3:PutObject",
          "s3:PutObjectAcl"
        ],
        Resource = [
          "arn:aws:s3:::*",
          "arn:aws:s3:::*/*"
        ]
      },
      {
        Sid    = "AllowS3Control",
        Effect = "Allow",
        Action = [
          "s3control:CreateJob",
          "s3control:DescribeJob",
          "s3control:ListJobs"
        ],
        Resource = "*"
      },
      {
        Sid    = "AllowStsGetCallerIdentity",
        Effect = "Allow",
        Action = ["sts:GetCallerIdentity"],
        Resource = "*"
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

data "aws_caller_identity" "current" {}

# ---------------------------------------------------------------------------
# Empaquetado de lambdas
# ---------------------------------------------------------------------------

data "archive_file" "generate_manifest" {
  type        = "zip"
  source_dir  = "${path.module}/lambdas/generate_manifest"
  output_path = "${path.module}/build/generate_manifest.zip"
}

data "archive_file" "start_restore_job" {
  type        = "zip"
  source_dir  = "${path.module}/lambdas/start_restore_job"
  output_path = "${path.module}/build/start_restore_job.zip"
}

data "archive_file" "monitor_restore_job" {
  type        = "zip"
  source_dir  = "${path.module}/lambdas/monitor_restore_job"
  output_path = "${path.module}/build/monitor_restore_job.zip"
}

# ---------------------------------------------------------------------------
# Lambda: Generate Manifest
# ---------------------------------------------------------------------------

resource "aws_lambda_function" "generate_manifest" {
  function_name    = "${local.lambda_base_name}-generate-manifest"
  role             = aws_iam_role.restore_lambda.arn
  filename         = data.archive_file.generate_manifest.output_path
  source_code_hash = data.archive_file.generate_manifest.output_base64sha256
  handler          = "lambda_function.lambda_handler"
  runtime          = "python3.11"
  timeout          = var.lambda_timeout
  memory_size      = var.lambda_memory

  environment {
    variables = {
      DEFAULT_MANIFEST_BUCKET = var.central_backup_bucket_name
      DEFAULT_MANIFEST_PREFIX = local.manifest_prefix
    }
  }

  tags = local.merged_tags
}

resource "aws_cloudwatch_log_group" "generate_manifest" {
  name              = "/aws/lambda/${aws_lambda_function.generate_manifest.function_name}"
  retention_in_days = 14
  tags              = local.merged_tags
}

# ---------------------------------------------------------------------------
# Lambda: Start Restore Job
# ---------------------------------------------------------------------------

resource "aws_lambda_function" "start_restore_job" {
  function_name    = "${local.lambda_base_name}-start-job"
  role             = aws_iam_role.restore_lambda.arn
  filename         = data.archive_file.start_restore_job.output_path
  source_code_hash = data.archive_file.start_restore_job.output_base64sha256
  handler          = "lambda_function.lambda_handler"
  runtime          = "python3.11"
  timeout          = var.lambda_timeout
  memory_size      = var.lambda_memory

  environment {
    variables = {
      BATCH_ROLE_NAME       = var.batch_operations_role_name
      DEFAULT_REPORT_SUFFIX = local.report_suffix
    }
  }

  tags = local.merged_tags
}

resource "aws_cloudwatch_log_group" "start_restore_job" {
  name              = "/aws/lambda/${aws_lambda_function.start_restore_job.function_name}"
  retention_in_days = 14
  tags              = local.merged_tags
}

# ---------------------------------------------------------------------------
# Lambda: Monitor Restore Job
# ---------------------------------------------------------------------------

resource "aws_lambda_function" "monitor_restore_job" {
  function_name    = "${local.lambda_base_name}-monitor-job"
  role             = aws_iam_role.restore_lambda.arn
  filename         = data.archive_file.monitor_restore_job.output_path
  source_code_hash = data.archive_file.monitor_restore_job.output_base64sha256
  handler          = "lambda_function.lambda_handler"
  runtime          = "python3.11"
  timeout          = 60
  memory_size      = 256

  tags = local.merged_tags
}

resource "aws_cloudwatch_log_group" "monitor_restore_job" {
  name              = "/aws/lambda/${aws_lambda_function.monitor_restore_job.function_name}"
  retention_in_days = 14
  tags              = local.merged_tags
}

# ---------------------------------------------------------------------------
# IAM Role para Step Functions
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "step_functions_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    effect  = "Allow"

    principals {
      type        = "Service"
      identifiers = ["states.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "step_functions" {
  name               = "${local.lambda_base_name}-sfn-role"
  assume_role_policy = data.aws_iam_policy_document.step_functions_assume.json
}

resource "aws_iam_role_policy" "step_functions" {
  role = aws_iam_role.step_functions.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = ["lambda:InvokeFunction"],
        Resource = [
          aws_lambda_function.generate_manifest.arn,
          aws_lambda_function.start_restore_job.arn,
          aws_lambda_function.monitor_restore_job.arn
        ]
      },
      {
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

# ---------------------------------------------------------------------------
# Step Function
# ---------------------------------------------------------------------------

resource "aws_sfn_state_machine" "restore" {
  name     = "${local.lambda_base_name}-state-machine"
  role_arn = aws_iam_role.step_functions.arn
  type     = "STANDARD"

  definition = templatefile("${path.module}/state_machine.asl.json.tmpl", {
    generate_manifest_arn = aws_lambda_function.generate_manifest.arn
    start_job_arn         = aws_lambda_function.start_restore_job.arn
    monitor_job_arn       = aws_lambda_function.monitor_restore_job.arn
  })

  tags = local.merged_tags
}
