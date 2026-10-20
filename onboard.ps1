# NaimorInc/.github onboard.ps1 — public phase, Windows.
#
#   irm "https://raw.githubusercontent.com/NaimorInc/.github/refs/heads/main/onboard.ps1" | iex
#
# Job: get to an authenticated `gh` that can read naimor-dev-infra, then
# hand off to the real installer there. Does NOT set up WSL2, install an
# IDE, or install your dotfiles itself -- that's
# naimor-dev-infra/bin/onboard.ps1, fetched below, not cloned. The design,
# and what the person running it sees, is naimor-dev-infra's onboarding guide
# ("Setting up your workstation").
#
# Runs on: native Windows 11, under Windows PowerShell 5.1 or PowerShell 7.
#
# Never `exit`s. Both documented forms (`| iex`, and the dry run's script
# block below) run this in the person's own PowerShell session, where `exit`
# ends that session and closes the window over what was just printed ([V]
# 2026-10-20, pwsh 7.4.6 on Linux: `exit` in a script block or in iex'd code
# ends the host, inside try/catch too; Windows PowerShell 5.1 not tried).
# Each stop is a `return` at the top level of this script, which ends only
# the script, with the result in $LASTEXITCODE: 0 when a dry run's plan ends
# early, 1 for an error here, and after the handoff the installer's own.
#
# Dry run: prints the plan and changes nothing.
#   & ([scriptblock]::Create((irm "https://raw.githubusercontent.com/NaimorInc/.github/refs/heads/main/onboard.ps1"))) -DryRun
# or $env:NAIMOR_ONBOARD_DRY_RUN = '1' before the usual command: `| iex`
# binds no parameters, so the param block below is inert there ([V]
# 2026-10-20, pwsh 7.4.6), and the variable then stays set in that window
# until removed. Any value but 0, false or no counts, in any case: a mistyped
# value plans rather than installs. Installs become [dry-run] lines and
# prompts are described, not asked. Read-only checks (Get-Command, gh api
# reads) still run, so the plan is this machine's. Where the next step needs
# something a real run would only just have installed or logged in, the plan
# describes the rest and ends there. With read access confirmed, it fetches
# the real installer and runs that installer's own dry run. -DryRun is a
# switch, as in that installer; -WhatIf is accepted as an alias.
param(
    [Alias('WhatIf')]
    [switch] $DryRun
)
$script:DryRun = $DryRun -or ($env:NAIMOR_ONBOARD_DRY_RUN -and $env:NAIMOR_ONBOARD_DRY_RUN -notin @('0', 'false', 'no'))

# Deliberately NOT $ErrorActionPreference = "Stop": it turns a native
# command's failure into a terminating error, even when the exit code is a
# deliberate signal this script checks via $LASTEXITCODE (e.g. `gh api user`
# failing just means "not logged in yet"), and redirecting the stream
# (*> $null) does not prevent it. On Windows PowerShell 5.1 the trigger is
# the command's stderr output ([S] a Windows PowerShell 5.1 run, 2026-08-21,
# stopped on `gh auth status *> $null`); on PowerShell 7.4+ it is a nonzero
# exit while $PSNativeCommandUseErrorActionPreference is $true ([V]
# 2026-10-20, pwsh 7.4.6: $false by default, and a profile can set it).
# Leaving the default ("Continue") is what makes the $LASTEXITCODE checks
# below reachable, on either PowerShell version.
$PSNativeCommandUseErrorActionPreference = $false  # in case a profile turned it on (7.4+); the real fix is not setting "Stop" above
$Org = "NaimorInc"
$Repo = "naimor-dev-infra"

function Info($m, $Mark = '==>') { Write-Host "$Mark $m" }
# A dry run's plan line.
function Plan($m) { Info $m '[dry-run]' }
# A dry run can't probe past a step that only a real run would complete (a
# tool not yet installed, a login not yet made): it says what that step and
# the rest would do, and its caller returns (never `exit`: see the top).
# $LASTEXITCODE 0: nothing failed.
function Exit-Plan($Step, $Why) {
    Plan $Step
    Info "Dry run ends here: $Why Nothing was changed."
    $global:LASTEXITCODE = 0
}
if ($script:DryRun) { Info "DRY RUN: printing the plan; nothing on this machine is changed" }
function Test-Cmd($name) { return [bool](Get-Command $name -ErrorAction SilentlyContinue) }
# Not in a dry run: nothing was installed, and this rewrites the session's PATH.
function Refresh-Path {
    if ($script:DryRun) { return }
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + `
                [System.Environment]::GetEnvironmentVariable("Path", "User")
}

if (-not (Test-Cmd winget)) {
    Write-Error "winget (Windows Package Manager) is required. Install 'App Installer' from the Microsoft Store, then re-run this command."
    $global:LASTEXITCODE = 1
    return
}

# Install a package from the community `winget` source explicitly. On a fresh
# machine the `msstore` source often fails its certificate check
# (0x8a15005e -- the Store isn't fully provisioned yet, and opening it once
# does not reliably fix this; [S] seen on a fresh Windows PC, 2026-09-01).
# When ANY source errors during resolution, winget refuses to auto-pick from
# the source that worked, prints "specify one of them using --source", and
# exits nonzero WITHOUT installing. Pinning --source winget sidesteps msstore
# entirely -- both packages we need (Git.Git, GitHub.cli) live in the
# community source. That bail is a nonzero exit, not a thrown error, so
# nothing catches it here: the hard gate below (git and gh on PATH) is the
# check. Out-Host shows winget's own output, which the callers' `| Out-Null`
# (discarding the result) would otherwise swallow.
function Winget-Install($Id) {
    if ($script:DryRun) {
        Plan "winget install --id $Id --exact --source winget --accept-package-agreements --accept-source-agreements"
        return $true
    }
    winget install --id $Id --exact --source winget `
        --accept-package-agreements --accept-source-agreements | Out-Host
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
    Exit-Plan "a real run then logs in to gh if it isn't yet (gh auth login -s project), confirms read access to $Org/$Repo, and runs its installer" `
        "the rest needs $($missing -join ' and '), not installed yet."
    return
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
    $global:LASTEXITCODE = 1
    return
}

# The probe is `gh api user`: it succeeds only with the ACTIVE account's
# token, the one every call below uses. Not `gh auth status`: without
# --active it exits 1 when ANY stored account on any host has a problem ([S]
# gh 2.89.0's --help), so a good login next to a stale second account would
# read as "not logged in", and a real run would then go through
# `gh auth login`, which can switch the active account.
gh api user *> $null
if ($LASTEXITCODE -ne 0) {
    Info "Not logged in to gh."
    if ($script:DryRun) {
        Exit-Plan "gh auth login -s project (interactive: gh asks which account and how to sign in, usually in a browser)" `
            "the access check and the installer's plan need a login. Log in, then run the dry run again."
        return
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
        return
    }
    $ans = Read-Host "Log out and try a different account? [y/N]"
    if ($ans -match '^[Yy]') {
        gh auth logout
        gh auth login -s project
        $who = (gh api user --jq .login 2>$null)
    } else {
        Write-Error "Cancelled. Ask a NaimorInc owner to grant '$who' read access to $Repo, or sign in with an account that has it."
        $global:LASTEXITCODE = 1
        return
    }
}
Info "Confirmed read access to $Org/$Repo as '$who'."

Info "Fetching the real installer from $Org/$Repo"
# PowerShell decodes gh's output with [Console]::OutputEncoding ([V]
# 2026-10-20, pwsh 7.4.6), which on Windows is the console's code page, set by
# the system locale, not UTF-8 ([S] .NET's Console.OutputEncoding docs). So a
# non-ASCII character in the installer arrives mangled. Unguarded, and
# tolerable while the installer keeps to ASCII outside comments: its only
# non-ASCII character is in its first-line comment ([V] 2026-10-20, on
# naimor-dev-infra's main).
$installer = gh api -H "Accept: application/vnd.github.raw" "repos/$Org/$Repo/contents/bin/onboard.ps1"
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace(($installer -join ""))) {
    Write-Error "Could not fetch bin/onboard.ps1 from $Org/$Repo (empty or errored response). Re-run in a moment."
    $global:LASTEXITCODE = 1
    return
}
if ($script:DryRun) {
    # Fetching only reads. The installer runs as a script block so -DryRun
    # binds (Invoke-Expression binds no parameters), and only once it is
    # known to have a dry run: one without would change the machine. The
    # variable is set for the call too, as onboard.sh exports it, so an
    # installer that reads only the variable still plans; the person's own
    # value (or its absence) is put back after.
    if (-not (($installer -join "`n") -match 'NAIMOR_ONBOARD_DRY_RUN')) {
        Write-Error "The installer in $Org/$Repo has no dry run; not running it."
        $global:LASTEXITCODE = 1
        return
    }
    Info "Running the installer's own dry run"
    $savedDryRunVar = $env:NAIMOR_ONBOARD_DRY_RUN
    $env:NAIMOR_ONBOARD_DRY_RUN = '1'
    try {
        & ([scriptblock]::Create($installer -join "`n")) -DryRun
    } finally {
        $env:NAIMOR_ONBOARD_DRY_RUN = $savedDryRunVar
    }
} else {
    Invoke-Expression ($installer -join "`n")
}
