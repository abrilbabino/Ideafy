# ==============================================================================
# SCRIPT DE MIGRACION CONTROLADA - IDEAFY
# Migracion de GCE Ingress -> Nginx Ingress + Cert-Manager + ArgoCD Helm
# ==============================================================================
#
# PRERREQUISITOS:
#   - gcloud CLI autenticado con permisos de admin
#   - kubectl configurado con el cluster GKE
#   - Terraform/OpenTofu instalado
#   - Acceso a GCP Console para actualizar OAuth2 Client
#
# USO: Ejecutar desde la carpeta scripts/
#   .\migrate-to-nginx.ps1
#   .\migrate-to-nginx.ps1 -DryRun
#
# ==============================================================================

param(
    [switch]$SkipConfirmations,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

# --- Configuracion ---
$GCP_PROJECT_ID  = "project-1944cf83-7f15-4f33-89b"
$REGION          = "us-central1"
$CLUSTER_NAME    = "systeam-gke-cluster"
$REGISTRY        = "$REGION-docker.pkg.dev/$GCP_PROJECT_ID/systeam-repo"
$DOMAIN          = "ideafy.lat"

# --- Rutas de los repos ---
$INFRA_DIR       = Split-Path -Parent $PSScriptRoot
$SEMINARIO_DIR   = Split-Path -Parent $INFRA_DIR
$TERRAFORM_DIR   = Join-Path $INFRA_DIR "terraform"
$K8S_DIR         = Join-Path $INFRA_DIR "k8s"
$FRONTEND_DIR    = Join-Path $SEMINARIO_DIR "SIP2026-SYSTEAM-FRONTEND"
$GATEWAY_DIR     = Join-Path $SEMINARIO_DIR "Systeam-Gateway"
$AUTH_DIR        = Join-Path $SEMINARIO_DIR "UlisesCasal-SIP2026---Systeam---Backend"
$PROJECTS_DIR    = Join-Path $SEMINARIO_DIR "Gestion_de_proyectos-Systeam"

# --- Helpers ---
function Write-Step {
    param([string]$Step, [string]$Msg)
    Write-Host ""
    Write-Host "===============================================================" -ForegroundColor Cyan
    Write-Host "  $Step" -ForegroundColor Cyan
    Write-Host "  $Msg" -ForegroundColor White
    Write-Host "===============================================================" -ForegroundColor Cyan
}

function Confirm-Step {
    param([string]$Msg)
    if (-not $SkipConfirmations) {
        Write-Host ""
        $response = Read-Host "$Msg (s/n)"
        if ($response -ne "s" -and $response -ne "S") {
            Write-Host "Paso omitido por el usuario." -ForegroundColor Yellow
            return $false
        }
    }
    return $true
}

function Test-CommandSuccess {
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: El ultimo comando fallo con codigo $LASTEXITCODE" -ForegroundColor Red
        Write-Host "Revisar el error y decidir si continuar." -ForegroundColor Yellow
        if (-not $SkipConfirmations) {
            $response = Read-Host "Continuar de todas formas? (s/n)"
            if ($response -ne "s" -and $response -ne "S") {
                throw "Migracion abortada por el usuario."
            }
        }
    }
}

# ==============================================================================
Write-Host ""
Write-Host "  +============================================================+" -ForegroundColor Magenta
Write-Host "  |              IDEAFY - Migracion Controlada                 |" -ForegroundColor Magenta
Write-Host "  |  GCE Ingress -> Nginx Ingress + Cert-Manager + ArgoCD Helm |" -ForegroundColor Magenta
Write-Host "  +============================================================+" -ForegroundColor Magenta
Write-Host ""

if ($DryRun) {
    Write-Host "  [MODO DRY-RUN] No se ejecutaran cambios destructivos." -ForegroundColor Yellow
    Write-Host ""
}

# ==============================================================================
# PASO 0: Verificar prerrequisitos
# ==============================================================================
Write-Step "PASO 0/8" "Verificando prerrequisitos..."

Write-Host "  Verificando gcloud..." -ForegroundColor Gray
$gcloudVer = gcloud --version 2>&1 | Select-Object -First 1
Write-Host "    $gcloudVer" -ForegroundColor DarkGray

Write-Host "  Verificando kubectl..." -ForegroundColor Gray
$kubectlVer = kubectl version --client 2>&1 | Select-Object -First 1
Write-Host "    $kubectlVer" -ForegroundColor DarkGray

Write-Host "  Verificando conexion al cluster..." -ForegroundColor Gray
$clusterInfo = kubectl cluster-info 2>&1 | Select-Object -First 1
Write-Host "    $clusterInfo" -ForegroundColor DarkGray

Write-Host "  Verificando tofu/terraform..." -ForegroundColor Gray
$tfCmd = if (Get-Command tofu -ErrorAction SilentlyContinue) { "tofu" } else { "terraform" }
$tfVer = & $tfCmd version 2>&1 | Select-Object -First 1
Write-Host "    $tfVer" -ForegroundColor DarkGray

Write-Host ""
Write-Host "  [OK] Todos los prerrequisitos OK" -ForegroundColor Green

# ==============================================================================
# PASO 1: Accion manual - Google OAuth2
# ==============================================================================
Write-Step "PASO 1/8" "Configurar Google OAuth2 en GCP Console (accion manual)"

Write-Host ""
Write-Host "  [!] ACCION MANUAL REQUERIDA - GCP Console" -ForegroundColor Yellow
Write-Host ""
Write-Host "  Abri: https://console.cloud.google.com/apis/credentials?project=$GCP_PROJECT_ID" -ForegroundColor White
Write-Host ""
Write-Host "  Edita el OAuth 2.0 Client ID y AGREGA (sin borrar los existentes):" -ForegroundColor White
Write-Host ""
Write-Host "    Authorized JavaScript origins:" -ForegroundColor White
Write-Host "      -> https://$DOMAIN" -ForegroundColor Green
Write-Host ""
Write-Host "    Authorized redirect URIs:" -ForegroundColor White
Write-Host "      -> https://$DOMAIN/login/oauth2/code/google" -ForegroundColor Green
Write-Host ""
Write-Host "  Esto es seguro de hacer ANTES de la migracion." -ForegroundColor Gray

if (-not (Confirm-Step "Ya configuraste el OAuth2 Client en GCP Console?")) {
    Write-Host "  [!] Recorda hacerlo antes de probar el login con Google." -ForegroundColor Yellow
}

# ==============================================================================
# PASO 2: Backup del ArgoCD Application actual
# ==============================================================================
Write-Step "PASO 2/8" "Backup y desinstalacion de ArgoCD existente (instalado via manifiestos)"

$backupDir = Join-Path $INFRA_DIR "migration-backup"
New-Item -ItemType Directory -Force -Path $backupDir | Out-Null

Write-Host "  Guardando backup de la Application de ArgoCD..." -ForegroundColor Gray
$ErrorActionPreference = "Continue"
$backupResult = kubectl get application systeam-app -n argocd -o yaml 2>&1
$ErrorActionPreference = "Stop"
if ($LASTEXITCODE -eq 0) {
    $backupResult | Set-Content (Join-Path $backupDir "argocd-app-backup.yaml")
    Write-Host "    Backup guardado." -ForegroundColor DarkGray
} else {
    Write-Host "    ArgoCD ya no existe, no se necesita backup." -ForegroundColor DarkGray
}

if ($DryRun) {
    Write-Host "  [DRY-RUN] Se omitiria la desinstalacion de ArgoCD." -ForegroundColor Yellow
} else {
    if (Confirm-Step "Desinstalar ArgoCD actual? (necesario para que Helm lo reinstale limpio)") {

        Write-Host "  Eliminando Application de ArgoCD..." -ForegroundColor Gray
        $ErrorActionPreference = "Continue"
        kubectl delete application systeam-app -n argocd --ignore-not-found 2>&1 | Out-Host

        Write-Host "  Eliminando ArgoCD (manifiestos raw)..." -ForegroundColor Gray
        kubectl delete -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml --ignore-not-found 2>&1 | Out-Host

        Write-Host "  Eliminando namespace argocd..." -ForegroundColor Gray
        kubectl delete namespace argocd --ignore-not-found 2>&1 | Out-Host
        $ErrorActionPreference = "Stop"

        # Esperar a que el namespace se elimine completamente
        Write-Host "  Esperando a que el namespace se elimine..." -ForegroundColor Gray
        $timeout = 60
        $elapsed = 0
        while ($elapsed -lt $timeout) {
            $ns = kubectl get namespace argocd --ignore-not-found --no-headers 2>$null
            if (-not $ns) { break }
            Start-Sleep -Seconds 5
            $elapsed += 5
            Write-Host "    Esperando... ($elapsed s)" -ForegroundColor DarkGray
        }

        Write-Host "  [OK] ArgoCD desinstalado" -ForegroundColor Green
    }
}

# ==============================================================================
# PASO 3: Terraform Apply (infraestructura nueva)
# ==============================================================================
Write-Step "PASO 3/8" "Terraform: crear IP regional, instalar nginx-ingress, cert-manager, ArgoCD Helm"

Write-Host "  Configurando un entorno aislado para Helm para evitar errores de cache..." -ForegroundColor Gray
$env:HELM_CONFIG_HOME = Join-Path $env:TEMP "tf-helm-config"
$env:HELM_CACHE_HOME  = Join-Path $env:TEMP "tf-helm-cache"
$env:HELM_DATA_HOME   = Join-Path $env:TEMP "tf-helm-data"
New-Item -ItemType Directory -Force -Path $env:HELM_CONFIG_HOME | Out-Null
New-Item -ItemType Directory -Force -Path $env:HELM_CACHE_HOME | Out-Null
New-Item -ItemType Directory -Force -Path $env:HELM_DATA_HOME | Out-Null

Write-Host "  Ejecutando terraform init..." -ForegroundColor Gray
Push-Location $TERRAFORM_DIR
& $tfCmd init -upgrade
Test-CommandSuccess

Write-Host ""
Write-Host "  Ejecutando terraform plan..." -ForegroundColor Gray
& $tfCmd plan -out=tfplan
Test-CommandSuccess

Write-Host ""
Write-Host "  [!] PUNTO DE NO RETORNO" -ForegroundColor Red
Write-Host "  El plan de arriba muestra los cambios. Revisa con cuidado que:" -ForegroundColor Yellow
Write-Host "    - Se DESTRUYE google_compute_global_address.systeam-static-ip" -ForegroundColor Yellow
Write-Host "    - Se CREA google_compute_address.nginx_ingress_ip (regional)" -ForegroundColor Yellow
Write-Host "    - Se CREAN helm_release.argocd, helm_release.ingress_nginx, helm_release.cert_manager" -ForegroundColor Yellow

if ($DryRun) {
    Write-Host ""
    Write-Host "  [DRY-RUN] Se omitiria terraform apply." -ForegroundColor Yellow
} else {
    if (Confirm-Step "Aplicar los cambios de Terraform? (ESTO CAUSA DOWNTIME ~5-10 min)") {
        Write-Host ""
        Write-Host "  Aplicando... (esto puede tardar 5-10 minutos)" -ForegroundColor Gray
        & $tfCmd apply tfplan
        Test-CommandSuccess
        Write-Host "  [OK] Terraform apply completado" -ForegroundColor Green
    }
}
Pop-Location

# ==============================================================================
# PASO 4: Obtener nueva IP y configurar DNS
# ==============================================================================
Write-Step "PASO 4/8" "Obtener nueva IP regional y configurar DNS"

Push-Location $TERRAFORM_DIR
$NEW_IP = & $tfCmd output -raw nginx_ingress_ip 2>$null
Pop-Location

if ($NEW_IP) {
    Write-Host ""
    Write-Host "  +---------------------------------------------+" -ForegroundColor Green
    Write-Host "  |  NUEVA IP: $NEW_IP" -ForegroundColor Green
    Write-Host "  +---------------------------------------------+" -ForegroundColor Green
    Write-Host ""
    Write-Host "  [!] ACCION MANUAL REQUERIDA - DNS" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Configura un registro A en tu proveedor de DNS:" -ForegroundColor White
    Write-Host ""
    Write-Host "    $DOMAIN  ->  $NEW_IP" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Verificar con: nslookup $DOMAIN" -ForegroundColor White
    Write-Host "  La propagacion puede tardar desde minutos hasta horas." -ForegroundColor Gray
    Write-Host "  cert-manager NO podra emitir el certificado TLS hasta que el DNS resuelva." -ForegroundColor Gray
} else {
    Write-Host "  [!] No se pudo obtener la IP. Verifica con: $tfCmd output nginx_ingress_ip" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "  Verificando que el LoadBalancer tomo la IP..." -ForegroundColor Gray
kubectl get svc -n ingress-nginx

if (-not (Confirm-Step "Ya configuraste el DNS? (podes continuar y hacerlo despues)")) {
    Write-Host "  Continuando... recorda configurar el DNS antes de verificar TLS." -ForegroundColor Yellow
}

# ==============================================================================
# PASO 5: Pushear cambios a los repos (trigger CI/CD)
# ==============================================================================
Write-Step "PASO 5/8" "Pushear codigo con CORS/env actualizados a los repos (trigger CI/CD)"

Write-Host ""
Write-Host "  Los cambios de CORS y .env.production ya estan hechos localmente." -ForegroundColor White
Write-Host "  Ahora hay que hacer commit + push en cada repo para que los pipelines" -ForegroundColor White
Write-Host "  de GitHub Actions buildeen y pusheen las imagenes Docker nuevas." -ForegroundColor White
Write-Host ""
Write-Host "  Repos a pushear:" -ForegroundColor White
Write-Host "    1) SIP2026-SYSTEAM-FRONTEND (.env.production)" -ForegroundColor Gray
Write-Host "    2) Systeam-Gateway (application.yml CORS)" -ForegroundColor Gray
Write-Host "    3) Gestion_de_proyectos-Systeam (SecurityConfig.java CORS)" -ForegroundColor Gray
Write-Host "    4) UlisesCasal-SIP2026---Systeam---Backend (SecurityConfig.java CORS)" -ForegroundColor Gray
Write-Host "    5) Ideafy (terraform + k8s manifests + workflow)" -ForegroundColor Gray
Write-Host ""

$repos = @(
    @{ Name = "Frontend";       Dir = $FRONTEND_DIR; Msg = "fix: actualizar URLs a https://ideafy.lat" }
    @{ Name = "Gateway";        Dir = $GATEWAY_DIR;  Msg = "fix: actualizar CORS a https://ideafy.lat" }
    @{ Name = "Projects-API";   Dir = $PROJECTS_DIR; Msg = "fix: actualizar CORS a https://ideafy.lat" }
    @{ Name = "Auth-API";       Dir = $AUTH_DIR;      Msg = "fix: agregar https://ideafy.lat a CORS" }
    @{ Name = "Infra (Ideafy)"; Dir = $INFRA_DIR;    Msg = "feat: migracion nginx-ingress + cert-manager + ArgoCD Helm" }
)

foreach ($repo in $repos) {
    Write-Host "  [$($repo.Name)]" -ForegroundColor Cyan

    if ($DryRun) {
        Write-Host "    [DRY-RUN] git add + commit + push" -ForegroundColor Yellow
        continue
    }

    if (Confirm-Step "  Hacer commit + push en $($repo.Name)?") {
        Push-Location $repo.Dir

        git add -A
        git status --short
        git commit -m $repo.Msg
        git push origin HEAD
        Test-CommandSuccess

        Write-Host "    [OK] Push completado" -ForegroundColor Green
        Pop-Location
    }
}

Write-Host ""
Write-Host "  Espera a que los 4 pipelines de GitHub Actions terminen." -ForegroundColor Yellow
Write-Host "  Podes verificar en: https://github.com/abrilbabino?tab=repositories" -ForegroundColor Yellow
Write-Host "  Cada pipeline tarda ~3-5 minutos en buildear la imagen Docker." -ForegroundColor Yellow
Write-Host ""

Confirm-Step "Los 4 pipelines de GitHub Actions terminaron exitosamente?" | Out-Null

# ==============================================================================
# PASO 6: Aplicar ArgoCD Application y forzar rollout
# ==============================================================================
Write-Step "PASO 6/8" "Aplicar ArgoCD Application y forzar rollout de pods"

if ($DryRun) {
    Write-Host "  [DRY-RUN] Se omitiria kubectl apply y rollout restart." -ForegroundColor Yellow
} else {
    Write-Host "  Aplicando ArgoCD Application..." -ForegroundColor Gray
    kubectl apply -f (Join-Path $K8S_DIR "argocd-app.yaml")
    Test-CommandSuccess

    Write-Host "  Esperando 30s para que ArgoCD sincronice..." -ForegroundColor Gray
    Start-Sleep -Seconds 30

    Write-Host "  Forzando rollout de los 4 deployments (para tomar imagenes nuevas)..." -ForegroundColor Gray
    kubectl rollout restart deployment frontend
    kubectl rollout restart deployment gateway
    kubectl rollout restart deployment auth-api
    kubectl rollout restart deployment projects-api

    Write-Host ""
    Write-Host "  Esperando a que los rollouts terminen..." -ForegroundColor Gray
    kubectl rollout status deployment frontend --timeout=300s
    kubectl rollout status deployment gateway --timeout=300s
    kubectl rollout status deployment auth-api --timeout=300s
    kubectl rollout status deployment projects-api --timeout=300s

    Write-Host "  [OK] Todos los deployments actualizados" -ForegroundColor Green
}

# ==============================================================================
# PASO 7: Verificar infraestructura
# ==============================================================================
Write-Step "PASO 7/8" "Verificacion de infraestructura"

Write-Host ""
Write-Host "  --- Pods de ingress-nginx ---" -ForegroundColor Cyan
kubectl get pods -n ingress-nginx

Write-Host ""
Write-Host "  --- Pods de cert-manager ---" -ForegroundColor Cyan
kubectl get pods -n cert-manager

Write-Host ""
Write-Host "  --- Pods de ArgoCD ---" -ForegroundColor Cyan
kubectl get pods -n argocd

Write-Host ""
Write-Host "  --- Services (ingress LoadBalancer IP) ---" -ForegroundColor Cyan
kubectl get svc -n ingress-nginx

Write-Host ""
Write-Host "  --- ClusterIssuer ---" -ForegroundColor Cyan
kubectl get clusterissuer

Write-Host ""
Write-Host "  --- HPAs ---" -ForegroundColor Cyan
kubectl get hpa

Write-Host ""
Write-Host "  --- Certificado TLS ---" -ForegroundColor Cyan
kubectl get certificate
$cert = kubectl get certificate systeam-tls --no-headers 2>$null
if ($cert -match "True") {
    Write-Host "  [OK] Certificado TLS emitido correctamente" -ForegroundColor Green
} else {
    Write-Host "  [!] Certificado TLS aun no emitido - verifica que el DNS este propagado." -ForegroundColor Yellow
    Write-Host "      Ejecuta: kubectl describe certificate systeam-tls" -ForegroundColor Yellow
    Write-Host "      Y verifica: nslookup $DOMAIN" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "  --- Pods de la aplicacion ---" -ForegroundColor Cyan
kubectl get pods -l "app in (frontend,gateway,auth-api,projects-api)"

# ==============================================================================
# PASO 8: Acceso a ArgoCD
# ==============================================================================
Write-Step "PASO 8/8" "Acceso a ArgoCD (port-forward)"

Write-Host "  Obteniendo password inicial de ArgoCD..." -ForegroundColor Gray
$argoPassword = kubectl -n argocd get secret argocd-initial-admin-secret -o "jsonpath={.data.password}" 2>$null
if ($argoPassword) {
    $decodedPassword = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($argoPassword))
    Write-Host ""
    Write-Host "  +---------------------------------------------+" -ForegroundColor Green
    Write-Host "  |  ArgoCD Login                               |" -ForegroundColor Green
    Write-Host "  |  User:     admin                            |" -ForegroundColor Green
    Write-Host "  |  Password: $decodedPassword" -ForegroundColor Green
    Write-Host "  +---------------------------------------------+" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Para acceder:" -ForegroundColor White
    Write-Host "    kubectl port-forward svc/argocd-server -n argocd 8080:443" -ForegroundColor White
    Write-Host "    Abrir: https://localhost:8080" -ForegroundColor White
} else {
    Write-Host "  [!] No se pudo obtener la password. Ejecuta manualmente:" -ForegroundColor Yellow
    Write-Host '      kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}"' -ForegroundColor Yellow
    Write-Host "      Y decodifica el base64 del resultado." -ForegroundColor Yellow
}

# ==============================================================================
# RESUMEN FINAL
# ==============================================================================
Write-Host ""
Write-Host "  +============================================================+" -ForegroundColor Green
Write-Host "  |                 MIGRACION COMPLETADA                       |" -ForegroundColor Green
Write-Host "  +============================================================+" -ForegroundColor Green
Write-Host "  |                                                            |" -ForegroundColor Green
Write-Host "  |  Dominio:    https://$DOMAIN                        |" -ForegroundColor Green
Write-Host "  |  Ingress:    nginx-ingress (IP regional)                   |" -ForegroundColor Green
Write-Host "  |  TLS:        cert-manager + Let's Encrypt                  |" -ForegroundColor Green
Write-Host "  |  ArgoCD:     Helm release (kubectl port-forward only)      |" -ForegroundColor Green
Write-Host "  |  HPAs:       4 servicios (2-5 replicas, CPU 50%)           |" -ForegroundColor Green
Write-Host "  |                                                            |" -ForegroundColor Green
Write-Host "  |  Checklist pendiente:                                      |" -ForegroundColor Green
Write-Host "  |    [ ] DNS apuntando a la nueva IP                         |" -ForegroundColor Green
Write-Host "  |    [ ] OAuth2 Client actualizado en GCP Console            |" -ForegroundColor Green
Write-Host "  |    [ ] Certificado TLS emitido (kubectl get certificate)   |" -ForegroundColor Green
Write-Host "  |    [ ] Login con Google funcionando                        |" -ForegroundColor Green
Write-Host "  |                                                            |" -ForegroundColor Green
Write-Host "  +============================================================+" -ForegroundColor Green
Write-Host ""
