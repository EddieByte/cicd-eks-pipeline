[CmdletBinding()]
param(
    [string]$TerraformDirectory = (Join-Path $PSScriptRoot '..\terraform\eks'),
    [string]$Region,
    [string]$ClusterName,
    [string]$ArgoCdVersion = 'v3.5.2',
    [string]$Namespace = 'argocd',
    [int]$LocalPort = 8080,
    [switch]$SkipBrowser
)

$ErrorActionPreference = 'Stop'

function Require-Command {
    param([Parameter(Mandatory)][string]$Name)

    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command '$Name' was not found in PATH."
    }
}

function Invoke-TerraformOutput {
    param([Parameter(Mandatory)][string]$Name)

    $value = & terraform -chdir=$TerraformDirectory output -raw $Name 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to read Terraform output '$Name': $($value -join ' ')"
    }

    return ($value -join "`n").Trim()
}

Require-Command 'terraform'
Require-Command 'aws'
Require-Command 'kubectl'

if (-not (Test-Path -LiteralPath $TerraformDirectory -PathType Container)) {
    throw "Terraform directory does not exist: $TerraformDirectory"
}

if ([string]::IsNullOrWhiteSpace($ClusterName)) {
    $ClusterName = Invoke-TerraformOutput -Name 'cluster_name'
}

if ([string]::IsNullOrWhiteSpace($Region)) {
    $Region = (& aws configure get region 2>$null).Trim()
}

if ([string]::IsNullOrWhiteSpace($Region)) {
    throw "No AWS region found. Pass -Region or configure one with 'aws configure'."
}

if ($ArgoCdVersion -notmatch '^v[0-9]+\.[0-9]+\.[0-9]+$') {
    throw "Argo CD version must use a pinned semantic version such as v3.5.2."
}

$existingPort = Get-NetTCPConnection -LocalPort $LocalPort -State Listen -ErrorAction SilentlyContinue
if ($existingPort) {
    throw "Local TCP port $LocalPort is already in use. Pass a different -LocalPort."
}

$env:AWS_DEFAULT_REGION = $Region

Write-Host "Updating kubeconfig for cluster '$ClusterName' in '$Region'..."
& aws eks update-kubeconfig --region $Region --name $ClusterName
if ($LASTEXITCODE -ne 0) {
    throw 'Failed to update kubeconfig.'
}

Write-Host 'Waiting for all EKS nodes to become Ready...'
& kubectl wait --for=condition=Ready node --all --timeout=10m
if ($LASTEXITCODE -ne 0) {
    throw 'EKS nodes did not become Ready within the timeout.'
}

Write-Host "Creating namespace '$Namespace' if needed..."
& kubectl create namespace $Namespace --dry-run=client -o yaml | kubectl apply -f -
if ($LASTEXITCODE -ne 0) {
    throw "Failed to create or verify namespace '$Namespace'."
}

$manifestUrl = "https://raw.githubusercontent.com/argoproj/argo-cd/$ArgoCdVersion/manifests/install.yaml"
Write-Host "Installing Argo CD $ArgoCdVersion..."
& kubectl apply --server-side --namespace $Namespace --filename $manifestUrl
if ($LASTEXITCODE -ne 0) {
    throw "Failed to install Argo CD from $manifestUrl."
}

Write-Host 'Waiting for Argo CD deployments...'
& kubectl wait --for=condition=Available deployment --all --namespace $Namespace --timeout=10m
if ($LASTEXITCODE -ne 0) {
    throw 'One or more Argo CD deployments did not become Available.'
}

Write-Host 'Waiting for the Argo CD application controller...'
& kubectl rollout status statefulset/argocd-application-controller --namespace $Namespace --timeout=10m
if ($LASTEXITCODE -ne 0) {
    throw 'The Argo CD application controller did not become Ready.'
}

$passwordBase64 = & kubectl get secret argocd-initial-admin-secret `
    --namespace $Namespace `
    --output 'jsonpath={.data.password}' 2>&1
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($passwordBase64)) {
    throw 'Unable to retrieve the Argo CD initial admin password.'
}

$password = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($passwordBase64 -join '').Trim()))
try {
    Set-Clipboard -Value $password
} catch {
    Write-Warning 'Could not copy the Argo CD password to the clipboard.'
}

$portForward = Start-Process kubectl `
    -ArgumentList @('port-forward', "service/argocd-server", "${LocalPort}:443", '--namespace', $Namespace) `
    -PassThru `
    -WindowStyle Hidden

Start-Sleep -Seconds 2
if ($portForward.HasExited) {
    throw 'Argo CD port-forward exited unexpectedly.'
}

$url = "https://localhost:$LocalPort"
Write-Host ''
Write-Host 'Argo CD is ready.' -ForegroundColor Green
Write-Host "URL:      $url"
Write-Host 'Username: admin'
Write-Host 'Password: copied to the clipboard'
Write-Host "Stop port-forward: Stop-Process -Id $($portForward.Id)"

if (-not $SkipBrowser) {
    Start-Process $url
}