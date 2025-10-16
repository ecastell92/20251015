aws_region                      = "eu-west-1"
central_backup_bucket_name_part = "s3-bucket-central"
central_backup_vault_name       = "00-dev-s3-aws-vault-bck-001-aws"
sufijo_recursos                 = "bck-001-aws"

environment = "dev"
tenant      = "00"

lifecycle_rules = {
  Critico = {
    glacier_transition_days             = 0
    deep_archive_transition_days        = 90
    expiration_days                     = 1825
    incremental_expiration_days         = 45
    incremental_glacier_transition_days = 0
    use_glacier_ir                      = true
  }
  MenosCritico = {
    glacier_transition_days             = 0
    deep_archive_transition_days        = 90
    expiration_days                     = 1095
    incremental_expiration_days         = 30
    incremental_glacier_transition_days = 0
    use_glacier_ir                      = true
  }
  NoCritico = {
    glacier_transition_days             = 0
    deep_archive_transition_days        = 0 # no aplica
    expiration_days                     = 90
    incremental_expiration_days         = 21
    incremental_glacier_transition_days = 0
    use_glacier_ir                      = false
  }
}


