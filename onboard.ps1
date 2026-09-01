# NaimorInc/.github onboard.ps1 — public phase, Windows.
#
#   irm "https://raw.githubusercontent.com/NaimorInc/.github/refs/heads/main/onboard.ps1" | iex
#
# Job: get to an authenticated `gh` that can read naimor-dev-infra, then
# hand off to the real installer there. Does NOT set up WSL2, install an
# IDE, or install your dotfiles itself -- that's
# naimor-dev-infra/bin/onboard.ps1, fetched below, not cloned.

# Deliberately NOT $ErrorActionPreference = "Stop": under BOTH Windows
# PowerShell 5.1 (the classic behavior, since v1) and PowerShell 7.4+
# (via $PSNativeCommandUseErrorActionPreference, on by default), "Stop"
# turns a native command's stderr output into a terminating error --
# even when the exit code is a deliberate signal this script checks via
# $LASTEXITCODE (e.g. `gh auth status` returning nonzero just means "not
# logged in yet"). Redirecting the stream (*> $null) does not prevent
# it. Leaving the default ("Continue") is what makes the $LASTEXITCODE
# checks below actually reachable, on either PowerShell version.
$PSNativeCommandUseErrorActionPreference = $false  # belt-and-suspenders on 7.4+; the real fix is not setting "Stop" above
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

# Install a package from the community `winget` source explicitly. On a fresh
# machine the `msstore` source often fails its certificate check
# (0x8a15005e -- the Store isn't fully provisioned yet, and opening it once
# does not reliably fix this). When ANY source errors during resolution,
# winget refuses to auto-pick from the source that worked, prints "specify
# one of them using --source", and exits nonzero WITHOUT installing. Pinning
# --source winget sidesteps msstore entirely -- both packages we need
# (Git.Git, GitHub.cli) live in the community source. $LASTEXITCODE is then
# checked by the caller: winget's "found in multiple sources" bail is a
# nonzero exit, not a thrown error, so nothing catches it otherwise.
function Winget-Install($Id) {
    winget install --id $Id --exact --source winget `
        --accept-package-agreements --accept-source-agreements
    return ($LASTEXITCODE -eq 0)
}

if (-not (Test-Cmd git)) {
    Info "Installing Git"
    Winget-Install "Git.Git" | Out-Null
    Refresh-Path
}

if (-not (Test-Cmd gh)) {
    Info "Installing GitHub CLI"
    Winget-Install "GitHub.cli" | Out-Null
    Refresh-Path
}

# Hard gate: if either tool is still missing, STOP here with a real message.
# Without this the script limps on into `gh` calls that throw
# CommandNotFoundException (which does NOT set $LASTEXITCODE), so the checks
# below read a stale value and the loop prints the misleading "This account
# cannot read ..." when the true cause is that gh never installed.
$missing = @()
if (-not (Test-Cmd git)) { $missing += "git" }
if (-not (Test-Cmd gh))  { $missing += "gh" }
if ($missing.Count -gt 0) {
    Write-Error @"
$($missing -join ' and ') did not install. Most likely winget could not
reach a package source. Try, in a NEW terminal:
    winget source reset --force
    winget install --id Git.Git --exact --source winget
    winget install --id GitHub.cli --exact --source winget
then re-run this onboarding command.
"@
    exit 1
}

gh auth status *> $null
if ($LASTEXITCODE -ne 0) {
    Info "Not logged in to gh."
    gh auth login
}

# Name the account we're about to act as. A person may have more than one
# GitHub account with NaimorInc access (e.g. a personal and a work login);
# make it visible which one onboarding picked up rather than assuming.
$who = (gh api user --jq .login 2>$null)
if ($who) { Info "Authenticated to GitHub as: $who" }

while ($true) {
    $probe = gh api "repos/$Org/$Repo" 2>&1
    if ($LASTEXITCODE -eq 0) { break }
    Write-Host "Account '$who' cannot read $Org/$Repo."
    # Surface the real reason -- a SAML/SSO-unauthorized token and a genuine
    # no-access both land here but say different things in the API error.
    Write-Host ($probe | Select-Object -First 3 | Out-String).Trim()
    $ans = Read-Host "Log out and try a different account? [y/N]"
    if ($ans -match '^[Yy]') {
        gh auth logout
        gh auth login
        $who = (gh api user --jq .login 2>$null)
    } else {
        Write-Error "Cancelled. Ask a NaimorInc owner to grant '$who' read access to $Repo, or sign in with an account that has it."
        exit 1
    }
}
Info "Confirmed read access to $Org/$Repo as '$who'."

Info "Fetching the real installer from $Org/$Repo"
$script = gh api -H "Accept: application/vnd.github.raw" "repos/$Org/$Repo/contents/bin/onboard.ps1"
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace(($script -join ""))) {
    Write-Error "Could not fetch bin/onboard.ps1 from $Org/$Repo (empty or errored response). Re-run in a moment."
    exit 1
}
Invoke-Expression ($script -join "`n")
