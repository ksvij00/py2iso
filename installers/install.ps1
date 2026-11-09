<#
.SYNOPSIS
    py2iso installer for Windows (PowerShell 5.1+ and PowerShell 7+).

.DESCRIPTION
    Installs Git and Python 3.8+ automatically if missing (winget first,
    direct download as fallback), creates a virtual environment, installs
    py2iso, and adds a launcher to your user PATH.

    This file is pure ASCII on purpose. The block-letter logo is stored as
    base64 and decoded at runtime, so it prints correctly regardless of how
    the file is saved (no BOM or encoding problems).

.PARAMETER InstallDir
    Where the virtual environment is created. Default: $env:LOCALAPPDATA\py2iso

.PARAMETER Package
    Package spec to install when no local checkout is found. Default: py2iso

.PARAMETER NoLogo
    Skip the banner (useful in CI).

.PARAMETER NoAutoInstall
    Do not install Git/Python automatically; just fail if they are missing.

.EXAMPLE
    .\install.ps1
    .\install.ps1 -InstallDir C:\tools\py2iso -NoLogo
#>
[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'py2iso'),
    [string]$Package    = 'py2iso',
    [switch]$NoLogo,
    [switch]$NoAutoInstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Older Windows PowerShell defaults to TLS 1.0/1.1, which python.org and GitHub reject.
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
$ProgressPreference = 'SilentlyContinue'   # makes Invoke-WebRequest much faster on 5.1

$MinPython       = [version]'3.8'
$PythonFallbackV = '3.12.7'

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
function Write-Step { param([string]$Message) Write-Host "[*] $Message" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Message) Write-Host "[+] $Message" -ForegroundColor Green }
function Write-Warn { param([string]$Message) Write-Host "[!] $Message" -ForegroundColor Yellow }
function Write-Fail { param([string]$Message) Write-Host "[x] $Message" -ForegroundColor Red }

function Get-LogoText {
    $b64 =
        '4paI4paI4paI4paI4paI4paI4pWXIOKWiOKWiOKVlyAgIOKWiOKWiOKVl+KWiOKWiOKWiOKWiOKW' +
        'iOKWiOKVlyDilojilojilZfilojilojilojilojilojilojilojilZcg4paI4paI4paI4paI4paI' +
        '4paI4pWXCuKWiOKWiOKVlOKVkOKVkOKWiOKWiOKVl+KVmuKWiOKWiOKVlyDilojilojilZTilZ3i' +
        'lZrilZDilZDilZDilZDilojilojilZfilojilojilZHilojilojilZTilZDilZDilZDilZDilZ3i' +
        'lojilojilZTilZDilZDilZDilojilojilZcK4paI4paI4paI4paI4paI4paI4pWU4pWdIOKVmuKW' +
        'iOKWiOKWiOKWiOKVlOKVnSAg4paI4paI4paI4paI4paI4pWU4pWd4paI4paI4pWR4paI4paI4paI' +
        '4paI4paI4paI4paI4pWX4paI4paI4pWRICAg4paI4paI4pWRCuKWiOKWiOKVlOKVkOKVkOKVkOKV' +
        'nSAgIOKVmuKWiOKWiOKVlOKVnSAg4paI4paI4pWU4pWQ4pWQ4pWQ4pWdIOKWiOKWiOKVkeKVmuKV' +
        'kOKVkOKVkOKVkOKWiOKWiOKVkeKWiOKWiOKVkSAgIOKWiOKWiOKVkQrilojilojilZEgICAgICAg' +
        'IOKWiOKWiOKVkSAgIOKWiOKWiOKWiOKWiOKWiOKWiOKWiOKVl+KWiOKWiOKVkeKWiOKWiOKWiOKW' +
        'iOKWiOKWiOKWiOKVkeKVmuKWiOKWiOKWiOKWiOKWiOKWiOKVlOKVnQrilZrilZDilZ0gICAgICAg' +
        'IOKVmuKVkOKVnSAgIOKVmuKVkOKVkOKVkOKVkOKVkOKVkOKVneKVmuKVkOKVneKVmuKVkOKVkOKV' +
        'kOKVkOKVkOKVkOKVnSDilZrilZDilZDilZDilZDilZDilZ0K'
    return [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64))
}

function Show-Logo {
    # Make the console able to display the block characters.
    try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
    Write-Host ''
    Write-Host (Get-LogoText) -ForegroundColor Magenta -NoNewline
    Write-Host '   Python -> bootable ISO' -ForegroundColor DarkMagenta
    Write-Host ''
}

# ---------------------------------------------------------------------------
# PATH + download helpers
# ---------------------------------------------------------------------------
function Update-SessionPath {
    # Pick up PATH changes made by installers without opening a new terminal.
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user    = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = (@($machine, $user) | Where-Object { $_ }) -join ';'
}

function Save-Download {
    param([string]$Url, [string]$OutFile)
    Write-Step "Downloading $Url"
    Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing
    if (-not (Test-Path -LiteralPath $OutFile)) { throw "Download failed: $Url" }
}

function Invoke-Installer {
    # Returns the exit code. 0 and 3010 (reboot pending) are success; callers
    # decide what to do with anything else listed in -TolerateCodes.
    param([string]$Exe, [string[]]$InstallerArgs, [int[]]$TolerateCodes = @())
    $p = Start-Process -FilePath $Exe -ArgumentList $InstallerArgs -Wait -PassThru
    $code = $p.ExitCode
    if ($code -ne 0 -and $code -ne 3010 -and ($TolerateCodes -notcontains $code)) {
        throw ("Installer exited with code {0}: {1}" -f $code, $Exe)
    }
    return $code
}

function Test-Winget {
    return [bool](Get-Command winget -ErrorAction SilentlyContinue)
}

# ---------------------------------------------------------------------------
# Git
# ---------------------------------------------------------------------------
function Find-Git {
    $cmd = Get-Command git -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $known = @(
        (Join-Path $env:ProgramFiles 'Git\cmd\git.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Git\cmd\git.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Git\cmd\git.exe')
    )
    foreach ($k in $known) {
        if ($k -and (Test-Path -LiteralPath $k)) {
            $env:Path = "$env:Path;" + (Split-Path -Parent $k)
            return $k
        }
    }
    return $null
}

function Install-Git {
    Write-Step 'Git not found. Installing Git...'

    if (Test-Winget) {
        & winget install --id Git.Git -e --source winget --silent --accept-package-agreements --accept-source-agreements
        Update-SessionPath
        if (Find-Git) { return }
        Write-Warn 'winget did not produce a working git; trying direct download.'
    }

    $api   = 'https://api.github.com/repos/git-for-windows/git/releases/latest'
    $rel   = Invoke-RestMethod -Uri $api -Headers @{ 'User-Agent' = 'py2iso-installer' }
    $asset = $rel.assets | Where-Object { $_.name -match '^Git-.*-64-bit\.exe$' } | Select-Object -First 1
    if (-not $asset) { throw 'Could not find a Git for Windows installer in the latest release.' }

    $tmp = Join-Path $env:TEMP $asset.name
    Save-Download -Url $asset.browser_download_url -OutFile $tmp
    Invoke-Installer -Exe $tmp -InstallerArgs @('/VERYSILENT', '/NORESTART', '/NOCANCEL', '/SP-')
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue

    Update-SessionPath
    if (-not (Find-Git)) { throw 'Git was installed but could not be located. Open a new terminal and re-run.' }
}

function Confirm-Git {
    $git = Find-Git
    if (-not $git) {
        if ($NoAutoInstall) { throw 'Git is required but was not found (auto-install disabled).' }
        Install-Git
        $git = Find-Git
    }
    $v = & $git --version
    Write-Ok "Using $v"
}

# ---------------------------------------------------------------------------
# Python
# ---------------------------------------------------------------------------
$script:ProbeLog = New-Object System.Collections.Generic.List[string]

function Test-PythonExe {
    # Returns a PSCustomObject {Exe, Version} if usable and new enough, else $null.
    param([string]$Exe, [string[]]$ExtraArgs = @())

    # Windows PowerShell 5.1 turns native stderr into terminating errors under 'Stop'.
    $ErrorActionPreference = 'Continue'
    try {
        $code = 'import sys; print("%d.%d.%d" % sys.version_info[:3])'
        $out  = & $Exe @ExtraArgs -c $code 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $out) {
            $script:ProbeLog.Add("$Exe : probe failed (exit $LASTEXITCODE)")
            return $null
        }
        $ver = [version]($out | Select-Object -First 1).ToString().Trim()
        if ($ver -lt $MinPython) {
            $script:ProbeLog.Add("$Exe : version $ver is older than $MinPython")
            return $null
        }

        $real = & $Exe @ExtraArgs -c 'import sys; print(sys.executable)' 2>$null
        $real = ($real | Select-Object -First 1).Trim()
        if (-not $real) { return $null }

        return [pscustomobject]@{ Exe = $real; Version = $ver }
    }
    catch {
        $script:ProbeLog.Add("$Exe : $($_.Exception.Message)")
        return $null
    }
}

function Find-Python {
    $script:ProbeLog.Clear()

    # 1) Every python/py on PATH (Get-Command can return several; try them all).
    $names = @(
        @{ Name = 'py';      Args = @('-3') },
        @{ Name = 'python';  Args = @() },
        @{ Name = 'python3'; Args = @() }
    )
    foreach ($c in $names) {
        $cmds = @(Get-Command $c.Name -All -CommandType Application -ErrorAction SilentlyContinue)
        foreach ($cmd in $cmds) {
            if (-not $cmd.Source) { continue }
            $found = Test-PythonExe -Exe $cmd.Source -ExtraArgs $c.Args
            if ($found) { return $found }
        }
    }

    # 2) Interpreters advertised via environment (actions/setup-python, runner tool cache).
    $envRoots = @($env:pythonLocation, $env:Python_ROOT_DIR, $env:Python3_ROOT_DIR) | Where-Object { $_ }
    foreach ($r in $envRoots) {
        $exe = Join-Path $r 'python.exe'
        if (Test-Path -LiteralPath $exe) {
            $found = Test-PythonExe -Exe $exe
            if ($found) { return $found }
        }
    }
    if ($env:RUNNER_TOOL_CACHE) {
        $tc = Join-Path $env:RUNNER_TOOL_CACHE 'Python'
        if (Test-Path -LiteralPath $tc) {
            $exes = Get-ChildItem -LiteralPath $tc -Recurse -Filter python.exe -ErrorAction SilentlyContinue |
                    Sort-Object FullName -Descending
            foreach ($e in $exes) {
                $found = Test-PythonExe -Exe $e.FullName
                if ($found) { return $found }
            }
        }
    }

    # 3) Registry (PEP 514): where python.org installers register themselves.
    $regRoots = @(
        'HKCU:\SOFTWARE\Python\PythonCore',
        'HKLM:\SOFTWARE\Python\PythonCore',
        'HKLM:\SOFTWARE\WOW6432Node\Python\PythonCore'
    )
    foreach ($rr in $regRoots) {
        if (-not (Test-Path -LiteralPath $rr)) { continue }
        foreach ($k in (Get-ChildItem -LiteralPath $rr -ErrorAction SilentlyContinue)) {
            $ipKey = Join-Path $k.PSPath 'InstallPath'
            if (-not (Test-Path -LiteralPath $ipKey)) { continue }
            $ip  = Get-ItemProperty -LiteralPath $ipKey -ErrorAction SilentlyContinue
            $exe = $null
            if ($ip -and $ip.PSObject.Properties['ExecutablePath']) { $exe = $ip.ExecutablePath }
            elseif ($ip -and $ip.PSObject.Properties['(default)'])   { $exe = Join-Path $ip.'(default)' 'python.exe' }
            if ($exe -and (Test-Path -LiteralPath $exe)) {
                $found = Test-PythonExe -Exe $exe
                if ($found) { return $found }
            }
        }
    }

    # 4) Usual install folders.
    $roots = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Python'),
        $env:ProgramFiles,
        ${env:ProgramFiles(x86)},
        'C:\'
    )
    foreach ($root in $roots) {
        if (-not $root -or -not (Test-Path -LiteralPath $root)) { continue }
        $dirs = Get-ChildItem -LiteralPath $root -Directory -Filter 'Python3*' -ErrorAction SilentlyContinue |
                Sort-Object Name -Descending
        foreach ($d in $dirs) {
            $exe = Join-Path $d.FullName 'python.exe'
            if (Test-Path -LiteralPath $exe) {
                $found = Test-PythonExe -Exe $exe
                if ($found) { return $found }
            }
        }
    }
    return $null
}

function Show-PythonProbeLog {
    if ($script:ProbeLog.Count -eq 0) {
        Write-Warn 'No Python candidates were found anywhere (PATH, registry, install folders).'
        return
    }
    Write-Warn 'Python candidates that were tried and rejected:'
    foreach ($line in $script:ProbeLog) { Write-Host "      $line" -ForegroundColor DarkGray }
}

function Install-Python {
    Write-Step 'Python not found. Installing Python...'

    if (Test-Winget) {
        & winget install --id Python.Python.3.12 -e --source winget --silent --accept-package-agreements --accept-source-agreements
        Update-SessionPath
        if (Find-Python) { return }
        Write-Warn 'winget did not produce a working Python; trying direct download.'
        Show-PythonProbeLog
    }

    $arch = if ([Environment]::Is64BitOperatingSystem) { 'amd64' } else { 'win32' }
    $name = "python-$PythonFallbackV-$arch.exe"
    $url  = "https://www.python.org/ftp/python/$PythonFallbackV/$name"
    $tmp  = Join-Path $env:TEMP $name

    Save-Download -Url $url -OutFile $tmp
    $code = Invoke-Installer -TolerateCodes @(1638) -Exe $tmp -InstallerArgs @(
        '/quiet', 'InstallAllUsers=0', 'PrependPath=1', 'Include_launcher=0', 'Include_test=0'
    )
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue

    if ($code -eq 1638) {
        Write-Warn 'Windows reports a Python 3.12 is already installed (code 1638); locating it instead.'
    }

    Update-SessionPath
    if (-not (Find-Python)) {
        Show-PythonProbeLog
        throw 'Python is installed but could not be used. See the rejected candidates above.'
    }
}

function Confirm-Python {
    $py = Find-Python
    if (-not $py) {
        if ($NoAutoInstall) { throw ("Python {0}+ is required but was not found (auto-install disabled)." -f $MinPython) }
        Install-Python
        $py = Find-Python
    }
    Write-Ok ("Using Python {0} at {1}" -f $py.Version, $py.Exe)
    return $py
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
function Install-Py2Iso {
    if (-not $NoLogo) { Show-Logo }

    Write-Step 'Checking Git...'
    Confirm-Git

    Write-Step 'Checking Python...'
    $Python    = Confirm-Python
    $PythonExe = $Python.Exe   # plain string; call with & so spaces in paths just work

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
        Write-Step "Installing $Package"
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
    $BinDir = Join-Path $InstallDir 'bin'
    $Shim   = Join-Path $BinDir 'py2iso.cmd'
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
    Write-Host '    Run:  py2iso --help'
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
