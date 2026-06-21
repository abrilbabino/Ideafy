$Project = "project-1944cf83-7f15-4f33-89b"
$ConfigFile = "..\config.json"

if (-Not (Test-Path $ConfigFile)) {
    Write-Host "No se encontró config.json en la carpeta padre" -ForegroundColor Red
    exit 1
}

$Config = Get-Content $ConfigFile | ConvertFrom-Json

$Secrets = @(
    "SPRING_DATASOURCE_PASSWORD",
    "BLOCKCHAIN_PRIVATE_KEY",
    "JWT_PRIVATE_KEY",
    "JWT_PUBLIC_KEY",
    "GOOGLE_CLIENT_SECRET",
    "SMTP_PASSWORD"
)

foreach ($SecretName in $Secrets) {
    $SecretValue = $Config.$SecretName
    
    # Crear el secreto en GCP si no existe
    Write-Host "Creando secreto $SecretName en GCP..."
    gcloud secrets create $SecretName --replication-policy="automatic" --project=$Project --quiet 2>$null
    
    # Agregar la versión al secreto
    Write-Host "Subiendo valor para $SecretName..."
    $SecretValue | gcloud secrets versions add $SecretName --data-file=- --project=$Project
}

Write-Host "¡Todos los secretos fueron subidos exitosamente!" -ForegroundColor Green
