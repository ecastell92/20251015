# Guía de Configuración y Operación – Backups S3 (Un Solo Bucket)

Este documento resume, en un lugar, todo lo necesario para desplegar, operar, restaurar y limpiar la solución. Es la referencia para cualquier persona que llegue al proyecto.

## 1. Requisitos

- Terraform >= 1.4, Provider AWS ~> 5.x
- AWS CLI y credenciales válidas (o SSO con `aws sso login`)
- Permisos para crear S3, IAM, Lambda, SQS, Step Functions y EventBridge

## 2. Nomenclatura de rutas en el bucket central

- Datos incrementales:
  `backup/criticality=<Critico|MenosCritico|NoCritico>/backup_type=incremental/generation=son/initiative=<ini>/bucket=<origen>/year=YYYY/month=MM/day=DD/hour=HH/window=<YYYYMMDDTHHMMZ>/...`
- Manifiestos incrementales: `manifests/criticality=.../backup_type=incremental/.../window=.../manifest-<ts>.csv`
- Reportes S3 Batch: `reports/criticality=.../backup_type=incremental/.../window=.../run=<ts>/...`
- Checkpoints: `checkpoints/<bucket-origen>/<backup_type>.txt`
- Configuraciones: `backup/configurations/initiative=<ini>/service=<svc>/year=YYYY/month=MM/day=DD/hour=HH/...json`

## 3. Variables – terraform.tfvars (raíz)

Usa el archivo `terraform.tfvars` (o crea uno nuevo desde `terraform.tfvars.example`) para definir TODA la configuración.

### 3.1 Básicas

- `aws_region` (string) – región AWS. Ej: `"eu-west-1"`
- `environment` (string) – `dev|staging|prod`
- `tenant` (string) – identificador corto del tenant. Ej: `"00"`
- `iniciativa` (string) – nombre corto de la iniciativa. Ej: `"mvp"`
- `cuenta` (string) – Account ID de despliegue
- `central_account_id` (string) – Account ID donde vive el bucket central (opcional, por defecto la actual)
- `central_backup_vault_name` (string) – nombre del AWS Backup Vault (si se usa)
- `sufijo_recursos` (string) – sufijo para unicidad en nombres

### 3.2 Schedules por criticidad

`schedule_expressions` (mapa): para cada criticidad define
- `incremental` (string, opcional). Ej: `"rate(12 hours)"` (≤24h usa event‑driven)
- `sweep` (string, requerido). Ej: `"rate(7 days)"`
- `grandfather` (string, opcional). Ej: `"cron(0 3 1 * ? *)"`

### 3.3 GFS – Retención de datos

`gfs_rules` por criticidad:
- `enable` (bool)
- `start_storage_class` (`STANDARD|GLACIER_IR|GLACIER`)
- `son_retention_days`, `father_retention_days`, `grandfather_retention_days`
- Transiciones a DEEP_ARCHIVE: `father_da_days`, `grandfather_da_days`

### 3.4 Incrementales – Controles y filtros

- `criticality_tag` (string) – tag en buckets origen. Default: `BackupCriticality`
- `allowed_prefixes` (mapa de listas) – prefijos incluidos por criticidad. Lista vacía = todos
- `exclude_key_prefixes` (list) – prefijos a excluir (recomendado: `temporary/`, `sparkHistoryLogs/`)
- `exclude_key_suffixes` (list) – sufijos a excluir (recomendado: `.inprogress`, `/`)
- `force_full_on_first_run` (bool) – para manifest‑diff inicial
- `fallback_max_objects`, `fallback_time_limit_seconds` – límites del fallback (0 = sin límite)
- `disable_window_checkpoint` (bool) – true para NO saltar objetos tardíos de una ventana
- `incremental_log_level` (string) – `INFO|DEBUG|...`
- KMS en origen:
  - `kms_allow_viaservice` (bool) – concede `kms:Decrypt` vía `kms:ViaService` a S3 en la región
  - `source_kms_key_arns` (list) – CMKs explícitas (opcional)

### 3.5 Limpieza operacional (Lifecycle)

- `cleanup_inventory_source_days` – inventarios de origen
- `cleanup_batch_reports_days` – reportes de Batch
- `cleanup_checkpoints_days` – checkpoints
- `cleanup_manifests_temp_days` – manifiestos temporales
- `cleanup_configurations_days` – JSON de configuraciones (por defecto 90 días)

### 3.6 Backup de configuraciones – toggles

- `backup_config_*` (log level, tag filter y toggles por servicio: Glue, Athena, Lambda, IAM, StepFunctions, EventBridge, DynamoDB, RDS)

## 4. Despliegue

1) `terraform init`
2) `terraform plan`
3) `terraform apply`

Tras el deploy, `find_resources` corre una vez (one‑shot) y configura S3 Inventory (Weekly) y S3→SQS en buckets con `BackupEnabled=true`.

## 5. Validación rápida

- Schedules: `aws scheduler list-schedules --group-name <tenant>-<env>-schedules-<sufijo>`
- Notificaciones S3→SQS por bucket origen:
  `aws s3api get-bucket-notification-configuration --bucket <bucket-origen>`
- SQS: `aws sqs get-queue-attributes --queue-url <url> --attribute-names ApproximateNumberOfMessages*`
- Lambda incremental (logs): `aws logs tail /aws/lambda/<fn-incremental> --follow`
- Jobs S3 Batch: `aws s3control list-jobs --account-id <acct>`
- Reporte último job: `python scripts/s3_batch_report_summary.py --bucket <central-bucket> --region <region>`

## 6. Restauración de configuraciones

Usa `scripts/restore_configurations.py`.

- Restaurar todo (dependencias):
```
python scripts/restore_configurations.py \
  --bucket <central-bucket> --initiative <ini> --criticality Critico \
  --all --latest --region <region> --profile <perfil> --yes
```
- Dry‑run: omite `--yes`.
- Servicios soportados: `iam,s3,eventbridge,stepfunctions,glue,athena,lambda,dynamodb,rds`.

### 6.1 Restauración fácil (sin código)

Para hacerlo aún más simple, hay dos “wrappers” interactivos que preguntan y ejecutan la restauración por ti:

- PowerShell (Windows):
  - `pwsh -File scripts/restore_easy.ps1`
  - Detecta `bucket` y `región` desde `terraform output` cuando es posible.
  - Permite elegir `criticality`, `services` o `--all`, y si usar `--latest` o un `--timestamp`.
  - Confirmación final y ejecución con/ sin `--yes`.

- Bash (Linux/macOS):
  - `bash scripts/restore_easy.sh`
  - Mismo flujo básico con preguntas y valores por defecto.

### 6.2 Restauración de DATOS (objetos S3)

Los scripts anteriores restauran CONFIGURACIONES. Para restaurar DATOS, usa los wrappers de la Lambda `restore_from_backup`:

- PowerShell:
  - `pwsh -File scripts/restore_data_easy.ps1`
  - Pregunta bucket origen (destino de la restauración), criticidad, tipo (incremental/full), generación, último manifest o fecha/hora, prefijo, y si aplicar (o dry‑run).

- Bash:
  - `bash scripts/restore_data_easy.sh`
  - Mismo flujo interactivo. Construye el payload y ejecuta `aws lambda invoke`.

Notas:
- Si eliges “último manifest”, la función busca automáticamente el más reciente para la combinación indicada.
- Usa “prefijo” para acotar (ej. `output/`).
- Los wrappers realizan SIEMPRE una previsualización (dry‑run) primero y muestran `manifest_key` y `data_prefix`; si confirmas, ejecutan la copia real con `dry_run=false`.

## 7. Limpieza y destroy

Al ejecutar `terraform destroy`, se invoca `scripts/cleanup_s3_backup_configs.py` para eliminar Inventory y notificaciones S3→SQS de los buckets `BackupEnabled=true`.

Manual:
```
python scripts/cleanup_s3_backup_configs.py --profile <perfil> --region <region> --yes
```

## 8. Troubleshooting (rápido)

- “Grupos encontrados: 0” en incremental: sin eventos S3 válidos; revisa S3→SQS, filtros y prefijos.
- “Etag mismatch reading manifest”: corregido usando ETag del PutObject; re‑aplica cambios.
- “AccessDenied” en reportes: SSE‑KMS en origen; define `source_kms_key_arns` o usa `kms_allow_viaservice=true` y revisa key policies si son cross‑account.
- Objetos faltantes: evita efímeros (.inprogress) y marcadores de carpeta (`/`); limita con `allowed_prefixes` a prefijos estables (p. ej. `output/`).

## 9. Scripts útiles

- `scripts/s3_batch_report_summary.py` – resume el último CSV de reportes de S3 Batch.
- `scripts/restore_configurations.py` – restauración por servicio o `--all` (dry‑run por defecto).
- `scripts/cleanup_s3_backup_configs.py` – limpia Inventory y notificaciones S3→SQS.
