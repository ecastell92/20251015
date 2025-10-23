# Demo – Prueba End‑to‑End (Incrementales + Reportes)

Esta demo despliega la solución, crea un bucket de origen de prueba, sube archivos, fuerza la configuración S3→SQS y verifica que los incrementales copian al bucket central y que hay reporte de S3 Batch.

## Requisitos
- Terraform y AWS CLI configurados
- Python (para scripts de apoyo)

## Ejecución automática (PowerShell)

```
pwsh -File scripts/demo.ps1 -Profile <aws-profile> -Region <region>
```

Parámetros:
- `-Profile`: perfil AWS (opcional; usa el por defecto si se omite)
- `-Region`: región AWS (si se omite, la toma de Terraform outputs)
- `-Criticality`: `Critico|MenosCritico|NoCritico` (default `Critico`)
- `-Prefix`: prefijo lógico para el bucket demo (default `demo`)

El script:
1) `terraform init && terraform apply`
2) Obtiene bucket central y ARNs de Lambdas desde `terraform output -json`
3) Crea un bucket S3 de origen con tags `BackupEnabled=true` y `BackupCriticality=<Criticality>`
4) Invoca la Lambda `find_resources` para configurar S3 Inventory y notificaciones S3→SQS
5) Sube archivos de prueba al bucket origen
6) Espera a que se cree un S3 Batch Job, lo monitorea hasta terminar
7) Lista los objetos copiados en el bucket central y resume el reporte con `scripts/s3_batch_report_summary.py`

## Verificación manual (alternativa)
- Subir archivos a un bucket con tags `BackupEnabled=true` y `BackupCriticality`
- Ver logs de la Lambda incremental
- Revisar objetos bajo `backup/criticality=.../backup_type=incremental/...`
- Resumir reporte: `python scripts/s3_batch_report_summary.py --bucket <central-bucket> --region <region>`

```
Nota: los objetos de datos copiados están en `backup/...`; los CSV que veas en `manifests/` y `reports/` son artefactos de operación (no son los datos).
```
