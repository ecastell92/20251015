output "state_machine_arn" {
  description = "ARN de la Step Function que orquesta el restore."
  value       = aws_sfn_state_machine.restore.arn
}

output "generate_manifest_lambda_arn" {
  description = "ARN de la Lambda que genera manifests."
  value       = aws_lambda_function.generate_manifest.arn
}

output "start_job_lambda_arn" {
  description = "ARN de la Lambda que crea los Jobs de S3 Batch."
  value       = aws_lambda_function.start_restore_job.arn
}

output "monitor_job_lambda_arn" {
  description = "ARN de la Lambda que monitorea el Job."
  value       = aws_lambda_function.monitor_restore_job.arn
}
