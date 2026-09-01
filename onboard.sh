#!/usr/bin/env bash
# NaimorInc/.github onboard.sh — public phase, macOS/Linux/WSL2.
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/NaimorInc/.github/refs/heads/main/onboard.sh)
#
# Job: get to an authenticated `gh` that can read naimor-dev-infra, then
# hand off to the real installer there. Does NOT install your baseline
# tools or dotfiles itself -- that's naimor-dev-infra/bin/onboard.sh,
# fetched below, not cloned.
#
# NOT plain `curl | bash`: this script calls `read -r -p` (the account-switch
# prompt below), and piping curl's output into bash leaves stdin attached to
# that pipe instead of the real terminal, so `read` would hang or read
# garbage. `bash <(...)` uses process substitution instead -- bash reads the
# script from a separate fd, stdin stays the terminal, `read` keeps working.
# (PowerShell's `irm | iex` doesn't have this problem: `iex` evaluates in the
# *same* session rather than a stdin-piped subshell, so its interactive
# prompts are unaffected either way.)
set -euo pipefail

ORG="NaimorInc"
REPO="naimor-dev-infra"

info() { printf '==> %s\n' "$1"; }

# 1. git
if ! command -v git >/dev/null 2>&1; then
  if [[ "$(uname)" == "Darwin" ]]; then
    command -v brew >/dev/null 2>&1 || /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv)"
    brew install git
  else
    sudo apt-get update -y && sudo apt-get install -y git
  fi
fi

# 2. gh (GitHub CLI)
if ! command -v gh >/dev/null 2>&1; then
  if [[ "$(uname)" == "Darwin" ]]; then
    command -v brew >/dev/null 2>&1 || /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv)"
    brew install gh
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
# into `gh` calls that then fail for a different-looking reason.
for tool in git gh; do
  command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: '$tool' did not install. Fix the error above and re-run." >&2; exit 1; }
done

# 3. Authenticate
if ! gh auth status >/dev/null 2>&1; then
  info "Not logged in to gh."
  gh auth login
fi

# Name the account we're acting as. A person may have more than one GitHub
# account with NaimorInc access (personal + work); make the pick visible.
WHO="$(gh api user --jq .login 2>/dev/null || true)"
[ -n "$WHO" ] && info "Authenticated to GitHub as: $WHO"

# 4. Confirm read access to naimor-dev-infra -- not just org membership.
# Offer to switch accounts rather than fail silently.
while ! probe="$(gh api "repos/$ORG/$REPO" 2>&1)"; do
  echo "Account '$WHO' cannot read $ORG/$REPO."
  # Surface the real reason -- a SAML/SSO-unauthorized token and a genuine
  # no-access both land here but the API error text differs.
  printf '%s\n' "$probe" | head -n 3
  read -r -p "Log out and try a different account? [y/N] " ans
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    gh auth logout
    gh auth login
    WHO="$(gh api user --jq .login 2>/dev/null || true)"
  else
    echo "Cancelled. Ask a NaimorInc owner to grant '$WHO' read access to $REPO, or sign in with an account that has it."
    exit 1
  fi
done
info "Confirmed read access to $ORG/$REPO as '$WHO'."

# 5. Hand off to the real installer. Fetched, not cloned.
info "Fetching the real installer from $ORG/$REPO"
gh api -H "Accept: application/vnd.github.raw" "repos/$ORG/$REPO/contents/bin/onboard.sh" | bash
