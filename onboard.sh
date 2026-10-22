#!/usr/bin/env bash
# NaimorInc/.github onboard.sh — public phase, macOS/Linux/WSL2.
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/NaimorInc/.github/refs/heads/main/onboard.sh)
#
# Runs on: macOS, Debian/Ubuntu (apt), WSL2's Debian (bash 3.2+: macOS's
# /bin/bash). git and gh are installed with Homebrew or apt; on another Linux,
# install both first, or the gate below stops the run once apt fails.
#
# Job: get to an authenticated `gh` that can read naimor-dev-infra, then
# hand off to the real installer there. Does NOT install your baseline
# tools or dotfiles itself -- that's naimor-dev-infra/bin/onboard.sh,
# fetched below, not cloned. The design, and what the person running it
# sees, is naimor-dev-infra's onboarding guide ("Setting up your
# workstation").
#
# `bash <(curl ...)`, not plain `curl | bash`: under a pipe, bash's stdin is
# the script itself, so whatever reads stdin gets the next script lines
# instead of the person's keystrokes ([V] 2026-10-20, bash 5.2: `read` took
# the line after it). `bash <(...)` reads the script from a separate fd and
# leaves stdin on the terminal. The prompts here (gh's sign-in, and the
# account question) read /dev/tty anyway: the Windows installer's WSL handoff
# does pipe this script into bash.
# (PowerShell's `irm | iex` doesn't have this problem: `iex` evaluates in the
# *same* session rather than a stdin-piped subshell, so its interactive
# prompts are unaffected either way; [V] 2026-10-20, pwsh 7.4.6.)
#
# --dry-run (or NAIMOR_ONBOARD_DRY_RUN=1) prints the plan and changes nothing:
#   bash <(curl -fsSL https://raw.githubusercontent.com/NaimorInc/.github/refs/heads/main/onboard.sh) --dry-run
# Any value of the variable but 0, false or no counts, in any case: a mistyped
# value plans rather than installs. Installs become [dry-run] lines and
# prompts are described, not asked. Read-only checks (command -v, gh api
# reads) still run, so the plan is this machine's. Where the next step needs
# something a real run would only just have installed or logged in, the plan
# describes the rest and ends there. With read access confirmed, it fetches
# the real installer and runs that installer's own dry run.
set -euo pipefail

ORG="NaimorInc"
REPO="naimor-dev-infra"

info() { printf '==> %s\n' "$1"; }

DRY_RUN=0
case "${NAIMOR_ONBOARD_DRY_RUN:-}" in
  ''|0|[Ff][Aa][Ll][Ss][Ee]|[Nn][Oo]) ;;
  *) DRY_RUN=1 ;;
esac
for arg in "$@"; do
  case "$arg" in
    --dry-run|-n) DRY_RUN=1 ;;
    -h|--help)
      printf 'Usage: onboard.sh [--dry-run]\n  --dry-run, -n  print the plan; change nothing (also NAIMOR_ONBOARD_DRY_RUN=1)\n'
      exit 0 ;;
    *) printf 'onboard.sh: unknown argument %s (try --help)\n' "$arg" >&2; exit 2 ;;
  esac
done

# Every install goes through run, or, where a command can't be passed as
# words (a fetched script handed to a shell, a pipe into tee), an explicit
# `if [ "$DRY_RUN" = 1 ]` with its own [dry-run] line. A dry run prints the
# command, %q-quoted so it can be pasted, and returns 0.
run() {
  if [ "$DRY_RUN" = 1 ]; then
    printf '[dry-run]'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}
# A dry run can't probe past a step that only a real run would complete (a
# tool not yet installed, a login not yet made): it says what that step and
# the rest would do, and stops. Exit 0: nothing failed.
plan_ends() {
  printf '[dry-run] %s\n' "$1"
  info "Dry run ends here: $2 Nothing was changed."
  exit 0
}
if [ "$DRY_RUN" = 1 ]; then
  # Exported for the real installer: it arrives on a pipe below, where no
  # argument reaches it, and reads this variable instead.
  export NAIMOR_ONBOARD_DRY_RUN=1
  info "DRY RUN: printing the plan; nothing on this machine is changed"
fi

# Homebrew, for git and gh on macOS. Not through run: the installer is a
# fetched script handed to bash, and a dry run must not even fetch it.
BREW_PLANNED=0
ensure_brew() {
  command -v brew >/dev/null 2>&1 && return 0
  if [ "$DRY_RUN" = 1 ]; then
    # Once: git and gh both call this, and a dry run installs nothing between.
    if [ "$BREW_PLANNED" = 0 ]; then
      # shellcheck disable=SC2016  # the literal command is the plan line
      printf '[dry-run] /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"\n'
      BREW_PLANNED=1
    fi
    return 0
  fi
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv)"
}

# 1. git. On macOS without the Command Line Tools, /usr/bin/git is Apple's
# shim, which only offers to install them: command -v finds it, so nothing is
# installed here and the gate below passes. Tolerated: this script never runs
# git, and the installer's Homebrew step installs the Command Line Tools ([S]
# Homebrew's install.sh, read 2026-10-20).
if ! command -v git >/dev/null 2>&1; then
  if [[ "$(uname)" == "Darwin" ]]; then
    ensure_brew
    run brew install git
  else
    run sudo apt-get update -y && run sudo apt-get install -y git
  fi
fi

# 2. gh (GitHub CLI)
if ! command -v gh >/dev/null 2>&1; then
  if [[ "$(uname)" == "Darwin" ]]; then
    ensure_brew
    run brew install gh
  elif [ "$DRY_RUN" = 1 ]; then
    printf '[dry-run] add the GitHub CLI apt repository (key: /etc/apt/keyrings/githubcli-archive-keyring.gpg, list: /etc/apt/sources.list.d/github-cli.list), then: sudo apt-get update && sudo apt-get install gh -y\n'
  else
    # Official Debian/Ubuntu method -- https://github.com/cli/cli/blob/trunk/docs/install_linux.md
    (type -p wget >/dev/null || (sudo apt-get update && sudo apt-get install wget -y)) \
      && sudo mkdir -p -m 755 /etc/apt/keyrings \
      && wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null \
      && sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
      && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
      && sudo apt-get update \
      && sudo apt-get install gh -y
  fi
fi

# Hard gate: git and gh must actually be on PATH now. A failed install
# above (a broken apt source, a declined Homebrew step) otherwise limps on
# into `gh` calls that then fail for a different-looking reason. In a dry
# run nothing was installed, so a missing tool ends the plan instead.
for tool in git gh; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    if [ "$DRY_RUN" = 1 ]; then
      plan_ends "a real run then logs in to gh if it isn't yet (gh auth login -h github.com -s project), confirms read access to $ORG/$REPO, and runs its installer" \
        "$tool isn't installed yet, and the rest needs it."
    fi
    echo "ERROR: '$tool' did not install. Fix the error above and re-run." >&2
    exit 1
  fi
done

# 3. Authenticate. The probe is `gh api user`: it succeeds only with the
# ACTIVE account's token, the one every call below uses. Not `gh auth status`:
# without --active it exits 1 when ANY stored account on any host has a
# problem ([S] gh 2.89.0's --help), so a good login next to a stale second
# account would read as "not logged in", and a real run would then go
# through `gh auth login`, which can switch the active account.
#
# gh_login's stdin is /dev/tty when there is one: under the WSL handoff's
# `curl | bash` gh's stdin would be this script, and gh would read the rest of
# it as answers (the same pipe the header describes). -h github.com skips
# gh's host question; -s project: day-to-day work edits an org Project board,
# and the real installer adds the scope to an older login that lacks it.
# A login adds an account beside the stored ones and makes it the active one;
# it never logs another out. gh has kept several accounts per host since 2.40
# ([S] gh 2.40.0's release notes; [V] 2026-10-22, gh 2.89.0's `auth switch
# --help` describes switching among them). The step above installs gh from
# GitHub's own channels, so it is current; a gh older than 2.40 that was
# already installed would replace the account, which is unguarded.
# A failed or cancelled sign-in is not fatal here: the caller's probe then
# fails, and the banner below says what to do next.
gh_login() {
  if ( : </dev/tty ) 2>/dev/null; then
    gh auth login -h github.com -s project </dev/tty || true
  else
    gh auth login -h github.com -s project || true
  fi
}
if ! gh api user >/dev/null 2>&1; then
  info "Not logged in to gh."
  if [ "$DRY_RUN" = 1 ]; then
    plan_ends "gh auth login -h github.com -s project (interactive: gh asks how to sign in, usually in a browser)" \
      "the access check and the installer's plan need a login. Log in, then run the dry run again."
  fi
  gh_login
fi

# Name the account we're acting as. A person may have more than one GitHub
# account (work + personal); make the pick visible.
WHO="$(gh api user --jq .login 2>/dev/null || true)"
[ -n "$WHO" ] && info "Authenticated to GitHub as: $WHO"

# Bold red for the banner below, only on a terminal and without NO_COLOR
# (no-color.org). bash 3.2 has $'...'.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  LOUD=$'\033[1;31m'; BOLD=$'\033[1m'; PLAIN=$'\033[0m'
else
  LOUD=''; BOLD=''; PLAIN=''
fi

# Why the active account can't read $ORG/$REPO, made hard to scroll past:
# people re-ran onboarding signed in to a personal account, saw the old
# one-line "cannot read", and took it for a broken script. NaimorInc's
# members are work accounts named Naimor- plus the person's initials, not
# personal accounts. So a login without that prefix is almost certainly the
# personal one, and the banner says so. A login with it gets the other
# likely cause: access not granted yet. The prefix is a hint for a person,
# never used to pick an account.
# Requires: $1 the active login, empty if gh has none that works; $2 gh's
# error output.
explain_no_access() {
  printf '\n%s  ==================================================================\n' "$LOUD"
  printf '    STOP AND READ THIS: wrong GitHub account?\n'
  printf '  ==================================================================%s\n\n' "$PLAIN"
  case "$1" in
    '')
      printf '  gh has no working sign-in, so it cannot read %s/%s.\n' "$ORG" "$REPO" ;;
    [Nn][Aa][Ii][Mm][Oo][Rr]-*)
      printf '  gh is signed in as %s%s%s, which cannot read %s/%s.\n\n' "$BOLD" "$1" "$PLAIN" "$ORG" "$REPO"
      printf '  It looks like a NaimorInc work account, so its access may not be\n'
      printf '  set up yet. If it is yours, ask a NaimorInc owner to check it.\n'
      printf '  If it is not, sign in with yours.\n' ;;
    *)
      printf '  gh is signed in as %s%s%s, which cannot read %s/%s.\n' "$BOLD" "$1" "$PLAIN" "$ORG" "$REPO"
      printf '  That is probably your %sPERSONAL%s account.\n\n' "$BOLD" "$PLAIN"
      printf '  NaimorInc uses WORK accounts, named %sNaimor-%s plus your initials\n' "$BOLD" "$PLAIN"
      printf '  (Jane Doe would be Naimor-JD). Sign in with your Naimor- account.\n' ;;
  esac
  printf '\n  What GitHub said:\n'
  printf '%s\n' "$2" | head -n 3 | sed 's/^/    /'
  printf '\n'
}

# 4. Confirm read access to naimor-dev-infra -- not just org membership.
# Offer another sign-in rather than fail silently.
while ! probe="$(gh api "repos/$ORG/$REPO" 2>&1)"; do
  explain_no_access "$WHO" "$probe"
  if [ "$DRY_RUN" = 1 ]; then
    plan_ends "a real run asks \"Sign in with a different GitHub account now? Type y or n\" until it gets one: y runs gh auth login -h github.com -s project and checks again; n stops" \
      "nothing past this check can be planned until an account can read $ORG/$REPO."
  fi
  # From /dev/tty, not stdin: the Windows installer's WSL handoff pipes this
  # script into bash, so stdin is the script (see the top). No default: Enter
  # alone asks again, so the answer is a choice made after reading the
  # banner. With no terminal, or at end of input, the answer is No.
  ans=""
  if ( : </dev/tty ) 2>/dev/null; then
    while :; do
      printf '%sSign in with a different GitHub account now? Type y or n:%s ' "$BOLD" "$PLAIN"
      read -r ans </dev/tty || { ans=n; echo; break; }
      case "$ans" in [Yy]|[Yy][Ee][Ss]|[Nn]|[Nn][Oo]) break ;; esac
    done
  else
    echo "No terminal to ask on, so not signing in again."
  fi
  case "$ans" in
    [Yy]*)
      printf '\n  %sBefore you enter the code gh shows, make sure the browser is signed in\n' "$BOLD"
      printf '  to GitHub as your Naimor- account%s: GitHub authorizes whichever account\n' "$PLAIN"
      printf '  the browser is signed in to, so a personal one there gets this same\n'
      printf '  message again. Your other login stays in gh; only the active one changes.\n\n'
      gh_login
      WHO="$(gh api user --jq .login 2>/dev/null || true)"
      [ -n "$WHO" ] && info "Authenticated to GitHub as: $WHO"
      ;;
    *)
      echo "Stopped. Sign in with your Naimor- work account (gh auth login -h github.com -s project), then run this command again. No work account yet? Ask a NaimorInc owner."
      exit 1 ;;
  esac
done
info "Confirmed read access to $ORG/$REPO as '$WHO'."

# 5. Hand off to the real installer. Fetched, not cloned. bash reads it on
# stdin, so it must read every prompt from /dev/tty, as
# naimor-dev-infra/bin/onboard.sh does.
info "Fetching the real installer from $ORG/$REPO"
if [ "$DRY_RUN" = 1 ]; then
  # Fetching only reads. The installer runs as its own dry run through the
  # exported variable, so make sure it has one: an installer without it
  # would change the machine for real.
  installer="$(gh api -H "Accept: application/vnd.github.raw" "repos/$ORG/$REPO/contents/bin/onboard.sh")"
  case "$installer" in
    *NAIMOR_ONBOARD_DRY_RUN*) ;;
    *) echo "ERROR: the installer in $ORG/$REPO has no dry run; not running it." >&2; exit 1 ;;
  esac
  info "Running the installer's own dry run"
  printf '%s\n' "$installer" | bash
else
  gh api -H "Accept: application/vnd.github.raw" "repos/$ORG/$REPO/contents/bin/onboard.sh" | bash
fi
