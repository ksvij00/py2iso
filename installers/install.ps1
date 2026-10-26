# py2iso installer for Windows (PowerShell 5.1 or 7+).
#   irm https://raw.githubusercontent.com/ksvij00/py2iso/main/install.ps1 | iex
# Optional: $env:PY2ISO_HOME = "C:\tools\py2iso"   (default: %USERPROFILE%\py2iso)
$ErrorActionPreference = "Stop"

$Repo = "https://github.com/ksvij00/py2iso.git"
$File = "bin/p2i.py"
$Dir  = if ($env:PY2ISO_HOME) { $env:PY2ISO_HOME } else { Join-Path $HOME "py2iso" }
$Cmd  = "p2i"

function Say($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Die($m) { Write-Host "error: $m" -ForegroundColor Red; throw $m }

if (-not (Get-Command git -ErrorAction SilentlyContinue)) { Die "git is required (winget install Git.Git)" }

if (Get-Command py -ErrorAction SilentlyContinue)         { $pyExe = "py";     $pyArgs = @("-3") }
elseif (Get-Command python -ErrorAction SilentlyContinue) { $pyExe = "python"; $pyArgs = @() }
else { Die "Python 3.10+ is required (winget install Python.Python.3.12)" }

& $pyExe @pyArgs -c "import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)"
if ($LASTEXITCODE -ne 0) { Die "Python 3.10 or newer is required" }

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("py2iso-" + [Guid]::NewGuid().ToString("N"))
try {
    Say "Cloning $Repo"
    $prev = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    git clone --depth 1 $Repo $tmp
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prev
    if ($code -ne 0) { Die "clone failed (while the repo is private, sign in to GitHub when git asks)" }

    $src = Join-Path $tmp $File
    if (-not (Test-Path $src)) { Die "$File not found in the repository" }

    New-Item -ItemType Directory -Force -Path $Dir | Out-Null
    Copy-Item $src (Join-Path $Dir "p2i.py") -Force
    Say "Installed $(Join-Path $Dir 'p2i.py')"
}
finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

# p2i.cmd works in both cmd.exe and PowerShell (the Windows equivalent of the .bashrc link)
if ($pyExe -eq "py") { $run = "py -3" } else { $run = "python" }
$shim = "@echo off`r`n$run ""%~dp0p2i.py"" %*`r`n"
Set-Content -Path (Join-Path $Dir "$Cmd.cmd") -Value $shim -Encoding Ascii -NoNewline

$user = [Environment]::GetEnvironmentVariable("Path", "User")
if (-not $user) { $user = "" }
if (($user -split ";") -notcontains $Dir) {
    $new = if ($user) { $user.TrimEnd(";") + ";" + $Dir } else { $Dir }
    [Environment]::SetEnvironmentVariable("Path", $new, "User")
    Say "Added $Dir to your PATH"
}
$env:Path += ";$Dir"

Say "Done. Open a new terminal, then try:  $Cmd cook .\myproj"
