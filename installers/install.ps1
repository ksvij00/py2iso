```powershell
# py2iso installer for Windows (PowerShell 5.1 or 7+).
# Usage:
#   irm https://raw.githubusercontent.com/ksvij00/py2iso/main/installers/install.ps1 | iex
#
# Optional:
#   $env:PY2ISO_HOME = "C:\tools\py2iso"

$ErrorActionPreference = "Stop"

$Repo = "https://github.com/ksvij00/py2iso.git"
$File = "bin/p2i.py"
$Dir = if ($env:PY2ISO_HOME) {
    $env:PY2ISO_HOME
} else {
    Join-Path $HOME "py2iso"
}
$Cmd = "p2i"

# --------------------------------------------------
# Logo
# --------------------------------------------------

Write-Host ""
Write-Host "██████╗ ██╗   ██╗██████╗ ██╗███████╗ ██████╗"
Write-Host "██╔══██╗╚██╗ ██╔╝╚════██╗██║██╔════╝██╔═══██╗"
Write-Host "██████╔╝ ╚████╔╝  █████╔╝██║███████╗██║   ██║"
Write-Host "██╔═══╝   ╚██╔╝  ██╔═══╝ ██║╚════██║██║   ██║"
Write-Host "██║        ██║   ███████╗██║███████║╚██████╔╝"
Write-Host "╚═╝        ╚═╝   ╚══════╝╚═╝╚══════╝ ╚═════╝"
Write-Host ""

function Say([string]$Message) {
    Write-Host "[PY2ISO] " -ForegroundColor Green -NoNewline
    Write-Host $Message
}

function Die([string]$Message) {
    Write-Host "[ERROR] $Message" -ForegroundColor Red
    throw $Message
}

# --------------------------------------------------
# Progress bar
# --------------------------------------------------

function Progress(
    [int]$Current,
    [int]$Total,
    [string]$Label
) {
    $Width = 30
    $Filled = [int][Math]::Floor($Current * $Width / $Total)
    $Empty = $Width - $Filled
    $Percent = [int][Math]::Floor($Current * 100 / $Total)

    $Bar = ("#" * $Filled) + ("-" * $Empty)

    Write-Host "`r[$Bar] $($Percent.ToString().PadLeft(3))% $Label".PadRight(90) -NoNewline

    if ($Current -ge $Total) {
        Write-Host ""
    }
}

# --------------------------------------------------
# Requirements
# --------------------------------------------------

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Die "Git is required. Install it with: winget install Git.Git"
}

if (Get-Command py -ErrorAction SilentlyContinue) {
    $PyExe = "py"
    $PyArgs = @("-3")
} elseif (Get-Command python -ErrorAction SilentlyContinue) {
    $PyExe = "python"
    $PyArgs = @()
} else {
    Die "Python 3.10+ is required. Install it with: winget install Python.Python.3.12"
}

& $PyExe @PyArgs -c "import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)" 2>$null 1>$null

if ($LASTEXITCODE -ne 0) {
    Die "Python 3.10 or newer is required."
}

# Resolve Python to a usable command for the shim.
$Run = if ($PyExe -eq "py") { "py -3" } else { "python" }

# --------------------------------------------------
# Temporary directory and cleanup
# --------------------------------------------------

$Tmp = Join-Path ([IO.Path]::GetTempPath()) ("py2iso-" + [Guid]::NewGuid().ToString("N"))

try {
    Progress 1 5 "Cloning repository"

    $null = New-Item -ItemType Directory -Path $Tmp -Force

    # Suppress Git output while preserving its exit code.
    & git clone --depth 1 $Repo $Tmp 2>$null 1>$null

    if ($LASTEXITCODE -ne 0) {
        Die "Clone failed. Check network access and repository visibility."
    }

    $Src = Join-Path $Tmp $File

    if (-not (Test-Path -LiteralPath $Src -PathType Leaf)) {
        Die "$File not found in the repository."
    }

    Progress 2 5 "Preparing installation"

    $null = New-Item -ItemType Directory -Force -Path $Dir

    Copy-Item -LiteralPath $Src -Destination (Join-Path $Dir "p2i.py") -Force

    Progress 3 5 "Creating command launcher"

    # cmd.exe launcher
    $Shim = "@echo off`r`n$Run ""%~dp0p2i.py"" %*`r`n"
    $ShimPath = Join-Path $Dir "$Cmd.cmd"

    [IO.File]::WriteAllText(
        $ShimPath,
        $Shim,
        [Text.Encoding]::ASCII
    )

    # --------------------------------------------------
    # Add installation directory to persistent user PATH
    # --------------------------------------------------

    Progress 4 5 "Configuring PATH"

    $UserPath = [Environment]::GetEnvironmentVariable("Path", "User")

    if (-not $UserPath) {
        $UserPath = ""
    }

    $PathEntries = @(
        $UserPath -split ";" |
        Where-Object { $_.Trim() -ne "" }
    )

    $AlreadyPresent = $false

    foreach ($Entry in $PathEntries) {
        if ([string]::Equals(
            $Entry.TrimEnd("\"),
            $Dir.TrimEnd("\"),
            [StringComparison]::OrdinalIgnoreCase
        )) {
            $AlreadyPresent = $true
            break
        }
    }

    if (-not $AlreadyPresent) {
        $NewPath = if ($UserPath.Trim()) {
            $UserPath.TrimEnd(";") + ";" + $Dir
        } else {
            $Dir
        }

        [Environment]::SetEnvironmentVariable("Path", $NewPath, "User")
        Say "Added installation directory to user PATH"
    }

    # Make p2i available immediately in this PowerShell session.
    if (-not (($env:Path -split ";") | Where-Object {
        [string]::Equals(
            $_.TrimEnd("\"),
            $Dir.TrimEnd("\"),
            [StringComparison]::OrdinalIgnoreCase
        )
    })) {
        $env:Path = $env:Path.TrimEnd(";") + ";" + $Dir
    }

    # PowerShell function: works immediately, including paths with spaces.
    $P2iScript = Join-Path $Dir "p2i.py"
    $P2iExe = $PyExe
    $P2iArgs = @($PyArgs)

    Set-Item -Path Function:global:p2i -Value {
        & $P2iExe @P2iArgs $P2iScript @args
    }.GetNewClosure()

    Progress 5 5 "Installation complete"

    Write-Host ""
    Say "PY2ISO installed successfully."
    Say "Location: $Dir"
    Say "Command: p2i"
    Write-Host ""
    Say "Try: p2i cook .\myproj"
    Write-Host ""
}
finally {
    if (Test-Path -LiteralPath $Tmp) {
        Remove-Item -LiteralPath $Tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}
```
