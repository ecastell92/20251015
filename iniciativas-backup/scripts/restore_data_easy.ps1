param(
  [string]$Profile = "",
  [string]$Region  = ""
)

$ErrorActionPreference = "Stop"
function Ask($q, $def="") { if ($def) { $a = Read-Host "$q [$def]"; if (-not $a) { $def } else { $a } } else { Read-Host $q } }
function YesNo($q, $def=$true){ $d= if($def){'Y/n'}else{'y/N'}; $a=Read-Host "$q ($d)"; if(-not $a){return $def}; @('y','Y','yes','s','S') -contains $a }
function Run($cmd){ Write-Host "» $cmd" -ForegroundColor DarkGray; iex $cmd }

Write-Host "== Restauración de DATOS (incrementales/full) ==" -ForegroundColor Cyan
if ($Profile) { $env:AWS_PROFILE = $Profile }

# Intentar inferir región desde terraform output
try{ $tf=(terraform output -json)|ConvertFrom-Json; if(-not $Region -or $Region -eq ''){ $Region=$tf.deployment_summary.value.region }}catch{}
if (-not $Region) { $Region = Ask "Región AWS" "eu-west-1" }

# Detectar función Lambda automáticamente
Write-Host "Buscando función Lambda de restauración..." -ForegroundColor Yellow
$fn = ""
try {
  $list = aws lambda list-functions --region $Region --output json | ConvertFrom-Json
  foreach($f in $list.Functions){ if($f.FunctionName -like "*-restore-from-backup-*"){ $fn=$f.FunctionName; break } }
} catch {}
if (-not $fn) { $fn = Ask "Nombre de la función Lambda restore_from_backup" }
Write-Host "Función: $fn" -ForegroundColor Gray

$sourceBucket = Ask "Bucket ORIGEN a restaurar (destino)" ""
$criticality  = Ask "Criticality (Critico|MenosCritico|NoCritico)" "Critico"
$backupType   = Ask "Backup type (incremental|full)" "incremental"
$generation   = if($backupType -eq 'incremental'){ 'son' } else { Ask "Generación (father|grandfather)" "father" }

Write-Host "¿Usar último manifest disponible o elegir fecha/hora?" -ForegroundColor Yellow
$useLatest = YesNo "Usar último manifest" $true
$year=$month=$day=$hour=""
if (-not $useLatest){
  $year  = Ask "Año (YYYY)"  (Get-Date -UFormat %Y)
  $month = Ask "Mes (MM)"    (Get-Date -UFormat %m)
  $day   = Ask "Día (DD)"    (Get-Date -UFormat %d)
  $hour  = Ask "Hora (HH, 00-23)" (Get-Date -UFormat %H)
}

$prefix     = Ask "Prefijo a restaurar (opcional, ej. output/)" ""
$maxObjects = [int](Ask "Máximo de objetos" "10000")
$applyNow   = YesNo "¿Aplicar copia ahora? (No = solo previsualizar)" $false

# Construir payload
$payload = @{ 
  source_bucket = $sourceBucket
  criticality   = $criticality
  backup_type   = $backupType
  generation    = $generation
  prefix        = $prefix
  max_objects   = $maxObjects
  dry_run       = $true   # siempre hacemos previsualización primero
}
if (-not $useLatest){ $payload.year=$year; $payload.month=$month; $payload.day=$day; $payload.hour=$hour }
$json = ($payload | ConvertTo-Json -Depth 6 -Compress)

Write-Host "\nPayload:" -ForegroundColor Cyan
Write-Host $json -ForegroundColor DarkGray

Write-Host "\nPrevisualización (dry-run) en $fn ..." -ForegroundColor Yellow
$previewFile = Join-Path $PSScriptRoot "restore-data-preview.json"
Remove-Item -Path $previewFile -ErrorAction SilentlyContinue
aws lambda invoke --function-name $fn --payload $json --region $Region --cli-binary-format raw-in-base64-out "$previewFile" | Out-Null
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $previewFile)) { Write-Host "Error invocando la Lambda (preview). Revisa credenciales/permiso y nombre de función." -ForegroundColor Red; exit 2 }
$preview = Get-Content $previewFile | ConvertFrom-Json
Write-Host "Resultado (preview):" -ForegroundColor Cyan
($preview | ConvertTo-Json -Depth 6)
if ($preview.manifest_key) { Write-Host "Manifest: $($preview.manifest_key)" -ForegroundColor Gray }
if ($preview.data_prefix)  { Write-Host "Data prefix: $($preview.data_prefix)" -ForegroundColor Gray }

if (-not $applyNow) { Write-Host "\nListo (solo previsualización)." -ForegroundColor Green; exit 0 }

if (-not (YesNo "¿Ejecutar copia con dry_run=false ahora?" $true)) { Write-Host "Cancelado por el usuario."; exit 0 }

# Ejecutar restauración real
$payload.dry_run = $false
$json = ($payload | ConvertTo-Json -Depth 6 -Compress)
Write-Host "\nEjecutando restauración..." -ForegroundColor Yellow
$outFile = Join-Path $PSScriptRoot "restore-data-out.json"
Remove-Item -Path $outFile -ErrorAction SilentlyContinue
aws lambda invoke --function-name $fn --payload $json --region $Region --cli-binary-format raw-in-base64-out "$outFile" | Out-Null
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $outFile)) { Write-Host "Error invocando la Lambda (restauración)." -ForegroundColor Red; exit 2 }
Write-Host "Resultado:" -ForegroundColor Cyan
Get-Content $outFile
Write-Host "\nListo." -ForegroundColor Green


