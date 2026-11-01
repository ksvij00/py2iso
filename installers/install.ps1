```powershell
# ============================================================
# PY2ISO Windows Installer
# PowerShell 5.1 / 7+
#
# Usage:
# irm "https://raw.githubusercontent.com/ksvij00/py2iso/main/installers/install.ps1" | iex
#
# Optional:
# $env:PY2ISO_HOME = "C:\tools\py2iso"
# ============================================================

$ErrorActionPreference = "Stop"

# ------------------------------------------------------------
# Configuration
# ------------------------------------------------------------

$RepoUrl = "https://github.com/ksvij00/py2iso.git"
$ZipUrl = "https://codeload.github.com/ksvij00/py2iso/zip/refs/heads/main"

$PythonVersion = "3.12.10"
$PythonInstallerUrl = "https://www.python.org/ftp/python/3.12.10/python-3.12.10-amd64.exe"

$InstallDir = if ($env:PY2ISO_HOME) {
    $env:PY2ISO_HOME
} else {
    Join-Path $env:LOCALAPPDATA "Programs\py2iso"
}

$ScriptPath = Join-Path $InstallDir "bin\p2i.py"
$CmdPath = Join-Path $InstallDir "p2i.cmd"

# ------------------------------------------------------------
# Output functions
# ------------------------------------------------------------

function Say {
    param([string]$Message)

    Write-Host "[PY2ISO] $Message" -ForegroundColor Cyan
}

function Info {
    param([string]$Message)

    Write-Host "         $Message" -ForegroundColor Gray
}

function Die {
    param([string]$Message)

    Write-Host ""
    Write-Host "[PY2ISO] ERROR: $Message" -ForegroundColor Red
    exit 1
}

function Show-Logo {
    Write-Host ""
    Write-Host "██████╗ ██╗   ██╗██████╗ ██╗███████╗ ██████╗" -ForegroundColor Cyan
    Write-Host "██╔══██╗╚██╗ ██╔╝╚════██╗██║██╔════╝██╔═══██╗" -ForegroundColor Cyan
    Write-Host "██████╔╝ ╚████╔╝ █████╔╝██║███████╗██║   ██║" -ForegroundColor Cyan
    Write-Host "██╔═══╝   ╚██╔╝  ██╔═══╝ ██║╚════██║██║   ██║" -ForegroundColor Cyan
    Write-Host "██║        ██║   ███████╗██║███████║╚██████╔╝" -ForegroundColor Cyan
    Write-Host "╚═╝        ╚═╝   ╚══════╝╚═╝╚══════╝ ╚═════╝" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Python to ISO installer for Windows" -ForegroundColor White
    Write-Host ""
}

# ------------------------------------------------------------
# Progress
# ------------------------------------------------------------

function Show-Progress {
    param(
        [int]$Step,
        [int]$Total,
        [string]$Message
    )

    $Percent = [math]::Min(
        100,
        [math]::Max(0, [int](($Step / $Total) * 100))
    )

    Write-Progress `
        -Activity "Installing PY2ISO" `
        -Status $Message `
        -PercentComplete $Percent
}

# ------------------------------------------------------------
# Platform check
# ------------------------------------------------------------

if ($env:OS -ne "Windows_NT") {
    Die "This installer requires Windows. Use install.sh on Linux or macOS."
}

# Enable TLS 1.2 for Windows PowerShell 5.1.
try {
    [Net.ServicePointManager]::SecurityProtocol = `
        [Net.ServicePointManager]::SecurityProtocol -bor `
        [Net.SecurityProtocolType]::Tls12
} catch {}

# ------------------------------------------------------------
# PATH handling
# ------------------------------------------------------------

function Refresh-Path {
    $MachinePath = [Environment]::GetEnvironmentVariable(
        "Path",
        [EnvironmentVariableTarget]::Machine
    )

    $UserPath = [Environment]::GetEnvironmentVariable(
        "Path",
        [EnvironmentVariableTarget]::User
    )

    $env:Path = @(
        $MachinePath
        $UserPath
        $env:Path
    ) -join ";"
}

function Add-UserPath {
    param([string]$NewPath)

    if (-not (Test-Path $NewPath)) {
        return
    }

    $UserPath = [Environment]::GetEnvironmentVariable(
        "Path",
        [EnvironmentVariableTarget]::User
    )

    $Entries = @($UserPath -split ";" | Where-Object { $_ })

    foreach ($Entry in $Entries) {
        if ($Entry.TrimEnd("\") -ieq $NewPath.TrimEnd("\")) {
            return
        }
    }

    $Entries += $NewPath

    [Environment]::SetEnvironmentVariable(
        "Path",
        ($Entries -join ";"),
        [EnvironmentVariableTarget]::User
    )

    if ($env:Path -notlike "*$NewPath*") {
        $env:Path = "$NewPath;$env:Path"
    }
}

# ------------------------------------------------------------
# Python detection
# ------------------------------------------------------------

function Test-Python {
    param(
        [string]$Exe,
        [string[]]$Args = @()
    )

    if (-not $Exe) {
        return $null
    }

    try {
        $Output = & $Exe @Args -c "import sys; print('%s.%s.%s' % sys.version_info[:3])" 2>$null

        if ($LASTEXITCODE -ne 0) {
            return $null
        }

        $VersionText = ($Output | Select-Object -Last 1).ToString().Trim()

        if ($VersionText -notmatch '^\d+\.\d+\.\d+$') {
            return $null
        }

        $Version = [version]$VersionText

        if ($Version -lt [version]"3.10.0") {
            return $null
        }

        return [PSCustomObject]@{
            Exe     = $Exe
            Args    = @($Args)
            Version = $VersionText
        }
    }
    catch {
        return $null
    }
}

function Get-Python {
    Refresh-Path

    # Python launcher.
    $Launcher = Get-Command "py.exe" -ErrorAction SilentlyContinue

    if ($Launcher) {
        $Result = Test-Python -Exe $Launcher.Source -Args @("-3")

        if ($Result) {
            return $Result
        }
    }

    # Python in PATH.
    $Commands = Get-Command "python.exe" -All -ErrorAction SilentlyContinue

    foreach ($Command in $Commands) {
        $Exe = $Command.Source

        if (-not $Exe) {
            continue
        }

        # Ignore Microsoft Store aliases.
        if ($Exe -match "\\WindowsApps\\") {
            continue
        }

        $Result = Test-Python -Exe $Exe

        if ($Result) {
            return $Result
        }
    }

    # Per-user Python installations.
    $LocalPython = Join-Path $env:LOCALAPPDATA "Programs\Python"

    if (Test-Path $LocalPython) {
        $Candidates = Get-ChildItem $LocalPython -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending

        foreach ($Directory in $Candidates) {
            $Exe = Join-Path $Directory.FullName "python.exe"

            if (Test-Path $Exe) {
                $Result = Test-Python -Exe $Exe

                if ($Result) {
                    return $Result
                }
            }
        }
    }

    return $null
}

# ------------------------------------------------------------
# Download helper
# ------------------------------------------------------------

function Download-File {
    param(
        [string]$Url,
        [string]$Destination
    )

    for ($Attempt = 1; $Attempt -le 3; $Attempt++) {
        Say "Downloading (attempt $Attempt/3)..."

        Remove-Item $Destination -Force -ErrorAction SilentlyContinue

        try {
            Invoke-WebRequest `
                -Uri $Url `
                -OutFile $Destination `
                -UseBasicParsing `
                -TimeoutSec 180 `
                -ErrorAction Stop

            if (
                (Test-Path $Destination) -and
                (Get-Item $Destination).Length -gt 0
            ) {
                return $true
            }
        }
        catch {
            Say "PowerShell download failed. Trying curl.exe..."

            $Curl = Get-Command "curl.exe" -ErrorAction SilentlyContinue

            if ($Curl) {
                $CurlOut = Join-Path $env:TEMP "py2iso-curl-out.txt"
                $CurlErr = Join-Path $env:TEMP "py2iso-curl-err.txt"

                try {
                    $Process = Start-Process `
                        -FilePath $Curl.Source `
                        -ArgumentList @(
                            "-fL",
                            "--connect-timeout", "20",
                            "--max-time", "300",
                            "--retry", "2",
                            "`"$Url`"",
                            "-o",
                            "`"$Destination`""
                        ) `
                        -Wait `
                        -PassThru `
                        -NoNewWindow `
                        -RedirectStandardOutput $CurlOut `
                        -RedirectStandardError $CurlErr

                    if (
                        $Process.ExitCode -eq 0 -and
                        (Test-Path $Destination) -and
                        (Get-Item $Destination).Length -gt 0
                    ) {
                        Remove-Item $CurlOut, $CurlErr -Force -ErrorAction SilentlyContinue
                        return $true
                    }
                }
                catch {
                    Say "curl.exe failed: $($_.Exception.Message)"
                }
                finally {
                    Remove-Item $CurlOut, $CurlErr -Force -ErrorAction SilentlyContinue
                }
            }
        }

        Remove-Item $Destination -Force -ErrorAction SilentlyContinue

        if ($Attempt -lt 3) {
            Start-Sleep -Seconds 3
        }
    }

    return $false
}

# ------------------------------------------------------------
# Install Python
# ------------------------------------------------------------

function Install-Python {
    $PythonDir = Join-Path $env:LOCALAPPDATA "Programs\Python\Python312"
    $PythonExe = Join-Path $PythonDir "python.exe"
    $Installer = Join-Path $env:TEMP "py2iso-python-installer.exe"

    Say "Python 3.10+ not found."
    Say "Installing Python $PythonVersion..."

    if (-not (Download-File -Url $PythonInstallerUrl -Destination $Installer)) {
        Die "Could not download Python. Check your internet connection."
    }

    try {
        Say "Running Python installer..."

        $Process = Start-Process `
            -FilePath $Installer `
            -ArgumentList @(
                "/quiet",
                "InstallAllUsers=0",
                "PrependPath=0",
                "Include_test=0",
                "TargetDir=`"$PythonDir`""
            ) `
            -Wait `
            -PassThru

        if ($Process.ExitCode -ne 0) {
            Die "Python installer failed with exit code $($Process.ExitCode)."
        }

        if (-not (Test-Path $PythonExe)) {
            Die "Python installation finished, but python.exe was not found at $PythonExe"
        }

        $Result = Test-Python -Exe $PythonExe

        if (-not $Result) {
            Die "Python was installed but failed the version check."
        }

        Add-UserPath $PythonDir
        Add-UserPath (Join-Path $PythonDir "Scripts")

        Say "Python successfully installed: $($Result.Version)"

        return $Result
    }
    finally {
        Remove-Item $Installer -Force -ErrorAction SilentlyContinue
    }
}

# ------------------------------------------------------------
# Install repository
# ------------------------------------------------------------

function Install-Repository {
    $TempRoot = Join-Path $env:TEMP (
        "py2iso-" + [guid]::NewGuid().ToString("N")
    )

    $SourceDir = Join-Path $TempRoot "source"

    New-Item -ItemType Directory -Path $TempRoot -Force | Out-Null

    try {
        $Git = Get-Command "git.exe" -ErrorAction SilentlyContinue
        $GitSuccess = $false

        # Try Git first.
        if ($Git) {
            Say "Git found. Cloning repository..."

            $GitOut = Join-Path $TempRoot "git-output.txt"
            $GitErr = Join-Path $TempRoot "git-error.txt"

            try {
                $Process = Start-Process `
                    -FilePath $Git.Source `
                    -ArgumentList @(
                        "clone",
                        "--depth",
                        "1",
                        "`"$RepoUrl`"",
                        "`"$SourceDir`""
                    ) `
                    -Wait `
                    -PassThru `
                    -NoNewWindow `
                    -RedirectStandardOutput $GitOut `
                    -RedirectStandardError $GitErr

                if (
                    $Process.ExitCode -eq 0 -and
                    (Test-Path (Join-Path $SourceDir "bin\p2i.py"))
                ) {
                    $GitSuccess = $true
                    Say "Repository cloned successfully."
                }
                else {
                    Say "Git clone failed. Switching to HTTPS download..."
                }
            }
            catch {
                Say "Git clone failed: $($_.Exception.Message)"
                Say "Switching to HTTPS download..."
            }
        }
        else {
            Say "Git not found. Using HTTPS download..."
        }

        # HTTPS ZIP fallback.
        if (-not $GitSuccess) {
            $ZipFile = Join-Path $TempRoot "py2iso.zip"

            if (-not (Download-File -Url $ZipUrl -Destination $ZipFile)) {
                Die "Could not download the PY2ISO repository."
            }

            Say "Extracting repository..."

            Expand-Archive `
                -Path $ZipFile `
                -DestinationPath $TempRoot `
                -Force

            $SourceDir = Join-Path $TempRoot "py2iso-main"

            if (-not (Test-Path (Join-Path $SourceDir "bin\p2i.py"))) {
                Die "The downloaded repository does not contain bin\p2i.py."
            }
        }

        # Verify source.
        if (-not (Test-Path (Join-Path $SourceDir "bin\p2i.py"))) {
            Die "Repository is missing bin\p2i.py."
        }

        Say "Installing PY2ISO files..."

        New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null

        Copy-Item `
            -Path (Join-Path $SourceDir "*") `
            -Destination $InstallDir `
            -Recurse `
            -Force

        if (-not (Test-Path $ScriptPath)) {
            Die "Installation failed. p2i.py was not found."
        }
    }
    finally {
        Remove-Item $TempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ------------------------------------------------------------
# Add PY2ISO to PATH
# ------------------------------------------------------------

function Add-InstallPath {
    Add-UserPath $InstallDir
}

# ------------------------------------------------------------
# Create CMD launcher
# ------------------------------------------------------------

function Create-CmdLauncher {
    param($Python)

    $PythonCommand = '"' + $Python.Exe + '"'
    $PythonArguments = ""

    if ($Python.Args.Count -gt 0) {
        $PythonArguments = " " + ($Python.Args -join " ")
    }

    $Launcher = @"
@echo off
$PythonCommand$PythonArguments "%~dp0bin\p2i.py" %*
"@

    Set-Content `
        -Path $CmdPath `
        -Value $Launcher `
        -Encoding ASCII

    Say "Created p2i.cmd"
}

# ------------------------------------------------------------
# MAIN
# ------------------------------------------------------------

Show-Logo

Show-Progress 1 5 "Checking Python"

$Python = Get-Python

if (-not $Python) {
    $Python = Install-Python
}

if (-not $Python) {
    Die "Could not find or install Python 3.10+."
}

$PythonExe = $Python.Exe
$PythonArgs = @($Python.Args)

Say "Using Python: $PythonExe"
Say "Python version: $($Python.Version)"

Show-Progress 2 5 "Downloading PY2ISO"

Install-Repository

Show-Progress 3 5 "Configuring PATH"

Add-InstallPath

Show-Progress 4 5 "Creating launcher"

Create-CmdLauncher -Python $Python

Show-Progress 5 5 "Finishing installation"

# ------------------------------------------------------------
# Immediate PowerShell function
# ------------------------------------------------------------

$global:PY2ISO_PYTHON = $PythonExe
$global:PY2ISO_PYTHON_ARGS = @($PythonArgs)
$global:PY2ISO_SCRIPT = $ScriptPath

function global:p2i {
    & $global:PY2ISO_PYTHON @global:PY2ISO_PYTHON_ARGS $global:PY2ISO_SCRIPT @args
}

Write-Progress -Activity "Installing PY2ISO" -Completed

Write-Host ""
Write-Host "============================================" -ForegroundColor Green
Write-Host "          PY2ISO INSTALLED" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Green
Write-Host ""
Write-Host "Install directory: $InstallDir"
Write-Host "Python:            $PythonExe"
Write-Host ""
Write-Host "Run:"
Write-Host ""
Write-Host "    p2i --help" -ForegroundColor Cyan
Write-Host ""
Write-Host "The p2i command is available in this PowerShell session."
Write-Host "Open a new terminal to use p2i from CMD or other shells."
Write-Host ""
```
