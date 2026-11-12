<#
.SYNOPSIS
    Generic version of the secrets setup + preflight check for this platform.
    Prompts for every SSM parameter the stacks need, validates each one, and prints
    READY / NOT READY before "terraform apply".

.DESCRIPTION
    Nothing in this script is specific to one person or project: usernames, repository
    names and the EC2 key pair are passed as parameters or asked for.

    For each parameter the script:
      * shows whether it already exists in SSM (keep it or replace it),
      * prompts for the value (secrets are typed hidden and never printed),
      * checks the format, and where possible checks it really works
        (GitHub, Docker Hub and Slack are asked whether the token is valid),
      * saves it to SSM and reads it back to confirm.

    It then checks what "terraform apply" depends on: AWS login, the S3 state bucket,
    the EC2 key pair, AMIs, leftovers from a previous deployment, the Slack workspace in
    ansible/playbooks/master.yml, and (optionally) that your repos are pushed.

    Tip: copy this file to scripts/setup-secrets.ps1 (git-ignored) and set your own
    defaults in the param() block, so you don't have to type them on every run.

    Requires: AWS CLI v2, Terraform, Git; Windows PowerShell 5.1+ or PowerShell 7+.

.PARAMETER KeyPairName
    EC2 key pair name. Default: key_name from terraform/jenkins/terraform.tfvars.
.PARAMETER GitHubUser
    Suggested default for /jenkins/github-username.
.PARAMETER ManifestsRepo
    "owner/name" of your manifests repo. If set, the GitHub token is checked for push access.
.PARAMETER DockerHubUser
    Suggested default for /jenkins/dockerhub-username.
.PARAMETER RelatedRepos
    Folder names of other repos next to this one to check are committed and pushed.

.EXAMPLE
    .\scripts\setup-secrets.example.ps1

.EXAMPLE
    .\scripts\setup-secrets.example.ps1 -GitHubUser my-org -ManifestsRepo my-org/my-app-manifests -DockerHubUser mydockerid -RelatedRepos my-app,my-app-manifests

.EXAMPLE
    .\scripts\setup-secrets.example.ps1 -CheckOnly
    Changes nothing; only validates what is already stored and runs the preflight.
#>
[CmdletBinding()]
param(
    [string]$Region = 'us-east-1',
    [string]$KeyPairName = '',
    [string]$GitHubUser = '',
    [string]$ManifestsRepo = '',
    [string]$DockerHubUser = '',
    [string[]]$RelatedRepos = @(),
    [switch]$CheckOnly
)

$ErrorActionPreference = 'Stop'
$env:AWS_PAGER = ''
# Windows PowerShell 5.1 draws a progress bar for every web request, which makes
# Invoke-WebRequest many times slower. Turning it off speeds up the live checks.
$ProgressPreference = 'SilentlyContinue'
# Windows PowerShell 5.1 defaults to old TLS versions that GitHub and Slack reject.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$RepoRoot    = Split-Path -Parent $PSScriptRoot
$ProjectRoot = Split-Path -Parent $RepoRoot
$MasterYml   = Join-Path $RepoRoot 'ansible\playbooks\master.yml'

# Key pair: use the one Terraform is configured with unless given explicitly.
if (-not $KeyPairName) {
    $tfvarsPath = Join-Path $RepoRoot 'terraform\jenkins\terraform.tfvars'
    if (Test-Path -LiteralPath $tfvarsPath) {
        $KeyPairName = [regex]::Match([IO.File]::ReadAllText($tfvarsPath), 'key_name\s*=\s*"([^"]+)"').Groups[1].Value
    }
    if (-not $KeyPairName) { $KeyPairName = (Read-Host 'EC2 key pair name (as in terraform.tfvars key_name)').Trim() }
}

$script:Problems = New-Object System.Collections.Generic.List[string]
$script:Warnings = New-Object System.Collections.Generic.List[string]

# -- Output helpers ------------------------------------------------------------

function Write-Section([string]$Text) { Write-Host ''; Write-Host "== $Text ==" -ForegroundColor Cyan }
function Write-Ok([string]$Text)      { Write-Host "  [OK]   $Text" -ForegroundColor Green }
function Write-Info([string]$Text)    { Write-Host "         $Text" -ForegroundColor Gray }
function Write-Warn([string]$Text)    { Write-Host "  [WARN] $Text" -ForegroundColor Yellow; $script:Warnings.Add($Text) }
function Write-Bad([string]$Text)     { Write-Host "  [FAIL] $Text" -ForegroundColor Red; $script:Problems.Add($Text) }

# -- AWS CLI helpers -----------------------------------------------------------

function Invoke-Aws {
    # Runs the AWS CLI and returns @{ Ok; Output } without throwing on stderr
    # (Windows PowerShell 5.1 turns native stderr into terminating errors under 'Stop').
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

# Every AWS CLI call costs 1-3 seconds on Windows, so all parameters are read in
# two batched calls up front and kept in this cache.
$script:ParamCache = @{}

function Import-ParamCache([string[]]$Names) {
    for ($i = 0; $i -lt $Names.Count; $i += 10) {          # SSM allows 10 names per call
        $batch = $Names[$i..([Math]::Min($i + 9, $Names.Count - 1))]
        $r = Invoke-Aws ssm get-parameters --region $Region --with-decryption --names @batch --output json
        if (-not $r.Ok) { throw "Could not read SSM parameters: $($r.Output)" }
        foreach ($p in ($r.Output | ConvertFrom-Json).Parameters) {
            $script:ParamCache[$p.Name] = @{ Exists = $true; Type = $p.Type; LastModified = $p.LastModifiedDate; Value = $p.Value }
        }
    }
}

function Update-ParamCache([string]$Name) {
    $r = Invoke-Aws ssm get-parameter --region $Region --name $Name --with-decryption --output json
    if ($r.Ok) {
        $p = ($r.Output | ConvertFrom-Json).Parameter
        $script:ParamCache[$Name] = @{ Exists = $true; Type = $p.Type; LastModified = $p.LastModifiedDate; Value = $p.Value }
    } elseif ($r.Output -match 'ParameterNotFound') {
        $script:ParamCache.Remove($Name)
    } else {
        throw "Could not read SSM parameter $Name : $($r.Output)"
    }
}

function Get-ParamInfo([string]$Name) {
    if ($script:ParamCache.ContainsKey($Name)) { return $script:ParamCache[$Name] }
    return @{ Exists = $false }
}

function Get-ParamValue([string]$Name) {
    if ($script:ParamCache.ContainsKey($Name)) { return $script:ParamCache[$Name].Value }
    throw "SSM parameter $Name not found."
}

function Set-ParamValue([string]$Name, [string]$Type, [string]$Value) {
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("ssm-" + [guid]::NewGuid().ToString('N') + '.json')
    try {
        $json = @{ Name = $Name; Type = $Type; Value = $Value; Overwrite = $true } | ConvertTo-Json -Compress
        [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding $false))
        $r = Invoke-Aws ssm put-parameter --region $Region --cli-input-json ("file://" + ($tmp -replace '\\', '/'))
        if (-not $r.Ok) { throw "Saving $Name failed: $($r.Output)" }
        Update-ParamCache $Name                                 # read back from AWS
    } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
    }
}

# -- Input helpers -------------------------------------------------------------

function ConvertTo-PlainText([Security.SecureString]$Secure) {
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function New-StrongPassword([int]$Length = 20) {
    # Avoids characters that cause trouble in properties files, shells, URLs and
    # RDS (which rejects @ / " and spaces in passwords).
    $sets = @('ABCDEFGHJKLMNPQRSTUVWXYZ', 'abcdefghijkmnopqrstuvwxyz', '23456789', '!#%^*-_=+')
    $all  = -join $sets
    $rng  = [Security.Cryptography.RandomNumberGenerator]::Create()
    $byte = New-Object byte[] 1
    $pick = {
        param($set)
        # Rejection sampling keeps every character equally likely.
        do { $rng.GetBytes($byte) } while ($byte[0] -ge (256 - (256 % $set.Length)))
        $set[$byte[0] % $set.Length]
    }
    $chars = New-Object System.Collections.Generic.List[char]
    foreach ($s in $sets) { $chars.Add((& $pick $s)) }            # at least one of each class
    while ($chars.Count -lt $Length) { $chars.Add((& $pick $all)) }
    # Shuffle so the guaranteed characters are not always first.
    for ($i = $chars.Count - 1; $i -gt 0; $i--) {
        $rng.GetBytes($byte); $j = $byte[0] % ($i + 1)
        $t = $chars[$i]; $chars[$i] = $chars[$j]; $chars[$j] = $t
    }
    return -join $chars
}

function Read-Value($Def) {
    switch ($Def.Input) {
        'file' {
            while ($true) {
                $path = (Read-Host "    Path to the .pem file").Trim().Trim('"')
                if ($path -and (Test-Path -LiteralPath $path -PathType Leaf)) {
                    $Def.SourcePath = $path
                    $text = [IO.File]::ReadAllText($path)
                    return (($text -replace "`r`n", "`n").Trim() + "`n")
                }
                Write-Host "    File not found, try again." -ForegroundColor Yellow
            }
        }
        'plain' {
            $prompt = "    Value"
            if ($Def.Default) { $prompt += " [Enter = $($Def.Default)]" }
            $v = (Read-Host $prompt).Trim()
            if (-not $v -and $Def.Default) { $v = $Def.Default }
            return $v
        }
        default {
            $prompt = "    Value (typing is hidden)"
            if ($Def.CanGenerate) { $prompt += " [Enter = generate a strong one]" }
            $v = ConvertTo-PlainText (Read-Host $prompt -AsSecureString)
            if (-not $v -and $Def.CanGenerate) {
                $v = New-StrongPassword
                Write-Info "Generated a 20-character password. Retrieve it later with:"
                Write-Info "aws ssm get-parameter --region $Region --name $($Def.Name) --with-decryption --query Parameter.Value --output text"
            }
            return $v.Trim()
        }
    }
}

# -- HTTP helper for live checks -----------------------------------------------

function Invoke-Http {
    # Returns @{ Status; Body; Headers } instead of throwing on 4xx/5xx.
    param([string]$Method = 'GET', [string]$Uri, [hashtable]$Headers = @{}, $Body, [string]$ContentType = 'application/json')
    try {
        # User-Agent must be set via -UserAgent (Windows PowerShell 5.1 rejects it in -Headers).
        $params = @{ Method = $Method; Uri = $Uri; Headers = $Headers; UseBasicParsing = $true; TimeoutSec = 10; UserAgent = 'setup-secrets.ps1' }
        if ($null -ne $Body) { $params.Body = $Body; $params.ContentType = $ContentType }
        $resp = Invoke-WebRequest @params
        return @{ Status = [int]$resp.StatusCode; Body = $resp.Content; Headers = $resp.Headers }
    } catch {
        $status = 0
        if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
        $body = ''
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $body = $_.ErrorDetails.Message }
        return @{ Status = $status; Body = $body; Headers = @{}; Error = $_.Exception.Message }
    }
}

# Values gathered during the run, used by later checks.
$script:Known = @{}

# -- Parameter definitions -----------------------------------------------------
# Validate: returns $null when the format is fine, otherwise an error message.
# Live:     returns @{ Ok = $true/$false/$null; Message } ($null = could not verify).

$Definitions = @(
    @{
        Name = '/jenkins/ssh-private-key'; Type = 'SecureString'; Input = 'file'
        Label = "Private key (.pem) for the '$KeyPairName' EC2 key pair"
        Validate = {
            param($v)
            if ($v -notmatch '-----BEGIN [A-Z ]*PRIVATE KEY-----' -or $v -notmatch '-----END [A-Z ]*PRIVATE KEY-----') {
                return 'This does not look like a private key (missing BEGIN/END PRIVATE KEY lines).'
            }
            if ([Text.Encoding]::UTF8.GetByteCount($v) -gt 4096) { return 'Key is larger than the 4 KB SSM limit.' }
            $null
        }
        Live = {
            param($v, $def)
            $kp = Invoke-Aws ec2 describe-key-pairs --region $Region --key-names $KeyPairName --include-public-key --output json
            if (-not $kp.Ok) { return @{ Ok = $false; Message = "EC2 key pair '$KeyPairName' does not exist in $Region." } }
            $awsPub = (($kp.Output | ConvertFrom-Json).KeyPairs[0].PublicKey -split '\s+')[1]
            if (-not $awsPub -or -not (Get-Command ssh-keygen -ErrorAction SilentlyContinue)) {
                return @{ Ok = $null; Message = "Key pair '$KeyPairName' exists (could not compare it with the .pem file)." }
            }
            $tmp = Join-Path ([IO.Path]::GetTempPath()) ("k-" + [guid]::NewGuid().ToString('N'))
            try {
                if ($def.SourcePath) { $file = $def.SourcePath } else { [IO.File]::WriteAllText($tmp, $v); $file = $tmp }
                $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
                $pub = (& ssh-keygen -y -f $file 2>$null) -join ''
                $ErrorActionPreference = $prev
            } finally { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force } }
            if (-not $pub) { return @{ Ok = $null; Message = "Key pair '$KeyPairName' exists (ssh-keygen could not read the key to compare)." } }
            if (($pub -split '\s+')[1] -eq $awsPub) { return @{ Ok = $true; Message = "Matches the '$KeyPairName' key pair in AWS." } }
            return @{ Ok = $false; Message = "This key does NOT match the '$KeyPairName' key pair in AWS." }
        }
    }
    @{
        Name = '/jenkins/github-username'; Type = 'String'; Input = 'plain'; Default = $GitHubUser
        Label = 'GitHub username'
        Validate = { param($v) if ($v -notmatch '^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})$') { 'Not a valid GitHub username.' } }
    }
    @{
        Name = '/jenkins/github-token'; Type = 'SecureString'; Input = 'secret'
        Label = 'GitHub personal access token (needs push access to your manifests repo)'
        Validate = { param($v) if ($v -notmatch '^(ghp_|github_pat_)') { 'GitHub tokens start with ghp_ or github_pat_.' } }
        Live = {
            param($v)
            $h = @{ Authorization = "Bearer $v"; Accept = 'application/vnd.github+json' }
            $me = Invoke-Http -Uri 'https://api.github.com/user' -Headers $h
            if ($me.Status -eq 401) { return @{ Ok = $false; Message = 'GitHub rejected this token (invalid or expired).' } }
            if ($me.Status -ne 200) { return @{ Ok = $null; Message = "Could not reach GitHub to verify ($($me.Error))." } }
            $login = ($me.Body | ConvertFrom-Json).login
            $user = $script:Known['/jenkins/github-username']
            if ($user -and $login -ne $user) {
                return @{ Ok = $false; Message = "Token belongs to '$login', but the username parameter is '$user'." }
            }
            if (-not $ManifestsRepo) {
                return @{ Ok = $true; Message = "Valid for '$login' (pass -ManifestsRepo owner/name to also check push access)." }
            }
            $repo = Invoke-Http -Uri "https://api.github.com/repos/$ManifestsRepo" -Headers $h
            if ($repo.Status -ne 200) { return @{ Ok = $false; Message = "Token cannot see $ManifestsRepo." } }
            $perm = ($repo.Body | ConvertFrom-Json).permissions
            if ($perm -and -not $perm.push) { return @{ Ok = $false; Message = 'Token can read but NOT push to the manifests repo (Jenkins needs push).' } }
            return @{ Ok = $true; Message = "Valid for '$login' with push access to the manifests repo." }
        }
    }
    @{
        Name = '/jenkins/dockerhub-username'; Type = 'String'; Input = 'plain'; Default = $DockerHubUser
        Label = 'Docker Hub username'
        Validate = { param($v) if ($v -notmatch '^[a-z0-9]{4,30}$') { 'Docker Hub usernames are 4-30 lowercase letters/digits.' } }
    }
    @{
        Name = '/jenkins/dockerhub-token'; Type = 'SecureString'; Input = 'secret'
        Label = 'Docker Hub access token (Account settings > Personal access tokens, Read & Write)'
        Validate = { param($v) if ($v.Length -lt 10) { 'That is too short to be a Docker Hub token.' } }
        Live = {
            param($v)
            $user = $script:Known['/jenkins/dockerhub-username']
            if (-not $user) { return @{ Ok = $null; Message = 'Username unknown, skipped login test.' } }
            $r = Invoke-Http -Method POST -Uri 'https://hub.docker.com/v2/auth/token' -Body (@{ identifier = $user; secret = $v } | ConvertTo-Json)
            if ($r.Status -in 404, 405) {
                $r = Invoke-Http -Method POST -Uri 'https://hub.docker.com/v2/users/login' -Body (@{ username = $user; password = $v } | ConvertTo-Json)
            }
            if ($r.Status -eq 200) { return @{ Ok = $true; Message = "Docker Hub login works for '$user'." } }
            if ($r.Status -eq 401) { return @{ Ok = $false; Message = 'Docker Hub rejected this username/token.' } }
            return @{ Ok = $null; Message = "Could not verify with Docker Hub (HTTP $($r.Status))." }
        }
    }
    @{
        Name = '/sonarqube/db-username'; Type = 'String'; Input = 'plain'; Default = 'sonar'
        Label = 'SonarQube PostgreSQL username'
        Validate = { param($v) if ($v -notmatch '^[a-z_][a-z0-9_]{0,30}$') { 'Use lowercase letters, digits and _ (start with a letter).' } }
    }
    @{
        Name = '/sonarqube/db-password'; Type = 'SecureString'; Input = 'secret'; CanGenerate = $true
        Label = 'SonarQube PostgreSQL password (nobody types this; generating one is easiest)'
        Validate = {
            param($v)
            if ($v.Length -lt 12) { return 'Use at least 12 characters.' }
            if ($v -match '[\\\s]') { return 'No backslashes or spaces (it is written into sonar.properties).' }
            $null
        }
    }
    @{
        Name = '/sonarqube/admin-password'; Type = 'SecureString'; Input = 'secret'; CanGenerate = $true
        Label = 'SonarQube admin password (you log in to SonarQube with this)'
        Validate = {
            param($v)
            # SonarQube's own password policy; a weaker one makes Ansible's password change fail silently.
            if ($v.Length -lt 12 -or $v -cnotmatch '[A-Z]' -or $v -cnotmatch '[a-z]' -or $v -notmatch '\d' -or $v -notmatch '[^A-Za-z0-9]') {
                return 'SonarQube requires 12+ characters with upper case, lower case, a digit and a symbol.'
            }
            if ($v -eq 'admin') { return 'Must differ from the default password.' }
            if ($v -match '\\') { return 'Avoid backslashes.' }
            $null
        }
    }
    @{
        Name = '/jenkins/slack-token'; Type = 'SecureString'; Input = 'secret'
        Label = 'Slack bot token (xoxb-...)'
        Validate = { param($v) if ($v -notmatch '^xoxb-') { 'Slack bot tokens start with xoxb-.' } }
        Live = {
            param($v)
            $r = Invoke-Http -Method POST -Uri 'https://slack.com/api/auth.test' -Headers @{ Authorization = "Bearer $v" }
            if ($r.Status -ne 200) { return @{ Ok = $null; Message = "Could not reach Slack to verify (HTTP $($r.Status))." } }
            $j = $r.Body | ConvertFrom-Json
            if (-not $j.ok) { return @{ Ok = $false; Message = "Slack rejected this token ($($j.error))." } }
            if ($j.url -match '^https://([^.]+)\.slack\.com') { $script:Known['slack-domain'] = $Matches[1] }
            return @{ Ok = $true; Message = "Valid bot '$($j.user)' in workspace '$($j.team)' ($($j.url))." }
        }
    }
    @{
        Name = '/monitoring/slack-webhook-url'; Type = 'SecureString'; Input = 'secret'
        Label = 'Slack incoming webhook URL (for the alerts channel)'
        Validate = { param($v) if ($v -notmatch '^https://hooks\.slack\.com/services/\S+$') { 'Expected https://hooks.slack.com/services/...' } }
        Live = {
            param($v)
            # An empty payload is rejected with "no_text" by a VALID webhook, and with
            # invalid_token / no_service by a dead one. Nothing is posted to the channel.
            $r = Invoke-Http -Method POST -Uri $v -Body '{}'
            if ($r.Body -match 'no_text|missing_text|invalid_payload') { return @{ Ok = $true; Message = 'Webhook is active.' } }
            if ($r.Body -match 'invalid_token|no_service|no_team|channel_not_found|team_disabled') {
                return @{ Ok = $false; Message = "Slack says this webhook is not valid ($($r.Body))." }
            }
            return @{ Ok = $null; Message = "Could not verify the webhook (HTTP $($r.Status))." }
        }
    }
    @{
        Name = '/monitoring/grafana-admin-password'; Type = 'SecureString'; Input = 'secret'; CanGenerate = $true
        Label = 'Grafana admin password (you log in to Grafana with this)'
        Validate = { param($v) if ($v.Length -lt 8) { 'Use at least 8 characters.' } }
    }
    @{
        Name = '/app/db-password'; Type = 'SecureString'; Input = 'secret'; CanGenerate = $true
        Label = 'RDS PostgreSQL password for the app (nobody types this; generating one is easiest)'
        Validate = {
            param($v)
            if ($v.Length -lt 12 -or $v.Length -gt 128) { return 'Use 12 to 128 characters.' }
            # RDS rejects these characters in the master password.
            if ($v -match '[@/"\s]') { return 'RDS does not allow @, /, double quotes or spaces in the password.' }
            if ($v -match '[^\x21-\x7E]') { return 'Use plain ASCII characters only.' }
            $null
        }
    }
)

# -- 1. Tools and AWS login ----------------------------------------------------

Write-Host ''
Write-Host 'Pipeline secrets setup and preflight' -ForegroundColor White
if ($CheckOnly) { Write-Host '(check-only mode: nothing will be changed)' -ForegroundColor Gray }

Write-Section 'Tools'
foreach ($tool in 'aws', 'terraform', 'git', 'kubectl') {
    if (Get-Command $tool -ErrorAction SilentlyContinue) { Write-Ok "$tool found" }
    elseif ($tool -eq 'kubectl') { Write-Warn 'kubectl not found (not needed yet, but needed for the EKS/ArgoCD phase).' }
    else { Write-Bad "$tool is not installed or not on PATH." }
}
if (-not (Get-Command aws -ErrorAction SilentlyContinue)) {
    Write-Host ''; Write-Host 'Install the AWS CLI first, then run this script again.' -ForegroundColor Red; exit 1
}

Write-Section 'AWS login'
$id = Invoke-Aws sts get-caller-identity --output json
if (-not $id.Ok) {
    Write-Bad "AWS CLI is not logged in: $($id.Output)"
    Write-Host ''; Write-Host "Run 'aws configure' (or 'aws sso login'), then run this script again." -ForegroundColor Red; exit 1
}
$who = $id.Output | ConvertFrom-Json
Write-Ok "Account $($who.Account) as $($who.Arn)"
Write-Info "Region: $Region"
if (-not $CheckOnly) {
    $answer = Read-Host '  Is this the right AWS account? (Y/n)'
    if ($answer -match '^[nN]') { Write-Host 'Stopped. Switch profiles (e.g. $env:AWS_PROFILE = "name") and re-run.'; exit 1 }
}

# -- 2. Parameters -------------------------------------------------------------

Write-Section 'SSM parameters'
Write-Info 'Reading what is already stored...'
Import-ParamCache ($Definitions | ForEach-Object { $_.Name })
$index = 0
foreach ($def in $Definitions) {
    $index++
    Write-Host ''
    Write-Host ("[{0}/{1}] {2}" -f $index, $Definitions.Count, $def.Name) -ForegroundColor White
    Write-Info $def.Label

    $info = Get-ParamInfo $def.Name
    $value = $null
    $mustPrompt = $false

    if ($info.Exists) {
        Write-Info "Already exists ($($info.Type), last changed $($info.LastModified))."
        if ($info.Type -ne $def.Type) {
            Write-Warn "Stored as $($info.Type) but should be $($def.Type); it will be re-saved."
        }
        if (-not $CheckOnly) {
            $choice = Read-Host '    [K]eep it or [R]eplace it? (K/r)'
            $mustPrompt = $choice -match '^[rR]'
        }
        if (-not $mustPrompt) { $value = Get-ParamValue $def.Name }
    } elseif ($CheckOnly) {
        Write-Bad "$($def.Name) is missing."
        continue
    } else {
        $mustPrompt = $true
    }

    $save = $mustPrompt -or ($info.Exists -and $info.Type -ne $def.Type -and -not $CheckOnly)

    while ($true) {
        if ($mustPrompt) { $value = Read-Value $def }

        if (-not $value) {
            if ($mustPrompt) { Write-Host '    A value is required.' -ForegroundColor Yellow; continue }
            Write-Bad "$($def.Name) is empty."; break
        }

        $formatError = & $def.Validate $value
        if ($formatError) {
            if ($mustPrompt) { Write-Host "    $formatError Try again." -ForegroundColor Yellow; continue }
            Write-Bad "$($def.Name): $formatError"
            break
        }

        $script:Known[$def.Name] = $value
        $live = $null
        if ($def.Live) { $live = & $def.Live $value $def }

        if ($live -and $live.Ok -eq $false) {
            if ($mustPrompt) {
                Write-Host "    $($live.Message)" -ForegroundColor Yellow
                $retry = Read-Host '    [R]e-enter or [S]ave anyway? (R/s)'
                if ($retry -notmatch '^[sS]') { continue }
                Write-Warn "$($def.Name): saved despite: $($live.Message)"
            } else {
                Write-Bad "$($def.Name): $($live.Message)"
                break
            }
        } elseif ($live -and $null -eq $live.Ok) {
            Write-Warn "$($def.Name): $($live.Message)"
        }

        if ($save) {
            Set-ParamValue $def.Name $def.Type $value
            $check = Get-ParamInfo $def.Name
            $readBack = Get-ParamValue $def.Name
            if ($check.Exists -and $check.Type -eq $def.Type -and $readBack -ceq $value) {
                Write-Ok "Saved and verified ($($def.Type))."
            } else {
                Write-Bad "$($def.Name) did not read back correctly after saving."
                break
            }
        } else {
            Write-Ok 'Present and valid.'
        }
        if ($live -and $live.Ok) { Write-Info $live.Message }
        break
    }
}

# -- 3. Slack workspace name in master.yml -------------------------------------

Write-Section 'Jenkins Slack workspace setting'
if (-not (Test-Path -LiteralPath $MasterYml)) {
    Write-Bad "Cannot find $MasterYml (run this script from the cicd-eks-pipeline repo)."
} else {
    $yml = [IO.File]::ReadAllText($MasterYml)
    $m = [regex]::Match($yml, 'jenkins_slack_team_domain:\s*"([^"]*)"')
    $current = if ($m.Success) { $m.Groups[1].Value } else { $null }
    $detected = $script:Known['slack-domain']
    if (-not $m.Success) {
        Write-Bad 'jenkins_slack_team_domain is missing from master.yml.'
    } elseif ($detected -and $current -ne $detected) {
        if ($CheckOnly) {
            Write-Bad "master.yml has '$current' but your Slack workspace is '$detected'."
        } else {
            $fix = Read-Host "  master.yml has '$current'; your Slack workspace is '$detected'. Update it? (Y/n)"
            if ($fix -notmatch '^[nN]') {
                $yml = $yml.Replace($m.Value, "jenkins_slack_team_domain: `"$detected`"")
                [IO.File]::WriteAllText($MasterYml, $yml, (New-Object Text.UTF8Encoding $false))
                Write-Ok "master.yml updated to '$detected' (commit and push this change)."
                $script:Warnings.Add('master.yml was just changed: commit and push cicd-eks-pipeline before terraform apply.')
            } else {
                Write-Bad "master.yml still has '$current'."
            }
        }
    } elseif ($current -eq 'CHANGE-ME' -or -not $current) {
        Write-Bad 'jenkins_slack_team_domain in master.yml is still CHANGE-ME.'
    } else {
        Write-Ok "jenkins_slack_team_domain = '$current'"
    }
}

# -- 4. AWS resources Terraform depends on -------------------------------------

Write-Section 'Terraform state backend (S3)'
$backendFile = Join-Path $RepoRoot 'terraform\backend.hcl'
$stateBucket = $null
if (-not (Test-Path -LiteralPath $backendFile)) {
    Write-Bad 'terraform\backend.hcl is missing. Run .\scripts\bootstrap-state-bucket.ps1 first.'
} else {
    $stateBucket = [regex]::Match([IO.File]::ReadAllText($backendFile), 'bucket\s*=\s*"([^"]+)"').Groups[1].Value
    $hb = Invoke-Aws s3api head-bucket --bucket $stateBucket --region $Region
    if ($hb.Ok) { Write-Ok "State bucket '$stateBucket' exists." }
    else { Write-Bad "State bucket '$stateBucket' (from backend.hcl) is not reachable. Run .\scripts\bootstrap-state-bucket.ps1." ; $stateBucket = $null }
}

Write-Section 'AWS prerequisites'
$kp = Invoke-Aws ec2 describe-key-pairs --region $Region --key-names $KeyPairName --output json
if ($kp.Ok) { Write-Ok "EC2 key pair '$KeyPairName' exists." } else { Write-Bad "EC2 key pair '$KeyPairName' not found in $Region." }

foreach ($stack in 'jenkins', 'eks') {
    $tfvars = Join-Path $RepoRoot "terraform\$stack\terraform.tfvars"
    if (-not (Test-Path -LiteralPath $tfvars)) { Write-Bad "Missing terraform\$stack\terraform.tfvars"; continue }
    $ami = [regex]::Match([IO.File]::ReadAllText($tfvars), 'ami_id\s*=\s*"([^"]+)"').Groups[1].Value
    if (-not $ami) { Write-Warn "No ami_id in terraform\$stack\terraform.tfvars"; continue }
    $img = Invoke-Aws ec2 describe-images --region $Region --image-ids $ami --query 'Images[0].State' --output text
    if ($img.Ok -and $img.Output.Trim() -eq 'available') { Write-Ok "AMI $ami ($stack) is available." }
    else { Write-Bad "AMI $ami in terraform\$stack\terraform.tfvars is not available (retired?). Update ami_id." }
}

$ip = Invoke-Aws iam get-instance-profile --instance-profile-name jenkins-master-profile --output json
if ($ip.Ok) {
    # Is it recorded in the remote state? (Then it is a running deployment, not a leftover.)
    $managed = $false
    if ($stateBucket) {
        $st = Invoke-Aws s3 cp "s3://$stateBucket/jenkins/terraform.tfstate" - --region $Region
        $managed = $st.Ok -and ($st.Output -match 'jenkins-master-profile')
    }
    if ($managed) { Write-Ok 'CI stack already exists and is tracked by Terraform state (apply will update it).' }
    else { Write-Bad "IAM instance profile 'jenkins-master-profile' exists but is not in Terraform state: a previous deployment was not fully destroyed. Delete it first." }
} else {
    Write-Ok 'No leftover IAM instance profile from a previous deployment.'
}

$vpcs = Invoke-Aws ec2 describe-vpcs --region $Region --filters 'Name=cidr,Values=10.10.0.0/16,10.20.0.0/16' --query 'Vpcs[].VpcId' --output text
if ($vpcs.Ok -and $vpcs.Output.Trim() -and $vpcs.Output.Trim() -ne 'None') {
    Write-Warn "VPCs with this project's CIDRs already exist: $($vpcs.Output.Trim()). Fine if Terraform manages them; otherwise they are leftovers."
} else {
    Write-Ok 'No leftover project VPCs.'
}

# -- 5. Repos pushed to GitHub -------------------------------------------------

Write-Section 'Git repositories'
$reposToCheck = @(@{ Name = (Split-Path -Leaf $RepoRoot); Path = $RepoRoot }) +
    @($RelatedRepos | ForEach-Object { @{ Name = $_; Path = (Join-Path $ProjectRoot $_) } })
foreach ($repoEntry in $reposToCheck) {
    $name = $repoEntry.Name
    $path = $repoEntry.Path
    if (-not (Test-Path -LiteralPath (Join-Path $path '.git'))) { Write-Warn "$name not found next to this repo; skipped."; continue }
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $dirty = (& git -C $path status --porcelain 2>$null)
    $ahead = (& git -C $path rev-list --count '@{u}..HEAD' 2>$null)
    $ErrorActionPreference = $prev
    if ($dirty) { Write-Bad "$name has uncommitted changes (commit and push them)." }
    elseif ($ahead -and [int]$ahead -gt 0) { Write-Bad "$name has $ahead commit(s) not pushed to GitHub." }
    else { Write-Ok "$name is committed and pushed." }
}

# -- Result --------------------------------------------------------------------

Write-Host ''
Write-Host '======================================================' -ForegroundColor White
if ($script:Problems.Count -eq 0) {
    Write-Host '  READY - you can deploy.' -ForegroundColor Green
    if ($script:Warnings.Count) {
        Write-Host '  Notes:' -ForegroundColor Yellow
        $script:Warnings | Select-Object -Unique | ForEach-Object { Write-Host "   - $_" -ForegroundColor Yellow }
    }
    Write-Host ''
    Write-Host '  Next:' -ForegroundColor White
    Write-Host '    cd terraform\jenkins'
    Write-Host '    terraform init'
    Write-Host '    terraform plan      # expect "X to add, 0 to change, 0 to destroy"'
    Write-Host '    terraform apply'
} else {
    Write-Host "  NOT READY - fix these $($script:Problems.Count) item(s), then run the script again:" -ForegroundColor Red
    $script:Problems | ForEach-Object { Write-Host "   - $_" -ForegroundColor Red }
    if ($script:Warnings.Count) {
        Write-Host '  Also note:' -ForegroundColor Yellow
        $script:Warnings | Select-Object -Unique | ForEach-Object { Write-Host "   - $_" -ForegroundColor Yellow }
    }
}
Write-Host '======================================================' -ForegroundColor White

# Drop secrets from memory.
$script:Known.Clear(); $value = $null; $readBack = $null
if ($script:Problems.Count) { exit 1 } else { exit 0 }
