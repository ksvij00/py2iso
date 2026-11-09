<#
.SYNOPSIS
    py2iso installer for Windows (PowerShell 5.1+ and PowerShell 7+).

.DESCRIPTION
    Finds Python 3.8+, creates a virtual environment, installs py2iso
    (from the local repo checkout if present, otherwise from PyPI),
    and verifies the install.

    This file is pure ASCII on purpose: no smart quotes, no box-drawing
    characters, so it parses the same on every encoding.

.PARAMETER InstallDir
    Where the virtual environment is created. Default: $env:LOCALAPPDATA\py2iso

.PARAMETER Package
    Package spec to install when no local checkout is found. Default: py2iso

.PARAMETER NoLogo
    Skip the banner (useful in CI).

.EXAMPLE
    .\install.ps1
    .\install.ps1 -InstallDir C:\tools\py2iso -NoLogo
#>
[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'py2iso'),
    [string]$Package    = 'py2iso',
    [switch]$NoLogo
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$MinPython = [version]'3.8'

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
function Write-Step { param([string]$Message) Write-Host "[*] $Message" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Message) Write-Host "[+] $Message" -ForegroundColor Green }
function Write-Warn { param([string]$Message) Write-Host "[!] $Message" -ForegroundColor Yellow }
function Write-Fail { param([string]$Message) Write-Host "[x] $Message" -ForegroundColor Red }

function Show-Logo {
    # Single-quoted here-string: everything between @' and '@ is literal.
    # Quotes, $, backticks and backslashes inside the art are all safe.
    # RULE: the closing '@ must be at column 0 on its own line.
    $logo = @'
                 ____  _
  _ __  _   _ |___ \(_)___  ___
 | '_ \| | | |  __) | / __|/ _ \
 | |_) | |_| | / __/| \__ \ (_) |
 | .__/ \__, ||_____|_|___/\___/
 |_|    |___/

   Python -> bootable ISO
'@
    Write-Host $logo -ForegroundColor Magenta
    Write-Host ''
}

# ---------------------------------------------------------------------------
# Python discovery
# ---------------------------------------------------------------------------
function Test-PythonExe {
    # Returns a PSCustomObject {Exe, Version} if the exe is a usable Python, else $null.
    param([string]$Exe, [string[]]$ExtraArgs = @())

    try {
        $code = 'import sys; print("%d.%d.%d" % sys.version_info[:3])'
        $out  = & $Exe @ExtraArgs -c $code 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $out) { return $null }
        $ver = [version]($out | Select-Object -First 1).Trim()
        if ($ver -lt $MinPython) { return $null }

        # Resolve the real interpreter path (py.exe is only a launcher).
        $real = & $Exe @ExtraArgs -c 'import sys; print(sys.executable)' 2>$null
        $real = ($real | Select-Object -First 1).Trim()
        if (-not $real) { return $null }

        return [pscustomobject]@{ Exe = $real; Version = $ver }
    }
    catch {
        return $null
    }
}

function Find-Python {
    # 1) py launcher, 2) python, 3) python3
    $candidates = @(
        @{ Name = 'py';      Args = @('-3') },
        @{ Name = 'python';  Args = @() },
        @{ Name = 'python3'; Args = @() }
    )

    foreach ($c in $candidates) {
        $cmd = Get-Command $c.Name -ErrorAction SilentlyContinue
        if (-not $cmd) { continue }

        # Skip the Microsoft Store stub in WindowsApps; it opens the Store instead of running Python.
        if ($cmd.Source -like '*\WindowsApps\*' -and $c.Name -ne 'py') {
            $probe = Test-PythonExe -Exe $cmd.Source -ExtraArgs $c.Args
            if (-not $probe) { continue }
        }

        $found = Test-PythonExe -Exe $cmd.Source -ExtraArgs $c.Args
        if ($found) { return $found }
    }
    return $null
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
function Install-Py2Iso {
    if (-not $NoLogo) { Show-Logo }

    Write-Step 'Looking for Python...'
    $Python = Find-Python
    if (-not $Python) {
        Write-Fail ("Python {0}+ was not found on PATH." -f $MinPython)
        Write-Host '    Install it from https://www.python.org/downloads/ (tick "Add python.exe to PATH"),'
        Write-Host '    or run: winget install Python.Python.3.12'
        exit 1
    }
    Write-Ok ("Using Python {0} at {1}" -f $Python.Version, $Python.Exe)

    # Do NOT build command strings with embedded quotes. Keep the path as a plain
    # string and call it with the & operator; PowerShell handles spaces for you.
    $PythonExe = $Python.Exe

    # --- Virtual environment ------------------------------------------------
    Write-Step "Creating virtual environment in $InstallDir"
    if (-not (Test-Path -LiteralPath $InstallDir)) {
        New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    }

    $VenvDir    = Join-Path $InstallDir 'venv'
    $VenvPython = Join-Path $VenvDir 'Scripts\python.exe'

    if (-not (Test-Path -LiteralPath $VenvPython)) {
        & $PythonExe -m venv $VenvDir
        if ($LASTEXITCODE -ne 0) { throw 'Failed to create the virtual environment.' }
    }
    else {
        Write-Warn 'Existing virtual environment found; reusing it.'
    }

    # --- pip ----------------------------------------------------------------
    Write-Step 'Upgrading pip...'
    & $VenvPython -m pip install --upgrade pip --disable-pip-version-check
    if ($LASTEXITCODE -ne 0) { throw 'pip upgrade failed.' }

    # --- py2iso -------------------------------------------------------------
    # Prefer the local checkout (this script lives in <repo>\installers\).
    $RepoRoot = Split-Path -Parent $PSScriptRoot
    $HasLocal = $RepoRoot -and (
        (Test-Path -LiteralPath (Join-Path $RepoRoot 'pyproject.toml')) -or
        (Test-Path -LiteralPath (Join-Path $RepoRoot 'setup.py'))
    )

    if ($HasLocal) {
        Write-Step "Installing py2iso from local checkout: $RepoRoot"
        & $VenvPython -m pip install --disable-pip-version-check $RepoRoot
    }
    else {
        Write-Step "Installing $Package from PyPI"
        & $VenvPython -m pip install --disable-pip-version-check $Package
    }
    if ($LASTEXITCODE -ne 0) { throw 'py2iso installation failed.' }

    $ReqFile = if ($RepoRoot) { Join-Path $RepoRoot 'requirements.txt' } else { $null }
    if ($ReqFile -and (Test-Path -LiteralPath $ReqFile)) {
        Write-Step 'Installing requirements.txt...'
        & $VenvPython -m pip install --disable-pip-version-check -r $ReqFile
        if ($LASTEXITCODE -ne 0) { throw 'Installing requirements.txt failed.' }
    }

    # --- Verify -------------------------------------------------------------
    Write-Step 'Verifying install...'
    & $VenvPython -c 'import py2iso; print("py2iso imported OK")'
    if ($LASTEXITCODE -ne 0) {
        Write-Warn 'Could not import "py2iso" as a module. If your entry point is a script, this is fine.'
    }

    # --- Launcher shim ------------------------------------------------------
    $BinDir  = Join-Path $InstallDir 'bin'
    $Shim    = Join-Path $BinDir 'py2iso.cmd'
    if (-not (Test-Path -LiteralPath $BinDir)) {
        New-Item -ItemType Directory -Path $BinDir -Force | Out-Null
    }
    $shimLines = @(
        '@echo off',
        ('"{0}" -m py2iso %*' -f $VenvPython)
    )
    Set-Content -LiteralPath $Shim -Value $shimLines -Encoding Ascii
    Write-Ok "Launcher created: $Shim"

    # --- PATH (per-user) ----------------------------------------------------
    $UserPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (-not $UserPath) { $UserPath = '' }
    $already = ($UserPath -split ';') | Where-Object { $_ -ieq $BinDir }
    if (-not $already) {
        $newPath = if ($UserPath) { "$UserPath;$BinDir" } else { $BinDir }
        [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
        $env:Path = "$env:Path;$BinDir"
        Write-Ok 'Added install folder to your user PATH (open a new terminal to use it).'
    }

    Write-Host ''
    Write-Ok 'py2iso installed successfully.'
    Write-Host "    Run:  py2iso --help"
}

try {
    Install-Py2Iso
    exit 0
}
catch {
    Write-Fail $_.Exception.Message
    if ($_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray }
    exit 1
}
