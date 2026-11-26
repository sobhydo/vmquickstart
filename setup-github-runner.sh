#!/usr/bin/env bash
#
# setup-github-runner.sh
# Interactive installer for a GitHub Actions self-hosted runner on Debian/Ubuntu.
#
#  - creates a dedicated "github-runner" user
#  - optionally installs Docker (official repo) and gives the runner access to it
#  - downloads the latest actions/runner release (checksum verified when available)
#  - asks for repo/org URL, registration token, name, labels, ...
#  - configures the runner and installs + starts it as a systemd service (svc.sh)
#
# Usage (as root):
#   sudo bash setup-github-runner.sh
# or straight from a URL:
#   curl -fsSL <raw-url-of-this-file> -o setup-github-runner.sh && sudo bash setup-github-runner.sh
#
set -euo pipefail

RUNNER_USER="github-runner"
RUNNER_HOME="/home/${RUNNER_USER}"
RUNNER_DIR="${RUNNER_HOME}/actions-runner"

# ---------- helpers ----------------------------------------------------------
c_blue=$'\e[1;34m'; c_green=$'\e[1;32m'; c_yellow=$'\e[1;33m'; c_red=$'\e[1;31m'; c_off=$'\e[0m'
step() { printf '\n%s==> %s%s\n' "$c_blue" "$*" "$c_off"; }
ok()   { printf '%s✔ %s%s\n' "$c_green" "$*" "$c_off"; }
warn() { printf '%s! %s%s\n' "$c_yellow" "$*" "$c_off"; }
die()  { printf '%s✘ %s%s\n' "$c_red" "$*" "$c_off" >&2; exit 1; }

# All prompts read from the terminal, so the script also works when piped (curl | bash).
ask() { # ask "Question" "default" -> echoes answer
  local q="$1" def="${2:-}" ans
  if [[ -n "$def" ]]; then read -r -p "$q [$def]: " ans </dev/tty; else read -r -p "$q: " ans </dev/tty; fi
  printf '%s' "${ans:-$def}"
}
ask_required() {
  local ans=""
  while [[ -z "$ans" ]]; do ans="$(ask "$@")"; done
  printf '%s' "$ans"
}
ask_secret() {
  local q="$1" ans=""
  while [[ -z "$ans" ]]; do read -r -s -p "$q: " ans </dev/tty; echo >&2; done
  printf '%s' "$ans"
}
ask_yn() { # ask_yn "Question" y|n -> return 0 for yes
  local q="$1" def="${2:-n}" hint ans
  [[ "$def" == y ]] && hint="Y/n" || hint="y/N"
  read -r -p "$q [$hint]: " ans </dev/tty
  ans="${ans:-$def}"
  [[ "${ans,,}" == y || "${ans,,}" == yes ]]
}
as_runner() { sudo -u "$RUNNER_USER" -H "$@"; }

# ---------- pre-flight -------------------------------------------------------
[[ $EUID -eq 0 ]] || die "Run this script as root (sudo bash $0)."
[[ -r /etc/os-release ]] || die "Cannot detect OS (/etc/os-release missing)."
# shellcheck disable=SC1091
. /etc/os-release
command -v apt-get >/dev/null || die "This script supports Debian/Ubuntu (apt) only."

case "$(uname -m)" in
  x86_64)  RUNNER_ARCH="x64" ;;
  aarch64) RUNNER_ARCH="arm64" ;;
  armv7l)  RUNNER_ARCH="arm" ;;
  *) die "Unsupported CPU architecture: $(uname -m)" ;;
esac

echo
echo "GitHub Actions self-hosted runner setup  (${PRETTY_NAME:-$ID}, ${RUNNER_ARCH})"
echo "-----------------------------------------------------------------"

# ---------- questions --------------------------------------------------------
INSTALL_DOCKER=n; ask_yn "Install Docker on this server?" y && INSTALL_DOCKER=y
GIVE_SUDO=n;      ask_yn "Give '${RUNNER_USER}' passwordless sudo (needed if workflows run apt/sudo)?" n && GIVE_SUDO=y

ALREADY_CONFIGURED=n
[[ -f "${RUNNER_DIR}/.runner" ]] && ALREADY_CONFIGURED=y

if [[ $ALREADY_CONFIGURED == n ]]; then
  echo
  echo "Get these from GitHub:  Repo (or Org) → Settings → Actions → Runners → New self-hosted runner"
  while :; do
    GH_URL="$(ask_required "Repository or organization URL (e.g. https://github.com/owner/repo)")"
    GH_URL="${GH_URL%/}"; GH_URL="${GH_URL%.git}"
    [[ "$GH_URL" =~ ^https://github\.com/[^/]+(/[^/]+)?$ ]] && break
    warn "URL must look like https://github.com/owner or https://github.com/owner/repo"
  done
  GH_TOKEN="$(ask_secret "Registration token (hidden, valid for 1 hour)")"
  RUNNER_NAME="$(ask "Runner name" "$(hostname)")"
  RUNNER_LABELS="$(ask "Extra labels, comma separated (self-hosted,Linux,${RUNNER_ARCH^^} are added automatically)" "")"
  RUNNER_WORK="$(ask "Work folder" "_work")"
  RUNNER_GROUP=""
  if [[ "$GH_URL" =~ ^https://github\.com/[^/]+$ ]]; then
    RUNNER_GROUP="$(ask "Runner group (organization runners)" "Default")"
  fi
  REPLACE=n; ask_yn "Replace an existing runner with the same name if there is one?" n && REPLACE=y
else
  warn "A runner is already configured in ${RUNNER_DIR} – skipping registration, will (re)install the service."
fi

# ---------- 1. base packages -------------------------------------------------
step "Checking base packages"
export DEBIAN_FRONTEND=noninteractive
MISSING=()
for p in curl ca-certificates tar sudo; do
  dpkg -s "$p" >/dev/null 2>&1 || MISSING+=("$p")
done
if (( ${#MISSING[@]} )); then
  apt-get update -y
  apt-get install -y "${MISSING[@]}"
  ok "Installed: ${MISSING[*]}"
else
  ok "Already installed: curl ca-certificates tar sudo"
fi

# ---------- 2. runner user ---------------------------------------------------
step "Creating user '${RUNNER_USER}'"
if id "$RUNNER_USER" >/dev/null 2>&1; then
  ok "User already exists"
else
  useradd --create-home --home-dir "$RUNNER_HOME" --shell /bin/bash "$RUNNER_USER"
  ok "User created"
fi
if [[ $GIVE_SUDO == y ]]; then
  echo "${RUNNER_USER} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${RUNNER_USER}"
  chmod 440 "/etc/sudoers.d/${RUNNER_USER}"
  visudo -cf "/etc/sudoers.d/${RUNNER_USER}" >/dev/null || { rm -f "/etc/sudoers.d/${RUNNER_USER}"; die "sudoers file invalid"; }
  ok "Passwordless sudo granted"
fi

# ---------- 3. docker (optional) --------------------------------------------
if [[ $INSTALL_DOCKER == y ]]; then
  step "Installing Docker"
  if command -v docker >/dev/null 2>&1; then
    ok "Docker already installed: $(docker --version)"
  else
    case "$ID" in
      ubuntu|debian) DOCKER_DISTRO="$ID" ;;
      *) case "${ID_LIKE:-}" in
           *ubuntu*) DOCKER_DISTRO=ubuntu ;;
           *debian*) DOCKER_DISTRO=debian ;;
           *) die "Docker repo not available for '$ID'. Install Docker manually and re-run." ;;
         esac ;;
    esac
    CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
    [[ -n "$CODENAME" ]] || die "Cannot detect distribution codename for the Docker repo."
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/${DOCKER_DISTRO}/gpg" -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${DOCKER_DISTRO} ${CODENAME} stable" \
      > /etc/apt/sources.list.d/docker.list
    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    systemctl enable --now docker
    ok "Docker installed: $(docker --version)"
  fi
  usermod -aG docker "$RUNNER_USER"
  ok "'${RUNNER_USER}' added to the docker group"
fi

# ---------- 4. download runner ----------------------------------------------
if [[ ! -x "${RUNNER_DIR}/config.sh" ]]; then
  step "Downloading the latest GitHub Actions runner"
  API_JSON="$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest)" \
    || die "Could not reach api.github.com"
  RUNNER_VERSION="$(printf '%s\n' "$API_JSON" | grep -m1 '"tag_name"' | sed -E 's/.*"v?([^"]+)".*/\1/')"
  [[ -n "$RUNNER_VERSION" ]] || die "Could not determine the latest runner version"
  ASSET="actions-runner-linux-${RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz"
  URL="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${ASSET}"
  # sha256 of the asset, from the release API "digest" field (if present)
  SHA="$(printf '%s\n' "$API_JSON" | tr ',' '\n' | awk -v n="\"name\": \"${ASSET}\"" '
      index($0, n) { f = 1; next }
      f && /"name":/ { exit }
      f && /"digest"/ { sub(/.*"sha256:/, ""); sub(/".*/, ""); print; exit }')"

  echo "Version: ${RUNNER_VERSION}  (${ASSET})"
  as_runner mkdir -p "$RUNNER_DIR"
  TMP="$(mktemp)"; trap 'rm -f "$TMP"' EXIT
  curl -fL --progress-bar -o "$TMP" "$URL" || die "Download failed: $URL"
  if [[ "$SHA" =~ ^[a-f0-9]{64}$ ]]; then
    echo "${SHA}  ${TMP}" | sha256sum -c --quiet - || die "Checksum mismatch – aborting"
    ok "Checksum verified"
  else
    warn "No checksum published in the API for this release – skipping verification"
  fi
  tar -xzf "$TMP" -C "$RUNNER_DIR"
  chown -R "${RUNNER_USER}:${RUNNER_USER}" "$RUNNER_DIR"
  ok "Runner extracted to ${RUNNER_DIR}"
else
  ok "Runner files already present in ${RUNNER_DIR}"
fi

step "Installing runner dependencies"
"${RUNNER_DIR}/bin/installdependencies.sh"
ok "Dependencies installed"

# ---------- 5. configure -----------------------------------------------------
if [[ $ALREADY_CONFIGURED == n ]]; then
  step "Registering the runner with GitHub"
  CFG_ARGS=(--unattended --url "$GH_URL" --token "$GH_TOKEN" --name "$RUNNER_NAME" --work "$RUNNER_WORK")
  [[ -n "$RUNNER_LABELS" ]] && CFG_ARGS+=(--labels "$RUNNER_LABELS")
  [[ -n "$RUNNER_GROUP" ]]  && CFG_ARGS+=(--runnergroup "$RUNNER_GROUP")
  [[ $REPLACE == y ]]       && CFG_ARGS+=(--replace)
  ( cd "$RUNNER_DIR" && as_runner ./config.sh "${CFG_ARGS[@]}" ) \
    || die "Runner registration failed (token expired or wrong URL?). Get a new token and re-run."
  unset GH_TOKEN
  ok "Runner registered"
fi

# ---------- 6. service -------------------------------------------------------
step "Installing and starting the runner service"
cd "$RUNNER_DIR"
if [[ -f .service ]]; then
  ok "Service already installed ($(cat .service))"
else
  ./svc.sh install "$RUNNER_USER"
fi
SYSTEMD_PAGER='' ./svc.sh start   # also prints the service status

echo
ok "Done! The runner should now show as 'Idle' under Settings → Actions → Runners."
echo "   Service:  $(cat .service 2>/dev/null || echo 'actions.runner.*')"
echo "   Logs:     journalctl -u \"$(cat .service 2>/dev/null || echo 'actions.runner.*')\" -f"
echo "   Manage:   cd ${RUNNER_DIR} && sudo ./svc.sh {status|stop|start|uninstall}"
[[ $INSTALL_DOCKER == y ]] && echo "   Docker:   '${RUNNER_USER}' is in the docker group (service was started after that, so jobs can use docker)."
exit 0
