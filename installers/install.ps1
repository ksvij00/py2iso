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

function Progress([int]$Current, [int]$Total, [string]$Label) {
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
# TLS and PATH
# --------------------------------------------------

try {
    [Net.ServicePointManager]::SecurityProtocol = `
        [Net.ServicePointManager]::SecurityProtocol -bor `
        [Net.SecurityProtocolType]::Tls12
} catch {}

function Refresh-Path {
    $Machine = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $User = [Environment]::GetEnvironmentVariable("Path", "User")

    $env:Path = @($Machine, $User) -join ";"

    $ExtraPaths = @(
        "$env:ProgramFiles\Git\cmd",
        "$env:LOCALAPPDATA\Programs\Git\cmd",
        "$env:LOCALAPPDATA\Programs\Python\Python312",
        "$env:LOCALAPPDATA\Programs\Python\Python312\Scripts",
        "$env:LOCALAPPDATA\Programs\Python\Python314",
        "$env:LOCALAPPDATA\Programs\Python\Python314\Scripts"
    )

    foreach ($Entry in $ExtraPaths) {
        if ((Test-Path $Entry) -and
            (($env:Path -split ";") -notcontains $Entry)) {
            $env:Path += ";$Entry"
        }
    }
}

# --------------------------------------------------
# Python detection
# --------------------------------------------------

function Get-Python {
    $Candidates = @()

    if (Get-Command py -ErrorAction SilentlyContinue) {
        $Candidates += @{ Exe = "py"; Args = @("-3") }
    }

    if (Get-Command python -ErrorAction SilentlyContinue) {
        $Candidates += @{ Exe = "python"; Args = @() }
    }

    foreach ($Candidate in $Candidates) {
        & $Candidate.Exe @($Candidate.Args) -c `
            "import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)" `
            *> $null

        if ($LASTEXITCODE -eq 0) {
            return $Candidate
        }
    }

    return $null
}

# --------------------------------------------------
# Python installation
# --------------------------------------------------

function Install-Python {
    Say "Python 3.10+ not found. Installing Python..."

    $Winget = Get-Command winget -ErrorAction SilentlyContinue

    if ($Winget) {
        Say "Using WinGet"

        & winget install `
            --id Python.Python.3.14 `
            --exact `
            --scope user `
            --silent `
            --accept-package-agreements `
            --accept-source-agreements `
            --disable-interactivity *> $null

        Refresh-Path

        $Python = Get-Python

        if ($Python) {
            Say "Python installed successfully."
            return $Python
        }

        Say "WinGet installation unavailable. Trying official HTTPS installer."
    }

    # Official Python installer fallback.
    $Architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()

    switch ($Architecture) {
        "X64" {
            $PythonUrl = "https://www.python.org/ftp/python/3.12.10/python-3.12.10-amd64.exe"
        }
        "Arm64" {
            $PythonUrl = "https://www.python.org/ftp/python/3.12.10/python-3.12.10-arm64.exe"
        }
        "X86" {
            $PythonUrl = "https://www.python.org/ftp/python/3.12.10/python-3.12.10.exe"
        }
        default {
            Die "Unsupported Windows architecture: $Architecture"
        }
    }

    $Installer = Join-Path ([IO.Path]::GetTempPath()) "py2iso-python-installer.exe"

    try {
        Say "Downloading Python from python.org"

        Invoke-WebRequest `
            -Uri $PythonUrl `
            -OutFile $Installer `
            -UseBasicParsing

        Say "Installing Python silently"

        $Process = Start-Process `
            -FilePath $Installer `
            -ArgumentList @(
                "/quiet",
                "InstallAllUsers=0",
                "PrependPath=1",
                "Include_launcher=1",
                "Include_pip=1",
                "Include_test=0"
            ) `
            -Wait `
            -PassThru

        if ($Process.ExitCode -notin @(0, 3010)) {
            Die "Python installation failed. Exit code: $($Process.ExitCode)"
        }
    }
    finally {
        Remove-Item $Installer -Force -ErrorAction SilentlyContinue
    }

    Refresh-Path

    $Python = Get-Python

    if (-not $Python) {
        Die "Python installation completed, but Python 3.10+ could not be detected. Restart PowerShell and retry."
    }

    Say "Python installed successfully."

    return $Python
}

# --------------------------------------------------
# Main installation
# --------------------------------------------------

$Tmp = Join-Path ([IO.Path]::GetTempPath()) (
    "py2iso-" + [Guid]::NewGuid().ToString("N")
)

try {
    Progress 1 6 "Checking dependencies"

    $Python = Get-Python

    if (-not $Python) {
        $Python = Install-Python
    }

    $PyExe = $Python.Exe
    $PyArgs = @($Python.Args)

    # --------------------------------------------------
    # Download repository
    # --------------------------------------------------

    Progress 2 6 "Downloading repository"

    $null = New-Item -ItemType Directory -Path $Tmp -Force

    $Src = $null

    if (Get-Command git -ErrorAction SilentlyContinue) {
        $GitDir = Join-Path $Tmp "repo"

        & git clone --depth 1 $Repo $GitDir *> $null

        if ($LASTEXITCODE -eq 0) {
            $Src = Join-Path $GitDir $File
        } else {
            Say "Git failed. Switching to HTTPS."
        }
    } else {
        Say "Git not found. Using HTTPS."
    }

    # --------------------------------------------------
    # HTTPS fallback
    # --------------------------------------------------

    if (-not $Src -or -not (Test-Path -LiteralPath $Src -PathType Leaf)) {
        $ZipPath = Join-Path $Tmp "py2iso.zip"
        $ExtractPath = Join-Path $Tmp "extract"

        try {
            Invoke-WebRequest `
                -Uri $ZipUrl `
                -OutFile $ZipPath `
                -UseBasicParsing

            Expand-Archive `
                -LiteralPath $ZipPath `
                -DestinationPath $ExtractPath `
                -Force

            $Src = Join-Path $ExtractPath "py2iso-main\$File"
        } catch {
            Die "Repository HTTPS download failed: $($_.Exception.Message)"
        }
    }

    if (-not (Test-Path -LiteralPath $Src -PathType Leaf)) {
        Die "$File not found in repository."
    }

    # --------------------------------------------------
    # Install
    # --------------------------------------------------

    Progress 3 6 "Installing PY2ISO"

    $null = New-Item -ItemType Directory -Force -Path $Dir

    Copy-Item -LiteralPath $Src `
        -Destination (Join-Path $Dir "p2i.py") -Force

    # --------------------------------------------------
    # CMD launcher
    # --------------------------------------------------

    Progress 4 6 "Creating command launcher"

    $Run = if ($PyExe -eq "py") { "py -3" } else { "python" }

    $Shim = "@echo off`r`n$Run ""%~dp0p2i.py"" %*`r`n"

    [IO.File]::WriteAllText(
        (Join-Path $Dir "$Cmd.cmd"),
        $Shim,
        [Text.Encoding]::ASCII
    )

    # --------------------------------------------------
    # PATH
    # --------------------------------------------------

    Progress 5 6 "Configuring PATH"

    $UserPath = [Environment]::GetEnvironmentVariable("Path", "User")

    if (-not $UserPath) {
        $UserPath = ""
    }

    $Exists = $false

    foreach ($Entry in ($UserPath -split ";")) {
        if ([string]::Equals(
            $Entry.Trim().TrimEnd("\"),
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

        [Environment]::SetEnvironmentVariable("Path", $NewPath, "User")
    }

    if (-not (($env:Path -split ";") | Where-Object {
        [string]::Equals(
            $_.Trim().TrimEnd("\"),
            $Dir.TrimEnd("\"),
            [StringComparison]::OrdinalIgnoreCase
        )
    })) {
        $env:Path = $env:Path.TrimEnd(";") + ";" + $Dir
    }

    # --------------------------------------------------
    # Immediate PowerShell function
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
    Say "Python: verified"
    Say "Git: optional"
    Say "Location: $Dir"
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
