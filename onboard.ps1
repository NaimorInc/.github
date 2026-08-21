# NaimorInc/.github onboard.ps1 — public phase, Windows.
#
#   irm "https://raw.githubusercontent.com/NaimorInc/.github/refs/heads/main/onboard.ps1" | iex
#
# Job: get to an authenticated `gh` that can read naimor-dev-infra, then
# hand off to the real installer there. Does NOT set up WSL2, install an
# IDE, or install your dotfiles itself -- that's
# naimor-dev-infra/bin/onboard.ps1, fetched below, not cloned.

$ErrorActionPreference = "Stop"
# PowerShell 7.4+ defaults $PSNativeCommandUseErrorActionPreference to $true,
# which turns ANY native command's nonzero exit (and often its stderr output)
# into a terminating error when $ErrorActionPreference = "Stop" -- even when
# the exit code is being used deliberately as a signal (e.g. `gh auth status`
# returning nonzero just means "not logged in yet"). Redirecting the stream
# (*> $null) does not prevent this. Disabling it restores the behavior this
# script's $LASTEXITCODE checks are written around.
$PSNativeCommandUseErrorActionPreference = $false
$Org = "NaimorInc"
$Repo = "naimor-dev-infra"

function Info($m) { Write-Host "==> $m" }
function Test-Cmd($name) { return [bool](Get-Command $name -ErrorAction SilentlyContinue) }
function Refresh-Path {
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + `
                [System.Environment]::GetEnvironmentVariable("Path", "User")
}

if (-not (Test-Cmd winget)) {
    Write-Error "winget (Windows Package Manager) is required. Install 'App Installer' from the Microsoft Store, then re-run this command."
    exit 1
}

if (-not (Test-Cmd git)) {
    Info "Installing Git"
    winget install --id Git.Git --exact --accept-package-agreements --accept-source-agreements
    Refresh-Path
}

if (-not (Test-Cmd gh)) {
    Info "Installing GitHub CLI"
    winget install --id GitHub.cli --exact --accept-package-agreements --accept-source-agreements
    Refresh-Path
}

gh auth status *> $null
if ($LASTEXITCODE -ne 0) {
    Info "Not logged in to gh."
    gh auth login
}

while ($true) {
    gh api "repos/$Org/$Repo" *> $null
    if ($LASTEXITCODE -eq 0) { break }
    Write-Host "This account cannot read $Org/$Repo."
    $ans = Read-Host "Log out and try a different account? [y/N]"
    if ($ans -match '^[Yy]') {
        gh auth logout
        gh auth login
    } else {
        Write-Error "Cancelled."
        exit 1
    }
}
Info "Confirmed read access to $Org/$Repo."

Info "Fetching the real installer from $Org/$Repo"
$script = gh api -H "Accept: application/vnd.github.raw" "repos/$Org/$Repo/contents/bin/onboard.ps1"
Invoke-Expression ($script -join "`n")
