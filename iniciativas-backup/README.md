Backups S3 – Un Solo Bucket
=================================

Este repositorio contiene una solución completa para orquestar copias de seguridad de S3 con un único bucket central, usando Lambda, SQS, Step Functions y S3 Batch Operations. Incluye incrementales event‑driven, full programados (sweep) y respaldo de configuraciones AWS.

Índice rápido
- Cuaderno de configuración principal: `terraform.tfvars`
- Ejemplo completo de configuración: `terraform.tfvars.example`
- Guía de configuración y operación: `docs/CONFIGURACION_Y_OPERACION.md`
- Demo end‑to‑end (presentación): `docs/DEMO.md`
- Scripts útiles:
  - `scripts/demo.ps1` – demo automática
  - `scripts/s3_batch_report_summary.py` – resume reportes S3 Batch
  - `scripts/restore_configurations.py` – restaura snapshots de configuraciones (soporta `--all`)
  - `scripts/cleanup_s3_backup_configs.py` – limpia Inventory/Notifs en destroy

Inicio rápido
1) Ajusta `terraform.tfvars` (o copia desde `terraform.tfvars.example`).
2) `terraform init && terraform apply`
3) Demo (opcional): `pwsh -File scripts/demo.ps1 -Profile <perfil> -Region <region>`

Para detalles de rutas, retención, validación, restauración y limpieza, consulta `docs/CONFIGURACION_Y_OPERACION.md`.
