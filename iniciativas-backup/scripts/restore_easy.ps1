param(
  [string]$Profile = "",
  [string]$Region = "",
  [string]$Bucket = "",
  [string]$Initiative = "",
  [ValidateSet("Critico","MenosCritico","NoCritico")]
  [string]$Criticality = "Critico"
)

$ErrorActionPreference = "Stop"
function Ask($q, $def="") {
  if ($def) { $ans = Read-Host "$q [$def]"; if (-not $ans) { return $def } return $ans }
  else { return Read-Host $q }
}
function YesNo($q, $def=$true) {
  $d = if ($def) {"Y/n"} else {"y/N"}
  $ans = Read-Host "$q ($d)"; if (-not $ans) { return $def }
  return @('y','Y','yes','s','S') -contains $ans
}

Write-Host "== Restauración fácil de configuraciones ==" -ForegroundColor Cyan
if ($Profile) { $env:AWS_PROFILE = $Profile }

# Try to infer from terraform output
try {
  $tf = (terraform output -json) | ConvertFrom-Json
  if (-not $Bucket -or $Bucket -eq '') { $Bucket = $tf.deployment_summary.value.central_resources.bucket_name }
  if (-not $Region -or $Region -eq '') { $Region = $tf.deployment_summary.value.region }
} catch {}

if (-not $Bucket) { $Bucket = Ask "Bucket central" }
if (-not $Region) { $Region = Ask "Región AWS" "eu-west-1" }
if (-not $Initiative) { $Initiative = Ask "Initiative (ruta en backup_type=configurations)" "mvp" }
$Criticality = Ask "Criticality (Critico|MenosCritico|NoCritico)" $Criticality

Write-Host "Servicios a restaurar:" -ForegroundColor Yellow
Write-Host "  1) Todos (orden dependencias)" -ForegroundColor Gray
Write-Host "  2) Seleccionar (coma) – opciones: iam,s3,eventbridge,stepfunctions,glue,athena,lambda,dynamodb,rds" -ForegroundColor Gray
$mode = Ask "Elige 1 o 2" "1"
$all = $false; $services = @()
if ($mode -eq '1') { $all = $true }
else { $services = (Ask "Lista de servicios (coma)" "s3,eventbridge,stepfunctions").Split(',') | ForEach-Object { $_.Trim() } }

$latest = YesNo "Usar el último snapshot (latest)?" $true
$timestamp = ""
if (-not $latest) { $timestamp = Ask "Cadena de timestamp a buscar (ej. 2025-10-21T19:30)" }
$apply = YesNo "Aplicar cambios (no dry-run)?" $false

$args = @("scripts/restore_configurations.py","--bucket","$Bucket","--initiative","$Initiative","--criticality","$Criticality","--region","$Region")
if ($all) { $args += "--all" } else { $args += @("--services", ($services -join ',')) }
if ($latest) { $args += "--latest" } else { $args += @("--timestamp", "$timestamp") }
if ($apply) { $args += "--yes" }
if ($Profile) { $args += @("--profile","$Profile") }

Write-Host "\nEjecutando:" -ForegroundColor Cyan
Write-Host ("python " + ($args -join ' ')) -ForegroundColor DarkGray
& python @args
if ($LASTEXITCODE -eq 0) { Write-Host "\nRestauración completa." -ForegroundColor Green } else { Write-Host "\nRestauración finalizó con código $LASTEXITCODE" -ForegroundColor Red }

