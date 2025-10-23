output "cluster_id" {
  value       = aws_rds_cluster.this.id
  description = "Aurora cluster identifier"
}

output "cluster_arn" {
  value       = aws_rds_cluster.this.arn
  description = "Aurora cluster ARN"
}

output "writer_endpoint" {
  value       = aws_rds_cluster.this.endpoint
  description = "Writer endpoint"
}

output "reader_endpoint" {
  value       = aws_rds_cluster.this.reader_endpoint
  description = "Reader endpoint"
}

output "master_username" {
  value       = aws_rds_cluster.this.master_username
  description = "Master user name"
}

output "generated_master_password" {
  value       = var.master_password != null ? null : random_password.master.result
  description = "Generated password (null if provided)"
  sensitive   = true
}

