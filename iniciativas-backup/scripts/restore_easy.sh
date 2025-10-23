#!/usr/bin/env bash
set -euo pipefail

echo "== Restauración fácil de configuraciones (bash) =="

PROFILE="${AWS_PROFILE:-}"
REGION=""
BUCKET=""
INITIATIVE="mvp"
CRIT="Critico"

ask() { local q="$1" def="${2:-}" ans=""; read -r -p "$q${def:+ [$def]}: " ans || true; echo "${ans:-$def}"; }
yesno() { local q="$1" def="$2"; local d="y/N"; [ "$def" = "y" ] && d="Y/n"; read -r -p "$q ($d): " a || true; a="${a:-$def}"; [[ "$a" =~ ^([yY]|yes|s|S)$ ]]; }

# Try terraform outputs
if command -v terraform >/dev/null 2>&1; then
  if terraform output -json >/dev/null 2>&1; then
    BUCKET=$(terraform output -json | jq -r '.deployment_summary.value.central_resources.bucket_name // empty')
    REGION=$(terraform output -json | jq -r '.deployment_summary.value.region // empty')
  fi
fi

BUCKET=$(ask "Bucket central" "${BUCKET}")
REGION=$(ask "Región AWS" "${REGION:-eu-west-1}")
INITIATIVE=$(ask "Initiative" "$INITIATIVE")
CRIT=$(ask "Criticality (Critico|MenosCritico|NoCritico)" "$CRIT")

echo "Servicios:"
echo "  1) Todos (orden dependencias)"
echo "  2) Seleccionar (coma) – iam,s3,eventbridge,stepfunctions,glue,athena,lambda,dynamodb,rds"
mode=$(ask "Elige 1 o 2" "1")
ALL=""; SERVICES=""
if [ "$mode" = "1" ]; then ALL="--all"; else SERVICES=$(ask "Lista de servicios" "s3,eventbridge,stepfunctions"); fi

if yesno "Usar el último snapshot (latest)?" y; then LATEST="--latest"; TS=""; else LATEST=""; TS="--timestamp $(ask 'Timestamp a buscar' '')"; fi
APPLY=""; if yesno "Aplicar cambios (no dry-run)?" n; then APPLY="--yes"; fi

CMD=(python scripts/restore_configurations.py --bucket "$BUCKET" --initiative "$INITIATIVE" --criticality "$CRIT" --region "$REGION")
[ -n "$ALL" ] && CMD+=(--all) || CMD+=(--services "$SERVICES")
[ -n "$LATEST" ] && CMD+=(--latest) || CMD+=($TS)
[ -n "$APPLY" ] && CMD+=(--yes)
[ -n "${PROFILE:-}" ] && CMD+=(--profile "$PROFILE")

echo "\nEjecutando: ${CMD[*]}"
"${CMD[@]}"
echo "\nRestauración finalizada.";

