# Migración de configuraciones (layout antiguo -> nuevo)

Este documento explica cómo mover los snapshots de configuraciones del layout antiguo al nuevo.

Antiguo:

- `backup/criticality=<Critico|MenosCritico|NoCritico>/backup_type=configurations/initiative=<ini>/service=<svc>/...`

Nuevo (nivel hermano de las criticidades):

- `backup/configurations/initiative=<ini>/service=<svc>/year=YYYY/month=MM/day=DD/hour=HH/...json`

## Requisitos de permisos (perfil/operator)

- `s3:ListBucket` sobre el bucket central
- `s3:GetObject` y `s3:PutObject` en `backup/criticality=*/backup_type=configurations/*` y `backup/configurations/*`
- `s3:DeleteObject` si se usará `--delete-source`

## Ensayo (dry‑run)

```
python scripts/migrate_configurations_layout.py \
  --bucket <central-bucket> --region <region> --profile <perfil>
```

## Migrar por partes (ejemplos)

- Solo initiative=mvp y servicios s3,iam:

```
python scripts/migrate_configurations_layout.py \
  --bucket <central-bucket> --initiative mvp --services s3,iam \
  --yes --region <region> --profile <perfil>
```

- Procesar solo ciertas criticalidades (p. ej. Critico y MenosCritico):

```
python scripts/migrate_configurations_layout.py \
  --bucket <central-bucket> --criticalities Critico,MenosCritico \
  --yes --region <region> --profile <perfil>
```

## Limpiar claves antiguas (opcional)

```
python scripts/migrate_configurations_layout.py \
  --bucket <central-bucket> --yes --delete-source \
  --region <region> --profile <perfil>
```

## Notas

- El script verifica el tamaño tras la copia. Use `--on-exists overwrite` si desea sobreescribir claves ya migradas.
- Puede ajustar la concurrencia con `--concurrency` (default 8).
- Para servicios, los nombres válidos corresponden al folder almacenado (p. ej., `s3_buckets`, `lambda_functions`, `iam_roles`, etc.). Para atajos, puede consultar los archivos existentes con `aws s3 ls --recursive`.

