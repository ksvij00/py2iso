
# ============================================================
# PY2ISO Windows Installer
# PowerShell 5.1 / 7+
#
# Usage:
# irm https://raw.githubusercontent.com/ksvij00/py2iso/main/installers/install.ps1 | iex
#
# Optional install directory:
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
    #
    Join-Path $env:LOCALAPPDATA "Programs\py2iso"
}

$ScriptPath = Join-Path $InstallDir "bin\p2i.py"
$CmdPath = Join-Path $InstallDir "p2i.cmd"

# ------------------------------------------------------------
# Output helpers
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
# Progress bar
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
# Check Windows
# ------------------------------------------------------------

if ($env:OS -ne "Windows_NT") {
    Die "This installer requires Windows. Use install.sh on Linux or macOS."
}

# ------------------------------------------------------------
# Refresh PATH without discarding process entries
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

    # Prefer the Python launcher.
    $Launcher = Get-Command "py.exe" -ErrorAction SilentlyContinue

    if ($Launcher) {
        $Result = Test-Python -Exe $Launcher.Source -Args @("-3")

        if ($Result) {
            return $Result
        }
    }

    # Check Python available in PATH.
    $Commands = Get-Command "python.exe" -All -ErrorAction SilentlyContinue

    foreach ($Command in $Commands) {
        $Exe = $Command.Source

        if (-not $Exe) {
            continue
        }

        # Ignore Microsoft Store execution aliases.
        if ($Exe -match "\\WindowsApps\\") {
            continue
        }

        $Result = Test-Python -Exe $Exe

        if ($Result) {
            return $Result
        }
    }

    # Check common per-user installation directories.
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

    # Check standard Python.org installation directories.
    $ProgramFilesPython = Join-Path $env:ProgramFiles "Python"

    if (Test-Path $ProgramFilesPython) {
        $Candidates = Get-ChildItem $ProgramFilesPython -Directory -ErrorAction SilentlyContinue

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
# Download helper with retries
# ------------------------------------------------------------

function Download-File {
    param(
        [string]$Url,
        [string]$Destination
    )

    $Success = $false

    for ($Attempt = 1; $Attempt -le 3; $Attempt++) {
        try {
            Say "Downloading (attempt $Attempt/3)..."

            Remove-Item $Destination -Force -ErrorAction SilentlyContinue

            try {
                Invoke-WebRequest `
                    -Uri $Url `
                    -OutFile $Destination `
                    -UseBasicParsing `
                    -TimeoutSec 120

                $Success = Test-Path $Destination
            }
            catch {
                # Fall back to curl.exe if available.
                $Curl = Get-Command "curl.exe" -ErrorAction SilentlyContinue

                if (-not $Curl) {
                    throw
                }

                & $Curl.Source -fL --connect-timeout 20 --max-time 300 --retry 2 $Url -o $Destination

                if ($LASTEXITCODE -ne 0) {
                    throw "curl.exe exited with code $LASTEXITCODE"
                }

                $Success = Test-Path $Destination
            }

            if ($Success) {
                $File = Get-Item $Destination

                if ($File.Length -gt 0) {
                    return $true
                }
            }
        }
        catch {
            Say "Download attempt failed: $($_.Exception.Message)"
        }

        Start-Sleep -Seconds 2
    }

    return $false
}

# ------------------------------------------------------------
# Install Python
# ------------------------------------------------------------

function Install-Python {
    $InstallPythonDir = Join-Path $env:LOCALAPPDATA "Programs\Python\Python312"
    $PythonExe = Join-Path $InstallPythonDir "python.exe"

    $Installer = Join-Path $env:TEMP "py2iso-python-installer.exe"

    Say "Python 3.10+ not found."
    Say "Installing Python $PythonVersion..."

    if (-not (Download-File -Url $PythonInstallerUrl -Destination $Installer)) {
        Die "Could not download Python. Check your internet connection and try again."
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
                "TargetDir=`"$InstallPythonDir`""
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

        # Add Python to the current process PATH.
        $env:Path = "$InstallPythonDir;$InstallPythonDir\Scripts;$env:Path"

        # Add Python to persistent user PATH.
        $UserPath = [Environment]::GetEnvironmentVariable(
            "Path",
            [EnvironmentVariableTarget]::User
        )

        $Entries = @($UserPath -split ";" | Where-Object { $_ })

        foreach ($PathEntry in @(
            $InstallPythonDir,
            (Join-Path $InstallPythonDir "Scripts")
        )) {
            if (-not ($Entries | Where-Object {
                $_.TrimEnd("\") -ieq $PathEntry.TrimEnd("\")
            })) {
                $Entries += $PathEntry
            }
        }

        [Environment]::SetEnvironmentVariable(
            "Path",
            ($Entries -join ";"),
            [EnvironmentVariableTarget]::User
        )

        Say "Python successfully installed: $($Result.Version)"

        return $Result
    }
    finally {
        Remove-Item $Installer -Force -ErrorAction SilentlyContinue
    }
}

# ------------------------------------------------------------
# Download repository
# ------------------------------------------------------------

function Install-Repository {
    $TempRoot = Join-Path $env:TEMP ("py2iso-" + [guid]::NewGuid().ToString("N"))
    $SourceDir = Join-Path $TempRoot "source"

    New-Item -ItemType Directory -Path $TempRoot -Force | Out-Null

    try {
        $Git = Get-Command "git.exe" -ErrorAction SilentlyContinue

        $GitSuccess = $false

        if ($Git) {
            Say "Git found. Cloning repository..."

            & $Git.Source clone --depth 1 $RepoUrl $SourceDir *> $null

            if ($LASTEXITCODE -eq 0 -and (Test-Path (Join-Path $SourceDir "bin\p2i.py"))) {
                $GitSuccess = $true
            } else {
                Say "Git clone failed. Switching to HTTPS download..."
            }
        } else {
            Say "Git not found. Using HTTPS download..."
        }

        if (-not $GitSuccess) {
            $ZipFile = Join-Path $TempRoot "py2iso.zip"

            if (-not (Download-File -Url $ZipUrl -Destination $ZipFile)) {
                Die "Could not download the PY2ISO repository."
            }

            Say "Extracting repository..."

            Expand-Archive -Path $ZipFile -DestinationPath $TempRoot -Force

            $Extracted = Join-Path $TempRoot "py2iso-main"

            if (-not (Test-Path (Join-Path $Extracted "bin\p2i.py"))) {
                Die "The downloaded repository does not contain bin\p2i.py."
            }

            $SourceDir = $Extracted
        }

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
# Add install directory to user PATH
# ------------------------------------------------------------

function Add-InstallPath {
    $UserPath = [Environment]::GetEnvironmentVariable(
        "Path",
        [EnvironmentVariableTarget]::User
    )

    $Entries = @($UserPath -split ";" | Where-Object { $_ })

    $Exists = $false

    foreach ($Entry in $Entries) {
        if ($Entry.TrimEnd("\") -ieq $InstallDir.TrimEnd("\")) {
            $Exists = $true
            break
        }
    }

    if (-not $Exists) {
        $Entries += $InstallDir

        [Environment]::SetEnvironmentVariable(
            "Path",
            ($Entries -join ";"),
            [EnvironmentVariableTarget]::User
        )
    }

    if ($env:Path -notlike "*$InstallDir*") {
        $env:Path = "$InstallDir;$env:Path"
    }
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

    Set-Content -Path $CmdPath -Value $Launcher -Encoding ASCII

    Say "Created p2i.cmd"
}

# ------------------------------------------------------------
# Main installer
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
# Create immediate PowerShell command
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
Write-Host "You can now run:"
Write-Host ""
Write-Host "    p2i --help" -ForegroundColor Cyan
Write-Host ""
Write-Host "The p2i command is available in this PowerShell session."
Write-Host "Open a new terminal to use p2i from CMD or other shells."
