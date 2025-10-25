#!/usr/bin/env bash
set -euo pipefail

echo "== Restauración de DATOS (incrementales/full) =="

PROFILE="${AWS_PROFILE:-}"
REGION="${AWS_REGION:-}"

ask(){ local q="$1"; local def="${2:-}"; local a=""; read -r -p "$q${def:+ [$def]}: " a || true; echo "${a:-$def}"; }
yesno(){ local q="$1"; local def="$2"; local d="y/N"; [ "$def" = "y" ] && d="Y/n"; local a=""; read -r -p "$q ($d): " a || true; a="${a:-$def}"; [[ "$a" =~ ^([yY]|yes|s|S)$ ]]; }

# Try infer region
if [ -z "$REGION" ] && command -v terraform >/dev/null 2>&1; then
  if terraform output -json >/dev/null 2>&1; then
    REGION=$(terraform output -json | jq -r '.deployment_summary.value.region // empty')
  fi
fi
[ -z "$REGION" ] && REGION=$(ask "Región AWS" "eu-west-1")

# Detect lambda function name
echo "Buscando función Lambda restore_from_backup..."
PROFILE_ARG=""; [ -n "${PROFILE:-}" ] && PROFILE_ARG=(--profile "$PROFILE")
FN=$(aws lambda list-functions --region "$REGION" ${PROFILE_ARG[@]:-} --query "Functions[?contains(FunctionName,'restore-from-backup')].FunctionName | [0]" --output text 2>/dev/null || true)
if [ "$FN" = "None" ] || [ -z "$FN" ]; then
  FN=$(ask "Nombre de la función Lambda" "")
fi
echo "Función: $FN"

SRC=$(ask "Bucket ORIGEN a restaurar (destino)" "")
CRIT=$(ask "Criticality (Critico|MenosCritico|NoCritico)" "Critico")
BT=$(ask "Backup type (incremental|full)" "incremental")
GEN="son"; [ "$BT" = "incremental" ] || GEN=$(ask "Generación (father|grandfather)" "father")

if yesno "Usar último manifest disponible?" y; then
  USE_LATEST=1
else
  USE_LATEST=0
  Y=$(ask "Año (YYYY)" "$(date +%Y)")
  M=$(ask "Mes (MM)" "$(date +%m)")
  D=$(ask "Día (DD)" "$(date +%d)")
  H=$(ask "Hora (HH)" "$(date +%H)")
fi

PFX=$(ask "Prefijo (opcional, ej. output/)" "")
MAX=$(ask "Máximo de objetos" "10000")
APPLY=0; yesno "¿Aplicar copia ahora? (No = solo previsualizar)" n && APPLY=1

PAYLOAD=$(jq -n \
  --arg src "$SRC" --arg crit "$CRIT" --arg bt "$BT" --arg gen "$GEN" \
  --arg pfx "$PFX" --argjson max "$MAX" --argjson dry "$([ "$APPLY" -eq 1 ] && echo false || echo true)" \
  '{source_bucket:$src,criticality:$crit,backup_type:$bt,generation:$gen,prefix:$pfx,max_objects:$max,dry_run:$dry}')
if [ "$USE_LATEST" -eq 0 ]; then
  PAYLOAD=$(echo "$PAYLOAD" | jq --arg y "$Y" --arg m "$M" --arg d "$D" --arg h "$H" '.+{year:$y,month:$m,day:$d,hour:$h}')
fi

echo -e "\nPayload (previsualización):\n$PAYLOAD"
TMP=$(mktemp)
echo "$PAYLOAD" > "$TMP"
PREVIEW=restore-data-preview.json
aws lambda invoke --function-name "$FN" --payload "$PAYLOAD" --region "$REGION" ${PROFILE_ARG[@]:-} --cli-binary-format raw-in-base64-out "$PREVIEW" >/dev/null
if [ ! -f "$PREVIEW" ]; then echo "Error invocando Lambda (preview)."; exit 2; fi
echo -e "\nResultado (preview):\n"
cat restore-data-preview.json

if [ "$APPLY" -ne 1 ]; then echo -e "\nListo (solo previsualización)."; exit 0; fi

if yesno "¿Ejecutar copia con dry_run=false ahora?" y; then
  PAYLOAD=$(echo "$PAYLOAD" | jq '.dry_run=false')
  echo "$PAYLOAD" > "$TMP"
  echo -e "\nEjecutando restauración..."
  OUT=restore-data-out.json
  aws lambda invoke --function-name "$FN" --payload "$PAYLOAD" --region "$REGION" ${PROFILE_ARG[@]:-} --cli-binary-format raw-in-base64-out "$OUT" >/dev/null
  if [ ! -f "$OUT" ]; then echo "Error invocando Lambda (restauración)."; exit 2; fi
  echo -e "\nResultado:\n"
  cat restore-data-out.json
  echo -e "\nListo."
else
  echo "Cancelado por el usuario."; exit 0
fi
