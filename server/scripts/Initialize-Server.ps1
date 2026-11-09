[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$SenderEmail,
    [Parameter(Mandatory = $true)][string]$AllowedEmails,
    [string]$PublicBaseUrl = 'https://replace-before-publication.invalid',
    [string]$BackupRepository = '',
    [string]$ConfigPath = ''
)
. "$PSScriptRoot/Common.ps1"
Initialize-Context -ConfigPath $ConfigPath -RequireConfig $false
Assert-Email $SenderEmail
foreach ($address in $AllowedEmails.Split(',')) { Assert-Email $address.Trim() }
$uri = [uri]$PublicBaseUrl
if (-not $uri.IsAbsoluteUri -or $uri.Scheme -ne 'https' -or $uri.AbsolutePath -ne '/' -or $uri.Query -or $uri.Fragment -or $uri.UserInfo) { throw 'PublicBaseUrl must be an HTTPS origin.' }
if (Test-Path -LiteralPath $script:ConfigPath) { throw 'server.env already exists. It was not overwritten. Edit it locally if needed.' }
$configDir = Split-Path -Parent $script:ConfigPath
New-Item -ItemType Directory -Force -Path $configDir | Out-Null
if ($env:OS -eq 'Windows_NT') {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    & icacls $configDir /inheritance:r /grant:r ($identity + ':(OI)(CI)F') '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not protect the config directory.' }
}
$secure = Read-Host 'Yandex mail APP password (input is hidden)' -AsSecureString
$pointer = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
try { $smtpPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
if (-not $smtpPassword) { throw 'The mail application password is required.' }
$values = [ordered]@{
    PUBLIC_BASE_URL = $uri.GetLeftPart([System.UriPartial]::Authority)
    PLANNER_API_PORT = '3030'
    POSTGRES_PASSWORD = (New-Secret)
    AUTH_SECRET = (New-Secret)
    SMTP_HOST = 'smtp.yandex.ru'
    SMTP_PORT = '465'
    SMTP_SECURE = 'true'
    SMTP_USER = $SenderEmail.Trim().ToLowerInvariant()
    SMTP_PASSWORD = $smtpPassword
    MAIL_FROM = $SenderEmail.Trim().ToLowerInvariant()
    ALLOWED_REGISTRATION_EMAILS = (($AllowedEmails.Split(',') | ForEach-Object { $_.Trim().ToLowerInvariant() }) -join ',')
    ALLOW_PUBLIC_REGISTRATION = 'false'
    ACCOUNT_QUOTA_BYTES = '1073741824'
    MAX_FILE_BYTES = '104857600'
    BACKUP_REPOSITORY_PATH = $BackupRepository.Replace('\', '/')
    RESTIC_PASSWORD = (New-Secret)
}
$lines = @('# Local secrets. Keep this file on the server, outside Git.')
foreach ($entry in $values.GetEnumerator()) { $lines += ($entry.Key + '=' + (ConvertTo-EnvLiteral ([string]$entry.Value))) }
[System.IO.File]::WriteAllLines($script:ConfigPath, $lines, (New-Object System.Text.UTF8Encoding($false)))
$smtpPassword = $null
foreach ($name in @('logs', 'backup-staging')) { New-Item -ItemType Directory -Force -Path (Join-Path $script:InstallRoot $name) | Out-Null }
if ($env:OS -eq 'Windows_NT') {
    $stagingPath = Join-Path $script:InstallRoot 'backup-staging'
    & icacls $stagingPath /inheritance:r /grant:r ($identity + ':(OI)(CI)F') '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not protect backup-staging.' }
}
Write-Host 'Configuration created. Existing root folders and other Docker projects were not changed.'
Write-Host 'Store RESTIC_PASSWORD separately in your password manager: it is needed to restore encrypted backups.'
Write-Host 'The placeholder PUBLIC_BASE_URL may be used for the local check. Set the real HTTPS origin before publishing.'
