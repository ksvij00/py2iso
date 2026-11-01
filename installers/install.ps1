```powershell
# PY2ISO installer for Windows (PowerShell 5.1 / 7+)
# irm https://raw.githubusercontent.com/ksvij00/py2iso/main/installers/install.ps1 | iex

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$Repo = "https://github.com/ksvij00/py2iso.git"
$ZipUrl = "https://codeload.github.com/ksvij00/py2iso/zip/refs/heads/main"
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
# Requirements
# --------------------------------------------------

Progress 1 6 "Checking dependencies"

# Enable TLS 1.2 for Windows PowerShell 5.1.
try {
    [Net.ServicePointManager]::SecurityProtocol = `
        [Net.ServicePointManager]::SecurityProtocol -bor `
        [Net.SecurityProtocolType]::Tls12
} catch {}

# Check Python.
if (Get-Command py -ErrorAction SilentlyContinue) {
    $PyExe = "py"
    $PyArgs = @("-3")
} elseif (Get-Command python -ErrorAction SilentlyContinue) {
    $PyExe = "python"
    $PyArgs = @()
} else {
    Die "Python 3.10+ is required. Install: winget install Python.Python.3.12"
}

& $PyExe @PyArgs -c `
    "import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)" `
    *> $null

if ($LASTEXITCODE -ne 0) {
    Die "Python 3.10 or newer is required."
}

# --------------------------------------------------
# Temporary directory
# --------------------------------------------------

$Tmp = Join-Path ([IO.Path]::GetTempPath()) (
    "py2iso-" + [Guid]::NewGuid().ToString("N")
)

try {
    $null = New-Item -ItemType Directory -Path $Tmp -Force

    $Src = $null

    # --------------------------------------------------
    # Download repository
    # --------------------------------------------------

    Progress 2 6 "Downloading repository"

    if (Get-Command git -ErrorAction SilentlyContinue) {

        Say "Using Git"

        $GitDir = Join-Path $Tmp "repo"

        & git clone --depth 1 $Repo $GitDir *> $null

        if ($LASTEXITCODE -eq 0) {
            $Src = Join-Path $GitDir $File
        } else {
            Say "Git clone failed. Switching to HTTPS download."
        }
    }

    # --------------------------------------------------
    # HTTPS fallback
    # --------------------------------------------------

    if (-not $Src -or -not (Test-Path -LiteralPath $Src -PathType Leaf)) {

        Say "Using HTTPS download"

        $ZipPath = Join-Path $Tmp "py2iso.zip"
        $ExtractPath = Join-Path $Tmp "extract"

        try {
            Invoke-WebRequest `
                -Uri $ZipUrl `
                -OutFile $ZipPath `
                -UseBasicParsing `
                -ErrorAction Stop

            Expand-Archive `
                -LiteralPath $ZipPath `
                -DestinationPath $ExtractPath `
                -Force

            $Src = Join-Path $ExtractPath "py2iso-main\$File"

        } catch {
            Die "HTTPS download failed: $($_.Exception.Message)"
        }
    }

    if (-not (Test-Path -LiteralPath $Src -PathType Leaf)) {
        Die "$File was not found in the downloaded repository."
    }

    # --------------------------------------------------
    # Install
    # --------------------------------------------------

    Progress 3 6 "Installing PY2ISO"

    $null = New-Item -ItemType Directory -Force -Path $Dir

    Copy-Item `
        -LiteralPath $Src `
        -Destination (Join-Path $Dir "p2i.py") `
        -Force

    # --------------------------------------------------
    # Create CMD launcher
    # --------------------------------------------------

    Progress 4 6 "Creating command launcher"

    $Run = if ($PyExe -eq "py") {
        "py -3"
    } else {
        "python"
    }

    $Shim = "@echo off`r`n$Run ""%~dp0p2i.py"" %*`r`n"

    [IO.File]::WriteAllText(
        (Join-Path $Dir "$Cmd.cmd"),
        $Shim,
        [Text.Encoding]::ASCII
    )

    # --------------------------------------------------
    # Configure persistent PATH
    # --------------------------------------------------

    Progress 5 6 "Configuring PATH"

    $UserPath = [Environment]::GetEnvironmentVariable("Path", "User")

    if (-not $UserPath) {
        $UserPath = ""
    }

    $Entries = @(
        $UserPath -split ";" |
        Where-Object { $_.Trim() -ne "" }
    )

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

    # Update current session PATH.
    if (-not (($env:Path -split ";") | Where-Object {
        [string]::Equals(
            $_.TrimEnd("\"),
            $Dir.TrimEnd("\"),
            [StringComparison]::OrdinalIgnoreCase
        )
    })) {
        $env:Path = $env:Path.TrimEnd(";") + ";" + $Dir
    }

    # --------------------------------------------------
    # Register immediate PowerShell command
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
    Say "Download method: $(if (Get-Command git -ErrorAction SilentlyContinue) { 'Git / HTTPS fallback' } else { 'HTTPS' })"
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
```
