<#
.SYNOPSIS
    Creates the S3 bucket that stores Terraform state for both stacks, and
    writes terraform\backend.hcl so "terraform init" can find it.

.DESCRIPTION
    Run once per AWS account, before the first "terraform init". Safe to run
    again: existing settings are re-applied, nothing is deleted.

    The bucket:
      * is named <prefix>-<account id> (bucket names are global, so the account
        ID keeps it unique),
      * blocks all public access,
      * encrypts every object (SSE-S3),
      * refuses any request that is not HTTPS,
      * is used with S3-native state locking (Terraform 1.10+), so no DynamoDB
        table is needed.

    Versioning is OFF unless you pass -EnableVersioning. With versioning on, a
    corrupted or deleted state file can be restored from an earlier version.

.EXAMPLE
    cd D:\eddie-register-app\Project\cicd-eks-pipeline
    .\scripts\bootstrap-state-bucket.ps1

.EXAMPLE
    .\scripts\bootstrap-state-bucket.ps1 -EnableVersioning
#>
[CmdletBinding()]
param(
    [string]$Region = 'us-east-1',
    [string]$BucketPrefix = 'cicd-eks-pipeline-tfstate',
    [switch]$EnableVersioning
)

$ErrorActionPreference = 'Stop'
$env:AWS_PAGER = ''
$RepoRoot = Split-Path -Parent $PSScriptRoot
$BackendFile = Join-Path $RepoRoot 'terraform\backend.hcl'

function Invoke-Aws {
    # Runs the AWS CLI and returns @{ Ok; Output } without throwing on stderr.
    param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & aws @Arguments 2>&1 | ForEach-Object { "$_" }
        return @{ Ok = ($LASTEXITCODE -eq 0); Output = ($output -join "`n") }
    } finally {
        $ErrorActionPreference = $previous
    }
}

function Invoke-AwsJson {
    # Passes a JSON document to the AWS CLI through a temporary file, which avoids
    # Windows PowerShell's broken quoting of JSON on native command lines.
    param([string[]]$Arguments, [string]$OptionName, $Document)
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("s3-" + [guid]::NewGuid().ToString('N') + '.json')
    try {
        $json = $Document | ConvertTo-Json -Depth 10 -Compress
        [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding $false))
        # Build the full argument list, then splat it. (Passing @(...) inline hands
        # Windows PowerShell 5.1 a single array argument, which it joins into one word.)
        $all = @($Arguments) + @($OptionName, ("file://" + ($tmp -replace '\\', '/')))
        $r = Invoke-Aws @all
        if (-not $r.Ok) { throw "aws $($Arguments -join ' ') failed: $($r.Output)" }
    } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
    }
}

function Write-Ok([string]$Text) { Write-Host "  [OK]   $Text" -ForegroundColor Green }

Write-Host ''
Write-Host 'Terraform state bucket setup' -ForegroundColor White

if (-not (Get-Command aws -ErrorAction SilentlyContinue)) { throw 'The AWS CLI is not installed or not on PATH.' }

$id = Invoke-Aws sts get-caller-identity --query Account --output text
if (-not $id.Ok) { throw "AWS CLI is not logged in: $($id.Output)" }
$account = $id.Output.Trim()
$bucket = "$BucketPrefix-$account"
Write-Host "  Account: $account   Region: $Region"
Write-Host "  Bucket:  $bucket"
Write-Host ''

# 1. Create the bucket (or confirm it already exists and is ours).
$head = Invoke-Aws s3api head-bucket --bucket $bucket --region $Region
if ($head.Ok) {
    Write-Ok 'Bucket already exists in this account.'
} elseif ($head.Output -match '403|Forbidden') {
    throw "The name '$bucket' is taken by another AWS account. Re-run with -BucketPrefix <something-else>."
} else {
    if ($Region -eq 'us-east-1') {
        $create = Invoke-Aws s3api create-bucket --bucket $bucket --region $Region
    } else {
        $create = Invoke-Aws s3api create-bucket --bucket $bucket --region $Region --create-bucket-configuration "LocationConstraint=$Region"
    }
    if (-not $create.Ok) { throw "Creating the bucket failed: $($create.Output)" }
    $wait = Invoke-Aws s3api wait bucket-exists --bucket $bucket --region $Region
    if (-not $wait.Ok) { throw "Bucket was not ready in time: $($wait.Output)" }
    Write-Ok 'Bucket created.'
}

# 2. Block every form of public access.
Invoke-AwsJson -Arguments @('s3api', 'put-public-access-block', '--bucket', $bucket, '--region', $Region) `
    -OptionName '--public-access-block-configuration' `
    -Document @{ BlockPublicAcls = $true; IgnorePublicAcls = $true; BlockPublicPolicy = $true; RestrictPublicBuckets = $true }
Write-Ok 'Public access blocked.'

# 3. Encrypt everything at rest.
Invoke-AwsJson -Arguments @('s3api', 'put-bucket-encryption', '--bucket', $bucket, '--region', $Region) `
    -OptionName '--server-side-encryption-configuration' `
    -Document @{ Rules = @(@{ ApplyServerSideEncryptionByDefault = @{ SSEAlgorithm = 'AES256' }; BucketKeyEnabled = $true }) }
Write-Ok 'Default encryption enabled (SSE-S3).'

# 4. Refuse anything that is not HTTPS.
$policy = @{
    Version   = '2012-10-17'
    Statement = @(@{
        Sid       = 'DenyInsecureTransport'
        Effect    = 'Deny'
        Principal = '*'
        Action    = 's3:*'
        Resource  = @("arn:aws:s3:::$bucket", "arn:aws:s3:::$bucket/*")
        Condition = @{ Bool = @{ 'aws:SecureTransport' = 'false' } }
    })
}
Invoke-AwsJson -Arguments @('s3api', 'put-bucket-policy', '--bucket', $bucket, '--region', $Region) -OptionName '--policy' -Document $policy
Write-Ok 'HTTPS-only bucket policy applied.'

# 5. Tag it so it is easy to recognise in the console.
Invoke-AwsJson -Arguments @('s3api', 'put-bucket-tagging', '--bucket', $bucket, '--region', $Region) `
    -OptionName '--tagging' `
    -Document @{ TagSet = @(@{ Key = 'Project'; Value = 'cicd-eks-pipeline' }, @{ Key = 'Purpose'; Value = 'terraform-state' }) }
Write-Ok 'Tagged Project=cicd-eks-pipeline.'

# 6. Versioning (off unless asked for).
if ($EnableVersioning) {
    $v = Invoke-Aws s3api put-bucket-versioning --bucket $bucket --region $Region --versioning-configuration Status=Enabled
    if (-not $v.Ok) { throw "Enabling versioning failed: $($v.Output)" }
    Write-Ok 'Versioning enabled.'
} else {
    $v = Invoke-Aws s3api get-bucket-versioning --bucket $bucket --region $Region --query Status --output text
    $status = if ($v.Ok -and $v.Output.Trim() -and $v.Output.Trim() -ne 'None') { $v.Output.Trim() } else { 'Off' }
    Write-Ok "Versioning: $status (pass -EnableVersioning to turn it on)."
}

# 7. Write the shared backend settings used by both stacks.
$hcl = @"
# Generated by scripts/bootstrap-state-bucket.ps1 - shared S3 backend settings.
# Each stack sets its own "key" in its terraform { backend "s3" { ... } } block.
bucket       = "$bucket"
region       = "$Region"
encrypt      = true
use_lockfile = true
"@
[IO.File]::WriteAllText($BackendFile, ($hcl -replace "`r`n", "`n") + "`n", (New-Object Text.UTF8Encoding $false))
Write-Ok "Wrote terraform\backend.hcl"

Write-Host ''
Write-Host 'Done. Initialise each stack against the bucket:' -ForegroundColor Green
Write-Host '    cd terraform\jenkins; terraform init -reconfigure -backend-config="..\backend.hcl"'
Write-Host '    cd ..\eks;            terraform init -reconfigure -backend-config="..\backend.hcl"'
Write-Host ''
Write-Host "Never delete '$bucket' while either stack is deployed: it is the only record of what Terraform created." -ForegroundColor Yellow
