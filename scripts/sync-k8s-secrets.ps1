<#
.SYNOPSIS
    Creates (or updates) every Kubernetes Secret the platform needs, from SSM and
    Terraform outputs, in one go.

.DESCRIPTION
    Run after "terraform apply" in terraform\eks (and after bootstrap-argocd.ps1
    if you want ArgoCD's Slack notifications). Safe to run again at any time.

    Secrets created:
      eddie-register-app-dev / register-app-db      DB_URL, DB_USER, DB_PASSWORD for the app
      monitoring             / grafana-admin        Grafana admin login
      monitoring             / alertmanager-slack   Slack webhook for alerts
      argocd                 / argocd-notifications-secret   Slack token (only if ArgoCD is installed)

    Values are written to a temporary file that is deleted immediately, so they
    never appear on a command line. If the app is already running, it is
    restarted so it picks up new database settings.

.EXAMPLE
    cd D:\eddie-register-app\Project\cicd-eks-pipeline
    .\scripts\sync-k8s-secrets.ps1
#>
[CmdletBinding()]
param(
    [string]$Region = 'us-east-1',
    [string[]]$AppNamespaces = @('eddie-register-app-dev')
)

$ErrorActionPreference = 'Stop'
$env:AWS_PAGER = ''
$RepoRoot = Split-Path -Parent $PSScriptRoot
$EksDir = Join-Path $RepoRoot 'terraform\eks'

function Write-Ok([string]$Text)   { Write-Host "  [OK]   $Text" -ForegroundColor Green }
function Write-Skip([string]$Text) { Write-Host "  [SKIP] $Text" -ForegroundColor Yellow }

function Invoke-Native {
    # Runs a command and returns @{ Ok; Output } without throwing on stderr.
    # Deliberately a *simple* function ($args): an advanced function would try to
    # bind short flags such as -o or -n as its own parameters.
    $exe = $args[0]
    $arguments = @($args | Select-Object -Skip 1)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $exe @arguments 2>&1 | ForEach-Object { "$_" }
        return @{ Ok = ($LASTEXITCODE -eq 0); Output = ($output -join "`n") }
    } finally {
        $ErrorActionPreference = $previous
    }
}

function Get-Ssm([string]$Name) {
    $r = Invoke-Native aws ssm get-parameter --region $Region --name $Name --with-decryption --output json
    if (-not $r.Ok) { throw "Could not read SSM parameter $Name. Run .\scripts\setup-secrets.ps1 first. ($($r.Output))" }
    return ($r.Output | ConvertFrom-Json).Parameter.Value
}

function Get-TfOutput([string]$Name) {
    $r = Invoke-Native terraform "-chdir=$EksDir" output -raw $Name
    if (-not $r.Ok) { throw "Could not read Terraform output '$Name' from terraform\eks. Has 'terraform apply' finished there? ($($r.Output))" }
    return $r.Output.Trim()
}

function Test-Namespace([string]$Name) {
    return (Invoke-Native kubectl get namespace $Name).Ok
}

function Set-Namespace([string]$Name) {
    if (-not (Test-Namespace $Name)) {
        $r = Invoke-Native kubectl create namespace $Name
        if (-not $r.Ok) { throw "Creating namespace $Name failed: $($r.Output)" }
    }
}

function Set-Secret {
    # Creates or updates a generic Secret from a hashtable of key -> value.
    param([string]$Namespace, [string]$Name, [hashtable]$Data)
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("k8s-" + [guid]::NewGuid().ToString('N') + '.env')
    $yaml = Join-Path ([IO.Path]::GetTempPath()) ("k8s-" + [guid]::NewGuid().ToString('N') + '.yaml')
    try {
        # env-file format: KEY=value, one per line; values are taken literally.
        $lines = foreach ($k in $Data.Keys) { "$k=$($Data[$k])" }
        [IO.File]::WriteAllText($tmp, (($lines -join "`n") + "`n"), (New-Object Text.UTF8Encoding $false))
        $r = Invoke-Native kubectl create secret generic $Name --namespace $Namespace --from-env-file $tmp --dry-run=client -o yaml
        if (-not $r.Ok) { throw "Building secret $Namespace/$Name failed: $($r.Output)" }
        [IO.File]::WriteAllText($yaml, $r.Output, (New-Object Text.UTF8Encoding $false))
        $a = Invoke-Native kubectl apply -f $yaml
        if (-not $a.Ok) { throw "Applying secret $Namespace/$Name failed: $($a.Output)" }
    } finally {
        foreach ($f in $tmp, $yaml) { if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force } }
    }
}

Write-Host ''
Write-Host 'Sync Kubernetes secrets from SSM and Terraform' -ForegroundColor White

foreach ($tool in 'aws', 'kubectl', 'terraform') {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "$tool is not installed or not on PATH." }
}
$ctx = Invoke-Native kubectl config current-context
if (-not $ctx.Ok) { throw "kubectl is not connected to a cluster. Run: aws eks update-kubeconfig --region $Region --name eddie-register-app-eks" }
Write-Host "  Cluster: $($ctx.Output.Trim())"
Write-Host ''

# 1. App database connection, one Secret per app namespace.
$dbHost = Get-TfOutput 'db_endpoint'
$dbPort = Get-TfOutput 'db_port'
$dbName = Get-TfOutput 'db_name'
$dbUser = Get-TfOutput 'db_username'
$dbPass = Get-Ssm '/app/db-password'
$dbUrl  = "jdbc:postgresql://${dbHost}:${dbPort}/${dbName}?sslmode=require"

foreach ($ns in $AppNamespaces) {
    Set-Namespace $ns
    Set-Secret -Namespace $ns -Name 'register-app-db' -Data @{ DB_URL = $dbUrl; DB_USER = $dbUser; DB_PASSWORD = $dbPass }
    Write-Ok "$ns/register-app-db  ->  $dbHost (database '$dbName', user '$dbUser')"

    # Restart the app (if it's running) so it reads the new settings.
    $dep = Invoke-Native kubectl get deployment -n $ns -o name
    if ($dep.Ok -and $dep.Output.Trim()) {
        foreach ($d in ($dep.Output -split "`n" | Where-Object { $_ })) {
            $null = Invoke-Native kubectl rollout restart $d -n $ns
        }
        Write-Ok "Restarted the app in $ns to pick up the database settings."
    }
}

# 2. Monitoring.
Set-Namespace 'monitoring'
Set-Secret -Namespace 'monitoring' -Name 'grafana-admin' -Data @{ 'admin-user' = 'admin'; 'admin-password' = (Get-Ssm '/monitoring/grafana-admin-password') }
Write-Ok 'monitoring/grafana-admin'
Set-Secret -Namespace 'monitoring' -Name 'alertmanager-slack' -Data @{ 'webhook-url' = (Get-Ssm '/monitoring/slack-webhook-url') }
Write-Ok 'monitoring/alertmanager-slack'

# 3. ArgoCD notifications (only once ArgoCD is installed).
if (Test-Namespace 'argocd') {
    Set-Secret -Namespace 'argocd' -Name 'argocd-notifications-secret' -Data @{ 'slack-token' = (Get-Ssm '/jenkins/slack-token') }
    Write-Ok 'argocd/argocd-notifications-secret'
} else {
    Write-Skip 'ArgoCD is not installed yet. Run this script again after bootstrap-argocd.ps1.'
}

$dbPass = $null
Write-Host ''
Write-Host 'Done.' -ForegroundColor Green
