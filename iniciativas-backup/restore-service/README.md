## Restore Service (Standalone)

Terraform root para desplegar el servicio de restauración basado en Step Functions + Lambdas.  
Este proyecto es independiente del pipeline de backups principal; únicamente requiere un bucket S3 donde almacenar los manifests.

### Contenido desplegado

- Lambda `generate-manifest`: opcional, lista un bucket/prefijo y genera `manifest-<uuid>.csv`.
- Lambda `start-job`: crea el S3 Batch Operations Job que copia los objetos al destino.
- Lambda `monitor-job`: consulta periódicamente el estado del job.
- Step Function estándar que orquesta el flujo anterior.

### Requisitos

- Terraform ≥ 1.4
- AWS CLI configurado y permisos para Lambda, Step Functions, IAM, S3 y S3 Control.
- Rol service-linked de S3 Batch (`aws iam create-service-linked-role --aws-service-name batchoperations.s3.amazonaws.com`) si aún no existe.

### Uso

1. Copia `terraform.tfvars.example` a `terraform.tfvars` y ajusta:
   - `manifest_bucket_name`: bucket que almacenará los manifests (puede ser el mismo bucket central de backups).
   - `tenant`, `environment`, `iniciativa`, `sufijo_recursos`: para nombres consistentes.
2. Ejecuta:
   ```bash
   terraform init
   terraform plan
   terraform apply
   ```
3. Toma nota del ARN `state_machine_arn` en los outputs.

### Lanzar un restore

```bash
aws stepfunctions start-execution \
  --state-machine-arn <arn> \
  --name restore-$(date +%Y%m%d%H%M%S) \
  --input '{
    "mode": "prefix",
    "sourceBucket": "bucket-origen",
    "sourcePrefix": "datos/proyecto/",
    "targetBucket": "bucket-destino",
    "targetPrefix": "restore/datos/",
    "storageClass": "STANDARD"
  }'
```

- Usa `"mode": "manifest"` si ya existe un CSV y proporciona `manifestBucket` + `manifestKey`.
- Los reportes de S3 Batch se escribirán en `s3://<targetBucket>/<targetPrefix><report_suffix>`.

### Limpieza

```bash
terraform destroy
```

Esto eliminará la Step Function, Lambdas y roles IAM asociados (no borra los manifests ni los reportes ya generados en S3).
