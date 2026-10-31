
# PY2ISO installer for Windows (PowerShell 5.1 / 7+)
# irm https://raw.githubusercontent.com/ksvij00/py2iso/main/installers/install.ps1 | iex

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
# Progress
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

    Write-Host (
        "`r[$Bar] $($Percent.ToString().PadLeft(3))% $Label".PadRight(90)
    ) -NoNewline

    if ($Current -ge $Total) {
        Write-Host ""
    }
}

# --------------------------------------------------
# Refresh PATH
# --------------------------------------------------

function Refresh-Path {
    $MachinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $UserPath = [Environment]::GetEnvironmentVariable("Path", "User")

    $env:Path = @($MachinePath, $UserPath) -join ";"

    $GitPaths = @(
        "$env:ProgramFiles\Git\cmd",
        "$env:ProgramFiles\Git\bin",
        "$env:LOCALAPPDATA\Programs\Git\cmd",
        "$env:LOCALAPPDATA\Programs\Git\bin"
    )

    foreach ($PathEntry in $GitPaths) {
        if ((Test-Path $PathEntry) -and
            (($env:Path -split ";") -notcontains $PathEntry)) {
            $env:Path += ";$PathEntry"
        }
    }
}

# --------------------------------------------------
# Git installation
# --------------------------------------------------

function Ensure-Git {
    if (Get-Command git -ErrorAction SilentlyContinue) {
        return
    }

    Say "Git not found. Installing Git..."

    $Winget = Get-Command winget -ErrorAction SilentlyContinue

    if (-not $Winget) {
        Die "WinGet is unavailable. Install App Installer from Microsoft Store, then rerun this installer."
    }

    & winget install --id Git.Git --exact `
        --silent `
        --accept-package-agreements `
        --accept-source-agreements `
        --disable-interactivity *> $null

    $InstallCode = $LASTEXITCODE

    Refresh-Path

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Die "Git installation failed (exit code: $InstallCode). Restart PowerShell and retry."
    }

    Say "Git installed successfully."
}

# --------------------------------------------------
# Requirements
# --------------------------------------------------

Progress 1 6 "Checking dependencies"

Ensure-Git

if (Get-Command py -ErrorAction SilentlyContinue) {
    $PyExe = "py"
    $PyArgs = @("-3")
} elseif (Get-Command python -ErrorAction SilentlyContinue) {
    $PyExe = "python"
    $PyArgs = @()
} else {
    Die "Python 3.10+ is required. Install with: winget install Python.Python.3.12"
}

& $PyExe @PyArgs -c `
    "import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)" `
    *> $null

if ($LASTEXITCODE -ne 0) {
    Die "Python 3.10 or newer is required."
}

$Run = if ($PyExe -eq "py") { "py -3" } else { "python" }

# --------------------------------------------------
# Temporary directory
# --------------------------------------------------

$Tmp = Join-Path ([IO.Path]::GetTempPath()) (
    "py2iso-" + [Guid]::NewGuid().ToString("N")
)

try {
    # --------------------------------------------------
    # Clone
    # --------------------------------------------------

    Progress 2 6 "Cloning repository"

    $null = New-Item -ItemType Directory -Path $Tmp -Force

    & git clone --depth 1 $Repo $Tmp *> $null

    if ($LASTEXITCODE -ne 0) {
        Die "Git clone failed. Check network access and repository visibility."
    }

    $Src = Join-Path $Tmp $File

    if (-not (Test-Path -LiteralPath $Src -PathType Leaf)) {
        Die "$File not found in the repository."
    }

    # --------------------------------------------------
    # Install
    # --------------------------------------------------

    Progress 3 6 "Installing PY2ISO"

    $null = New-Item -ItemType Directory -Force -Path $Dir

    Copy-Item -LiteralPath $Src `
        -Destination (Join-Path $Dir "p2i.py") -Force

    # --------------------------------------------------
    # Command launcher
    # --------------------------------------------------

    Progress 4 6 "Creating command launcher"

    $Shim = "@echo off`r`n$Run ""%~dp0p2i.py"" %*`r`n"

    [IO.File]::WriteAllText(
        (Join-Path $Dir "$Cmd.cmd"),
        $Shim,
        [Text.Encoding]::ASCII
    )

    # --------------------------------------------------
    # User PATH
    # --------------------------------------------------

    Progress 5 6 "Configuring PATH"

    $UserPath = [Environment]::GetEnvironmentVariable("Path", "User")

    if (-not $UserPath) {
        $UserPath = ""
    }

    $Entries = @($UserPath -split ";" | Where-Object {
        $_.Trim() -ne ""
    })

    $Exists = $false

    foreach ($Entry in $Entries) {
        if ([string]::Equals(
            $Entry.TrimEnd("\"),
            $Dir.TrimEnd("\"),
            [StringComparison]::OrdinalIgnoreCase
        )) {
            $Exists = $true
            break
        }
    }

    if (-not $Exists) {
        $NewPath = if ($UserPath) {
            $UserPath.TrimEnd(";") + ";" + $Dir
        } else {
            $Dir
        }

        [Environment]::SetEnvironmentVariable(
            "Path",
            $NewPath,
            "User"
        )
    }

    if (-not (($env:Path -split ";") | Where-Object {
        [string]::Equals(
            $_.TrimEnd("\"),
            $Dir.TrimEnd("\"),
            [StringComparison]::OrdinalIgnoreCase
        )
    })) {
        $env:Path += ";$Dir"
    }

    # --------------------------------------------------
    # Immediate PowerShell command
    # --------------------------------------------------

    $P2iScript = Join-Path $Dir "p2i.py"
    $P2iExe = $PyExe
    $P2iPythonArgs = @($PyArgs)

    $P2iFunction = ({
        param(
            [Parameter(ValueFromRemainingArguments = $true)]
            [string[]]$Arguments
        )

        & $P2iExe @P2iPythonArgs $P2iScript @Arguments
    }).GetNewClosure()

    Set-Item -Path Function:\global:p2i -Value $P2iFunction

    # --------------------------------------------------
    # Complete
    # --------------------------------------------------

    Progress 6 6 "Installation complete"

    Write-Host ""
    Say "PY2ISO installed successfully."
    Say "Location: $Dir"
    Say "Git: installed and available"
    Say "Python: verified"
    Say "Command: p2i"
    Write-Host ""
    Say "Try: p2i cook .\myproj"
    Write-Host ""
}
finally {
    if (Test-Path -LiteralPath $Tmp) {
        Remove-Item -LiteralPath $Tmp -Recurse -Force `
            -ErrorAction SilentlyContinue
    }
}
