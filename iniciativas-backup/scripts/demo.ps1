param(
  [string]$Profile = "",
  [string]$Region = "",
  [string]$Prefix = "demo",
  [ValidateSet("Critico","MenosCritico","NoCritico")]
  [string]$Criticality = "Critico"
)

$ErrorActionPreference = "Stop"
function Run($cmd) { Write-Host "» $cmd"; iex $cmd }

Write-Host "== Demo de Backups S3 (incrementales) ==" -ForegroundColor Cyan

if ($Profile) { $env:AWS_PROFILE = $Profile }

Run "terraform init -input=false"
Run "terraform apply -auto-approve"

$tf = (terraform output -json) | ConvertFrom-Json
$summary = $tf.deployment_summary.value

if (-not $Region -or $Region -eq '') { $Region = $summary.region }
$account   = $summary.account_id
$central   = $summary.central_resources.bucket_name
$findArn   = $summary.initiative_logic.find_resources_lambda_arn

$rand = (New-Guid).ToString().Substring(0,5)
$demoBucket = "$($summary.environment)-$Prefix-source-$rand"

Write-Host "Creando bucket de prueba: $demoBucket" -ForegroundColor Yellow
Run "aws s3api create-bucket --bucket $demoBucket --region $Region --create-bucket-configuration LocationConstraint=$Region"
Run "aws s3api put-bucket-tagging --bucket $demoBucket --tagging 'TagSet=[{Key=BackupEnabled,Value=true},{Key=BackupCriticality,Value=$Criticality}]'"

Write-Host "Invocando find_resources para configurar Inventory/Notificaciones..."
Run "aws lambda invoke --function-name $findArn --payload '{}' --region $Region demo-find-out.json | Out-Null"
Start-Sleep -Seconds 10

Write-Host "Subiendo archivos de prueba..."
function PutDemo($key){ $tmp = New-TemporaryFile; "demo-$([DateTime]::UtcNow)" | Set-Content -Path $tmp; Run "aws s3 cp `"$tmp`" s3://$demoBucket/$key --region $Region"; Remove-Item $tmp }
PutDemo "output/run-$(Get-Date -Format yyyyMMddHHmmss)-part-r-00000.snappy"
PutDemo "carga2/output/run-$(Get-Date -Format yyyyMMddHHmmss)-part-r-00000.snappy"

Write-Host "Esperando creación de S3 Batch Job..."
$jobId = ""
for ($i=0; $i -lt 36; $i++) {  # hasta 6 minutos
  $jobsJson = aws s3control list-jobs --account-id $account --region $Region --output json
  $jobs = $jobsJson | ConvertFrom-Json
  foreach ($j in $jobs.Jobs) {
    if ($null -ne $j.Description -and $j.Description -like "Incremental backup for $demoBucket*") {
      $jobId = $j.JobId
      break
    }
  }
  if ($jobId) { break }
  Start-Sleep -Seconds 10
}
if (-not $jobId) { throw "No se encontró un S3 Batch Job para el bucket demo (verificar S3→SQS y logs de incremental_backup)" }
Write-Host "Job creado: $jobId"

Write-Host "Monitoreando estado del Job..."
do {
  $state = aws s3control describe-job --account-id $account --region $Region --job-id $jobId --query "Job.Status" --output text
  Write-Host "  Estado: $state"
  Start-Sleep -Seconds 10
} while ($state -in @('Active','Preparing','Ready','Suspended','Cancelled','Cancelling','Completing','Failing','New','InProgress'))

Write-Host "Listando objetos copiados en el bucket central..." -ForegroundColor Green
Run "aws s3 ls s3://$central/backup/ --recursive --region $Region | Select-String $demoBucket | Select-Object -First 20"

Write-Host "Resumen del último reporte de S3 Batch..." -ForegroundColor Green
Run "python scripts/s3_batch_report_summary.py --bucket $central --region $Region"

Write-Host "Demo finalizada. Bucket de prueba: $demoBucket  |  Bucket central: $central" -ForegroundColor Cyan
