# Backup S3 – Diseño de Un Solo Bucket

Esta solución orquesta copias de seguridad de S3 con un único bucket central que almacena todo:

- Datos de respaldo: `backup/...`
- Manifiestos: `manifests/...`
- Reportes de S3 Batch: `reports/...`
- Checkpoints: `checkpoints/...`

La lógica (Lambdas + Step Functions + EventBridge Scheduler) vive en la misma cuenta que el bucket central.

## Componentes

- Bucket central (`central-resources`): cifrado AES256, bloqueo público, lifecycle por criticidad y tipo de backup (full/incremental).
- Lógica de iniciativa (`initiative-logic`):
  - `find_resources`: habilita S3 Inventory (Daily) y notificaciones SQS en buckets origen etiquetados `BackupEnabled=true`.
  - `filter_inventory`: genera manifiestos a partir de S3 Inventory; si no hay inventario aún, hace fallback con ListObjectsV2 (opcionalmente con límites); soporta “full en primera corrida”.
  - `launch_batch_job`: mueve el manifiesto a `manifests/` en el bucket central y crea el job de S3 Batch para copiar objetos a `backup/`.
  - `incremental_backup`: procesa eventos S3 (SQS) y arma incrementales por ventanas (12h críticos, 24h menos críticos por defecto).
  - Schedules (EventBridge Scheduler): dos agendas por criticidad: `incremental` y `sweep` (full).

## Variables clave (initiative-logic)

- `schedule_expressions` (mapa): `{ Critico = { incremental, sweep }, MenosCritico = {...}, ... }`.
- `force_full_on_first_run` (bool): primera corrida incremental se trata como full lógico.
- `fallback_max_objects` / `fallback_time_limit_seconds`: límites para el fallback cuando aún no hay inventario.
- `allowed_prefixes` (mapa): restringe prefijos incluidos por criticidad.
- `central_backup_bucket_name`: nombre del bucket central (también se usa para manifiestos y reportes).

## Notas de migración

- Se eliminó el bucket de manifiestos separado: todas las referencias a `backup_manifests_bucket_name` y `central_manifests_bucket_name_part` fueron retiradas.
- Policies actualizadas para operar únicamente sobre el bucket central.

## Operación

1) Desplegar `central-resources` y luego `initiative-logic`.
2) Etiquetar los buckets origen con `BackupEnabled=true` y `BackupCriticality` en `Critico|MenosCritico|NoCritico`.
3) Validar que se crean schedules incrementales y de sweep por criticidad.
4) Observar logs de Lambdas para la primera corrida: si no hay inventario aún, se usa fallback; después, Inventory toma el control.

## Estructura de rutas en el bucket central

- `backup/criticality=<Critico|MenosCritico|NoCritico>/backup_type=<incremental|full>/...`
- `manifests/criticality=.../backup_type=.../.../manifest.csv`
- `reports/criticality=.../backup_type=.../...`
- `checkpoints/<source-bucket>/<backup_type>.txt`

## Seguridad

- Deny sin TLS y sin SSE.
- Batch Operations y Lambdas con permisos mínimos sobre el bucket central.

## Lifecycle sugerido (ejemplo)

- Incrementales: retención corta (21–45 días), opcional GLACIER_IR.
- Full: transición a DEEP_ARCHIVE a los 90 días, retención larga (años) según criticidad.
