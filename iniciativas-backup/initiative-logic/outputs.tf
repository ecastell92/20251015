// ============================================================================
// Initiative Logic Outputs
// ============================================================================

output "state_machine_arn" {
  description = "ARN de la Step Function orquestadora de backups"
  value       = aws_sfn_state_machine.backup_orchestrator.arn
}

output "state_machine_name" {
  description = "Nombre de la Step Function"
  value       = aws_sfn_state_machine.backup_orchestrator.name
}

output "find_resources_lambda_arn" {
  description = "ARN de la Lambda find_resources"
  value       = aws_lambda_function.find_resources.arn
}

output "filter_inventory_lambda_arn" {
  description = "ARN de la Lambda filter_inventory"
  value       = aws_lambda_function.filter_inventory.arn
}

output "launch_batch_job_lambda_arn" {
  description = "ARN de la Lambda launch_batch_job"
  value       = aws_lambda_function.launch_batch_job.arn
}

output "incremental_backup_lambda_arn" {
  description = "ARN de la Lambda incremental_backup"
  value       = aws_lambda_function.incremental_backup.arn
}

# output "backup_configurations_lambda_arn" {
#   description = "ARN de la Lambda backup_configurations"
#   value       = aws_lambda_function.backup_configurations.arn
# }

output "sqs_queue_arn" {
  description = "ARN de la cola SQS para eventos S3"
  value       = aws_sqs_queue.s3_events_queue.arn
}

output "sqs_queue_url" {
  description = "URL de la cola SQS para eventos S3"
  value       = aws_sqs_queue.s3_events_queue.url
}

output "sqs_queue_name" {
  description = "Nombre de la cola SQS"
  value       = aws_sqs_queue.s3_events_queue.name
}

output "scheduler_group_name" {
  description = "Nombre del grupo de schedules de EventBridge"
  value       = aws_scheduler_schedule_group.backup_schedules.name
}

output "batch_job_role_arn" {
  description = "ARN del rol IAM para S3 Batch Operations"
  value       = aws_iam_role.batch_job_role.arn
}

output "step_function_role_arn" {
  description = "ARN del rol IAM de la Step Function"
  value       = aws_iam_role.step_function.arn
}

output "schedules_created" {
  description = "Lista de schedules creados"
  value = {
    incremental = [for k, v in aws_scheduler_schedule.incremental_schedules : v.name]
    sweep       = [for k, v in aws_scheduler_schedule.sweep_schedules : v.name]
    grandfather = [for k, v in aws_scheduler_schedule.grandfather_schedules : v.name]
  }
}

output "lambda_functions" {
  description = "Mapa de todas las funciones Lambda desplegadas"
  value = {
    find_resources        = aws_lambda_function.find_resources.function_name
    filter_inventory      = aws_lambda_function.filter_inventory.function_name
    launch_batch_job      = aws_lambda_function.launch_batch_job.function_name
    incremental_backup    = aws_lambda_function.incremental_backup.function_name
    backup_configurations = aws_lambda_function.backup_configurations.function_name
    restore_from_backup   = aws_lambda_function.restore_from_backup.function_name
  }
}

# Visibilidad del ruteo de incrementales según frecuencias configuradas
output "event_driven_criticalities" {
  description = "Criticidades que van por event-driven (0 < h <= 24)"
  value       = local.notif_criticalities
}

output "manifest_diff_criticalities" {
  description = "Criticidades que van por manifest-diff (h > 24)"
  value       = [for k, h in local.backup_frequencies : k if h > 24]
}

output "no_incremental_criticalities" {
  description = "Criticidades sin incremental (h == 0)"
  value       = [for k, h in local.backup_frequencies : k if h == 0]
}

output "monitoring_commands" {
  description = "Comandos útiles para monitoreo"
  value       = <<-EOT
  
  # Ver logs de find_resources
  aws logs tail /aws/lambda/${aws_lambda_function.find_resources.function_name} --follow
  
  # Ver logs de incremental_backup
  aws logs tail /aws/lambda/${aws_lambda_function.incremental_backup.function_name} --follow
  
  # Ver mensajes en SQS
  aws sqs receive-message --queue-url ${aws_sqs_queue.s3_events_queue.url}
  
  # Ver schedules
  aws scheduler list-schedules --group-name ${aws_scheduler_schedule_group.backup_schedules.name}
  
  # Ejecutar Step Function manualmente
  aws stepfunctions start-execution \
    --state-machine-arn ${aws_sfn_state_machine.backup_orchestrator.arn} \
    --input '{"BackupType":"incremental","Criticality":"Critico","Generation":"son"}'
  
  EOT
}

output "dlq_url" {
  description = "URL de la Dead Letter Queue"
  value       = aws_sqs_queue.s3_events_dlq.url
}

output "sns_topic_arn" {
  description = "ARN del SNS Topic para alertas"
  value       = aws_sns_topic.backup_alerts.arn
}

output "dashboard_name" {
  description = "Nombre del CloudWatch Dashboard de Backup Ops"
  value       = try(aws_cloudwatch_dashboard.backup_ops[0].dashboard_name, null)
}

output "cost_optimization_applied" {
  description = "Resumen de optimizaciones aplicadas"
  value = {
    sqs_batch_size            = "1000 (antes: 10) → Reducción 99% invocaciones"
    sqs_batching_window       = "300s (antes: 20s)"
    log_retention             = "7/14 días (antes: indefinido)"
    dlq_enabled               = "true (antes: false)"
    estimated_monthly_savings = "$9,600+ (para 20 buckets con 10M objetos)"
  }
}
