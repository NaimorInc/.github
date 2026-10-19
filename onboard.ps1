# NaimorInc/.github onboard.ps1 — public phase, Windows.
#
#   irm "https://raw.githubusercontent.com/NaimorInc/.github/refs/heads/main/onboard.ps1" | iex
#
# Job: get to an authenticated `gh` that can read naimor-dev-infra, then
# hand off to the real installer there. Does NOT set up WSL2, install an
# IDE, or install your dotfiles itself -- that's
# naimor-dev-infra/bin/onboard.ps1, fetched below, not cloned.
#
# Runs on: native Windows 11, under Windows PowerShell 5.1 or PowerShell 7.
#
# Dry run: prints the plan and changes nothing.
#   & ([scriptblock]::Create((irm "https://raw.githubusercontent.com/NaimorInc/.github/refs/heads/main/onboard.ps1"))) -DryRun
# or $env:NAIMOR_ONBOARD_DRY_RUN = '1' before the usual command: `| iex`
# binds no parameters, so the param block below is inert there (the variable
# then stays set in that window until removed). Installs become [dry-run]
# lines and prompts are described, not asked. Read-only checks (Get-Command,
# gh auth status, gh api reads) still run, so the plan is this machine's.
# Where the next step needs something a real run would only just have
# installed or logged in, the plan describes the rest and ends there. With
# read access confirmed, it fetches the real installer and runs that
# installer's own dry run. -DryRun is a switch, as in that installer; -WhatIf
# is accepted as an alias.
param(
    [Alias('WhatIf')]
    [switch] $DryRun
)
$script:DryRun = $DryRun -or ($env:NAIMOR_ONBOARD_DRY_RUN -in @('1', 'true', 'yes'))

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

function Info($m, $Mark = '==>') { Write-Host "$Mark $m" }
# A dry run's plan line.
function Plan($m) { Info $m '[dry-run]' }
# A dry run can't probe past a step that only a real run would complete (a
# tool not yet installed, a login not yet made): it says what that step and
# the rest would do, and stops. Exit 0: nothing failed.
function Exit-Plan($Step, $Why) {
    Plan $Step
    Info "Dry run ends here: $Why Nothing was changed."
    exit 0
}
if ($script:DryRun) { Info "DRY RUN: printing the plan; nothing on this machine is changed" }
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
    if ($script:DryRun) {
        Plan "winget install --id $Id --exact --source winget --accept-package-agreements --accept-source-agreements"
        return $true
    }
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
if ($missing.Count -gt 0 -and $script:DryRun) {
    Exit-Plan "a real run then logs in to gh (gh auth login -s project), confirms read access to $Org/$Repo, and runs its installer" `
        "$($missing -join ' and ') isn't installed yet, and the rest needs it."
}
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
    if ($script:DryRun) {
        Exit-Plan "gh auth login -s project (interactive: gh asks which account and how to sign in, usually in a browser)" `
            "the access check and the installer's plan need a login. Log in, then run the dry run again."
    }
    # -s project: day-to-day work edits an org Project board; the real installer
    # adds the scope to an older login that lacks it.
    gh auth login -s project
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
    if ($script:DryRun) {
        Exit-Plan "a real run asks `"Log out and try a different account? [y/N]`": y logs out, runs gh auth login -s project and checks again; anything else stops" `
            "nothing past this check can be planned until an account can read $Org/$Repo."
    }
    $ans = Read-Host "Log out and try a different account? [y/N]"
    if ($ans -match '^[Yy]') {
        gh auth logout
        gh auth login -s project
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
if ($script:DryRun) {
    # Fetching only reads. The installer runs as a script block so -DryRun
    # binds (Invoke-Expression binds no parameters), and only once it is
    # known to have one: an installer without it would change the machine.
    if (-not (($script -join "`n") -match 'NAIMOR_ONBOARD_DRY_RUN')) {
        Write-Error "The installer in $Org/$Repo has no dry run; not running it."
        exit 1
    }
    Info "Running the installer's own dry run"
    & ([scriptblock]::Create($script -join "`n")) -DryRun
} else {
    Invoke-Expression ($script -join "`n")
}
