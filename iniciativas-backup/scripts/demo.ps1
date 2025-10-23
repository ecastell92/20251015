param(
  [string]$Profile = "",
  [string]$Region = "",
  [string]$Prefix = "demo",
  [ValidateSet("Critico","MenosCritico","NoCritico")]
  [string]$Criticality = "Critico",
  [switch]$KeepBucket
)

$ErrorActionPreference = "Stop"

function Run($cmd) { Write-Host "» $cmd" -ForegroundColor DarkGray; iex $cmd }
function Stamp($msg, $color='Gray') { $ts = (Get-Date).ToString('HH:mm:ss'); Write-Host "[$ts] $msg" -ForegroundColor $color }
function Step($title) { $script:step = 1 + ($script:step ?? 0); $script:sw = [System.Diagnostics.Stopwatch]::StartNew(); Write-Host "`n=== Paso $script:step: $title ===" -ForegroundColor Cyan }
function Done() { if ($script:sw) { $script:sw.Stop(); Stamp ("OK ({0:N1}s)" -f $script:sw.Elapsed.TotalSeconds) 'Green' } }
function Sub($msg) { Stamp "• $msg" 'Yellow' }
function Info($msg) { Stamp $msg 'Gray' }
function Warn($msg) { Stamp $msg 'DarkYellow' }
function Fail($msg) { Stamp $msg 'Red' }

Write-Host "== Demo de Backups S3 (incrementales) ==" -ForegroundColor Cyan
if ($Profile) { $env:AWS_PROFILE = $Profile }

Step "Aplicando Terraform"
Run "terraform init -input=false"
Run "terraform apply -auto-approve"
Done

Step "Leyendo outputs de Terraform"
$tf = (terraform output -json) | ConvertFrom-Json
$summary = $tf.deployment_summary.value
if (-not $Region -or $Region -eq '') { $Region = $summary.region }
$account   = $summary.account_id
$central   = $summary.central_resources.bucket_name
$findArn   = $summary.initiative_logic.find_resources_lambda_arn
Info "Cuenta: $account  |  Región: $Region"
Info "Bucket central: $central"
Info "Lambda find_resources: $findArn"
Done

Step "Creando bucket de origen de prueba"
$rand = (New-Guid).ToString().Substring(0,5)
$demoBucket = "$($summary.environment)-$Prefix-source-$rand"
Sub "Nombre: $demoBucket  (tags BackupEnabled=true, BackupCriticality=$Criticality)"
Run "aws s3api create-bucket --bucket $demoBucket --region $Region --create-bucket-configuration LocationConstraint=$Region"
Run "aws s3api put-bucket-tagging --bucket $demoBucket --tagging 'TagSet=[{Key=BackupEnabled,Value=true},{Key=BackupCriticality,Value=$Criticality}]'"
Done

Step "Configurando Inventory / Notificaciones (find_resources)"
Run "aws lambda invoke --function-name $findArn --payload '{}' --region $Region demo-find-out.json | Out-Null"
Info "Para ver logs: aws logs tail /aws/lambda/$(Split-Path $findArn -Leaf) --follow --region $Region"
Start-Sleep -Seconds 10
Done

Step "Subiendo archivos de prueba al bucket origen"
function PutDemo($key){ $tmp = New-TemporaryFile; "demo-$([DateTime]::UtcNow)" | Set-Content -Path $tmp; Run "aws s3 cp `"$tmp`" s3://$demoBucket/$key --region $Region"; Remove-Item $tmp }
$k1 = "output/run-$(Get-Date -Format yyyyMMddHHmmss)-part-r-00000.snappy"
$k2 = "carga2/output/run-$(Get-Date -Format yyyyMMddHHmmss)-part-r-00000.snappy"
Sub "$k1"
PutDemo $k1
Sub "$k2"
PutDemo $k2
Done

Step "Esperando creación del S3 Batch Job"
$jobId = ""
for ($i=0; $i -lt 36; $i++) {
  Write-Progress -Activity "Buscando job" -Status "Intento $($i+1)/36" -PercentComplete (($i/36.0)*100)
  $jobsJson = aws s3control list-jobs --account-id $account --region $Region --output json
  $jobs = $jobsJson | ConvertFrom-Json
  foreach ($j in $jobs.Jobs) {
    if ($null -ne $j.Description -and $j.Description -like "Incremental backup for $demoBucket*") { $jobId = $j.JobId; break }
  }
  if ($jobId) { break }
  Start-Sleep -Seconds 10
}
Write-Progress -Activity "Buscando job" -Completed
if (-not $jobId) { Fail "No se encontró un S3 Batch Job para el bucket demo (verificar S3→SQS y logs de incremental_backup)"; exit 2 }
Info "Job creado: $jobId"
Done

Step "Monitoreando estado del Job"
do {
  $desc = aws s3control describe-job --account-id $account --region $Region --job-id $jobId --output json | ConvertFrom-Json
  $state = $desc.Job.Status
  $prog  = $desc.Job.ProgressSummary
  $msg = "Estado: $state"
  if ($prog) { $msg += " | T:$($prog.TotalNumberOfTasks) S:$($prog.NumberOfTasksSucceeded) F:$($prog.NumberOfTasksFailed)" }
  Write-Progress -Activity "S3 Batch Job $jobId" -Status $msg -PercentComplete (($prog.NumberOfTasksSucceeded / [Math]::Max(1,$prog.TotalNumberOfTasks))*100)
  Start-Sleep -Seconds 10
} while ($state -in @('Active','Preparing','Ready','New','InProgress'))
Write-Progress -Activity "S3 Batch Job $jobId" -Completed
Info "Estado final: $state"
Done

Step "Objetos copiados en el bucket central (primeros 20)"
Run "aws s3 ls s3://$central/backup/ --recursive --region $Region | Select-String $demoBucket | Select-Object -First 20"
Done

Step "Resumen del último reporte de S3 Batch"
Run "python scripts/s3_batch_report_summary.py --bucket $central --region $Region"
Done

Write-Host "`n=== Resumen ===" -ForegroundColor Cyan
Stamp "Bucket central: $central" 'Green'
Stamp "Bucket demo:    $demoBucket" 'Green'
Stamp "Para destruir: terraform destroy -auto-approve" 'Gray'
if (-not $KeepBucket) {
  Stamp "(Puedes borrar el bucket demo) aws s3 rm s3://$demoBucket --recursive; aws s3api delete-bucket --bucket $demoBucket --region $Region" 'Gray'
}
Write-Host "Demo finalizada." -ForegroundColor Cyan
