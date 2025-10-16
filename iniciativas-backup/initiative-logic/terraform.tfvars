aws_region         = "eu-west-1"    # Región de AWS donde se ejecuta tu iniciativa
iniciativa         = "mvp"          # Identificador corto para esta iniciativa
environment        = "dev"          # Entorno de despliegue (dev, test, prod, etc.)    
tenant             = "00"           # Nombre corto de la unidad de negocio o tenant
central_account_id = "905418243844" # ID de la cuenta central de backup

central_backup_bucket_name = "00-dev-s3-bucket-central-bck-001-aws-notinet"

criticality_tag = "BackupCriticality"

allowed_prefixes = {
  Critico      = []
  MenosCritico = []
  NoCritico    = []
}

backup_tags = {
  ManagedBy   = "Terraform"
  Project     = "DataPlatformBackup"
  Environment = "dev"
  Initiative  = "my-initiative-2"
}

sufijo_recursos = "bck-001-aws-notinet" # Sufijo para asegurar nombres únicos en recursos globales

force_full_on_first_run     = false # Incrementales siempre como incremental
fallback_max_objects        = null # p.ej., 200000 para limitar objetos listados
fallback_time_limit_seconds = null # p.ej., 600 (10 minutos) para cortar por tiempo


schedule_expressions = {
  Critico = {
    incremental = "rate(12 hours)"
    sweep       = "rate(7 days)"
    grandfather = "cron(0 3 1 * ? *)" # mensual
  }
  MenosCritico = {
    incremental = "rate(24 hours)"
    sweep       = "rate(14 days)"
    grandfather = "cron(0 3 1 */3 ? *)" # trimestral
  }
  NoCritico = {
    sweep       = "rate(15 days)"
    grandfather = "cron(0 4 1 */6 ? *)" # semestral
  }
}
