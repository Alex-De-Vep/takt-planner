$ErrorActionPreference = 'Stop'

if (-not (Get-Command node.exe -ErrorAction SilentlyContinue) -or -not (Get-Command npm.cmd -ErrorAction SilentlyContinue)) {
    throw 'Install Node.js 22.12 or later before starting the Copilot bridge.'
}
& node.exe -e 'const [major, minor] = process.versions.node.split(".").map(Number); if (major < 22 || (major === 22 && minor < 12)) process.exit(1)'
if ($LASTEXITCODE -ne 0) { throw 'The Copilot bridge requires Node.js 22.12 or later.' }
$architecture = (& node.exe -p 'process.arch').Trim()
if ($architecture -notin @('x64', 'arm64')) { throw 'Use x64 or ARM64 Node.js with this bridge.' }

$runtime = Join-Path $env:LOCALAPPDATA 'Takt/CopilotBridge/1.0.0'
New-Item -ItemType Directory -Path $runtime -Force | Out-Null
Push-Location $runtime
try {
    $binary = Join-Path $runtime "node_modules/@github/copilot-win32-$architecture/copilot.exe"
    $sourceLock = Join-Path $PSScriptRoot 'package-lock.json'
    $installedLock = Join-Path $runtime 'package-lock.json'
    $install = !(Test-Path -LiteralPath $binary) -or !(Test-Path -LiteralPath $installedLock)
    if (!$install) { $install = (Get-FileHash -LiteralPath $sourceLock).Hash -ne (Get-FileHash -LiteralPath $installedLock).Hash }
    if ($install) {
        Copy-Item -LiteralPath @($sourceLock, (Join-Path $PSScriptRoot 'package.json')) -Destination $runtime -Force
        & npm.cmd ci --omit=dev --no-audit --no-fund
        if ($LASTEXITCODE -ne 0 -or !(Test-Path -LiteralPath $binary)) { throw 'Could not install the pinned Copilot runtime.' }
    }
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'bridge.mjs') -Destination $runtime -Force
    New-Item -ItemType Directory -Path (Join-Path $runtime 'workspace') -Force | Out-Null
    $env:COPILOT_HOME = Join-Path $runtime 'account'
    foreach ($name in @('COPILOT_GITHUB_TOKEN', 'GH_TOKEN', 'GITHUB_TOKEN', 'GITHUB_COPILOT_API_TOKEN',
        'COPILOT_API_URL', 'COPILOT_PROVIDERS_CONFIG', 'COPILOT_PROVIDER_BASE_URL', 'COPILOT_PROVIDER_API_KEY',
        'COPILOT_PROVIDER_TYPE', 'COPILOT_PROVIDER_MODEL')) {
        [Environment]::SetEnvironmentVariable($name, $null, 'Process')
    }

    & node.exe bridge.mjs
    if ($LASTEXITCODE -eq 42) {
        & $binary login --web-flow
        if ($LASTEXITCODE -ne 0) { throw 'GitHub Copilot sign-in did not finish.' }
        & node.exe bridge.mjs
    }
    if ($LASTEXITCODE -ne 0) { throw 'The Copilot bridge stopped.' }
}
finally { Pop-Location }
