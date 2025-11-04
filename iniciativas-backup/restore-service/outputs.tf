output "state_machine_arn" {
  description = "ARN de la Step Function que orquesta los restores."
  value       = module.restore_service.state_machine_arn
}

output "generate_manifest_lambda_arn" {
  description = "ARN de la Lambda que genera manifests."
  value       = module.restore_service.generate_manifest_lambda_arn
}

output "start_job_lambda_arn" {
  description = "ARN de la Lambda que crea los jobs de S3 Batch."
  value       = module.restore_service.start_job_lambda_arn
}

output "monitor_job_lambda_arn" {
  description = "ARN de la Lambda que monitorea el job."
  value       = module.restore_service.monitor_job_lambda_arn
}
