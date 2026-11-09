<#
.SYNOPSIS
    p2i installer for Windows (PowerShell 5.1+ and PowerShell 7+).

.DESCRIPTION
    1. Makes sure Python 3.8+ is available (installs it if missing).
    2. Puts p2i.py in  <Program Files>\p2i\  (or %LOCALAPPDATA%\Programs\p2i
       when not running as administrator).
       - If this script sits in a repo checkout, bin\p2i.py is copied from there.
       - Otherwise p2i.py is downloaded from -Url.
    3. Creates a  p2i  command (p2i.cmd) that runs:  python <install dir>\p2i.py
    4. Adds the install folder to PATH (machine-wide if admin, else per-user).

    Pure ASCII on purpose; the logo is base64 so no encoding problems.

.PARAMETER Url
    Where to download p2i.py when no local copy exists.
    CHANGE THE DEFAULT to your real repo's raw link.

.PARAMETER InstallDir
    Override the install folder.

.PARAMETER NoLogo
    Skip the banner (useful in CI).

.PARAMETER NoAutoInstall
    Do not install Python automatically.

.EXAMPLE
    .\install.ps1
    .\install.ps1 -Url https://raw.githubusercontent.com/OWNER/REPO/main/bin/p2i.py
#>
[CmdletBinding()]
param(
    [string]$Url = 'https://raw.githubusercontent.com/ksvij/py2iso/main/bin/p2i.py',
    [string]$InstallDir,
    [switch]$NoLogo,
    [switch]$NoAutoInstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
$ProgressPreference = 'SilentlyContinue'

$MinPython       = [version]'3.8'
$PythonFallbackV = '3.12.7'

function Write-Step { param([string]$Message) Write-Host "[*] $Message" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Message) Write-Host "[+] $Message" -ForegroundColor Green }
function Write-Warn { param([string]$Message) Write-Host "[!] $Message" -ForegroundColor Yellow }
function Write-Fail { param([string]$Message) Write-Host "[x] $Message" -ForegroundColor Red }

function Test-IsAdmin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        return ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

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
# Python
# ---------------------------------------------------------------------------
$script:ProbeLog = New-Object System.Collections.Generic.List[string]

function Test-PythonExe {
    # Returns a PSCustomObject {Exe, Version} if usable and new enough, else $null.
    param([string]$Exe, [string[]]$ExtraArgs = @())

    # Windows PowerShell 5.1 turns native stderr into terminating errors under 'Stop'.
    $ErrorActionPreference = 'Continue'
    try {
        # No double quotes in -c code: Windows PowerShell 5.1 strips them when calling native exes.
        $code = 'import sys; print(*sys.version_info[:3], sep=chr(46))'
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

function Install-P2I {
    if (-not $NoLogo) { Show-Logo }

    $IsAdmin = Test-IsAdmin

    # --- Python -------------------------------------------------------------
    Write-Step 'Checking Python...'
    $Python    = Confirm-Python
    $PythonExe = $Python.Exe

    # --- Where to install ---------------------------------------------------
    if (-not $InstallDir) {
        if ($IsAdmin) { $InstallDir = Join-Path $env:ProgramFiles 'p2i' }
        else          { $InstallDir = Join-Path $env:LOCALAPPDATA 'Programs\p2i' }
    }
    Write-Step "Install folder: $InstallDir"
    if (-not $IsAdmin -and $InstallDir -like "$env:ProgramFiles*") {
        throw 'Installing into Program Files needs an administrator shell. Re-run as admin or omit -InstallDir.'
    }
    if (-not (Test-Path -LiteralPath $InstallDir)) {
        New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    }

    # --- Get p2i.py ---------------------------------------------------------
    $Target = Join-Path $InstallDir 'p2i.py'
    $Local  = $null
    if ($PSScriptRoot) {
        $cand = Join-Path (Split-Path -Parent $PSScriptRoot) 'bin\p2i.py'
        if (Test-Path -LiteralPath $cand) { $Local = $cand }
    }

    if ($Local) {
        Write-Step "Copying p2i.py from local checkout: $Local"
        Copy-Item -LiteralPath $Local -Destination $Target -Force
    }
    else {
        Save-Download -Url $Url -OutFile $Target
    }

    if (-not (Test-Path -LiteralPath $Target) -or (Get-Item -LiteralPath $Target).Length -eq 0) {
        throw "p2i.py is missing or empty at $Target"
    }
    # A 404 from GitHub raw returns a tiny text body, not Python.
    $head = Get-Content -LiteralPath $Target -TotalCount 1 -ErrorAction SilentlyContinue
    if ($head -match '^(404|<!DOCTYPE|<html)') {
        Remove-Item -LiteralPath $Target -Force
        throw "Download returned an error page, not Python. Check -Url: $Url"
    }
    Write-Ok "Installed $Target"

    # --- p2i command --------------------------------------------------------
    $Shim = Join-Path $InstallDir 'p2i.cmd'
    $shimLines = @(
        '@echo off',
        'setlocal',
        ('set "PY={0}"' -f $PythonExe),
        'if not exist "%PY%" set "PY=python"',
        '"%PY%" "%~dp0p2i.py" %*',
        'exit /b %ERRORLEVEL%'
    )
    Set-Content -LiteralPath $Shim -Value $shimLines -Encoding Ascii
    Write-Ok "Command created: $Shim"

    # --- PATH ---------------------------------------------------------------
    $scope = if ($IsAdmin) { 'Machine' } else { 'User' }
    $cur   = [Environment]::GetEnvironmentVariable('Path', $scope)
    if (-not $cur) { $cur = '' }
    $has = ($cur -split ';') | Where-Object { $_ -and ($_.TrimEnd('\') -ieq $InstallDir.TrimEnd('\')) }
    if (-not $has) {
        $new = if ($cur) { $cur.TrimEnd(';') + ';' + $InstallDir } else { $InstallDir }
        [Environment]::SetEnvironmentVariable('Path', $new, $scope)
        Write-Ok "Added to $scope PATH."
    }
    $env:Path = "$env:Path;$InstallDir"

    # CI: make it available to later steps too.
    if ($env:GITHUB_PATH) {
        Add-Content -LiteralPath $env:GITHUB_PATH -Value $InstallDir -Encoding Ascii
    }

    Write-Host ''
    Write-Ok 'p2i installed.'
    Write-Host '    Open a NEW terminal, then run:  p2i'
}

try {
    Install-P2I
    exit 0
}
catch {
    Write-Fail $_.Exception.Message
    if ($_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray }
    exit 1
}
