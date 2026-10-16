#!/bin/bash
# Startup script for runner VMs. Compute Engine runs it as root at boot.
#
# Run mode (default): install Docker and the runner if the image lacks them,
# run exactly one job with the just-in-time config from instance metadata,
# then power off. The controller deletes the VM after the job.
#
# Bake mode (metadata ghr-bake=true, used by bake-image.sh): install, clean
# up, power off, so the disk can become an image.
# -E makes the ERR trap below fire inside functions too.
set -Eeuo pipefail

# The GHR_ overrides exist for runner/tests only.
RUNNER_DIR="${GHR_RUNNER_DIR:-/opt/actions-runner}"
RUNNER_USER=runner
INSTALLED_MARKER="${GHR_INSTALLED_MARKER:-/etc/ghr-installed}"
IDLE_POLL_SECONDS="${GHR_IDLE_POLL_SECONDS:-5}"
BAKE_GRACE_SECONDS=60
# System Node, as on a GitHub-hosted runner: some jobs run `node` or a global
# `npm install` without actions/setup-node. Jobs that need another version
# still use setup-node.
NODE_VERSION=22.22.3

# Libraries and fonts Playwright installs for Chromium on Ubuntu 24.04
# (`playwright install --with-deps chromium`, Playwright 1.63.0). GitHub-hosted
# runners have them preinstalled; jobs here only download the browser.
PLAYWRIGHT_CHROMIUM_PACKAGES=(
  libasound2t64 libatk-bridge2.0-0t64 libatk1.0-0t64 libatspi2.0-0t64 libcairo2
  libcups2t64 libdbus-1-3 libdrm2 libgbm1 libglib2.0-0t64 libnspr4 libnss3
  libpango-1.0-0 libx11-6 libxcb1 libxcomposite1 libxdamage1 libxext6 libxfixes3
  libxkbcommon0 libxrandr2
  xvfb fonts-noto-color-emoji fonts-unifont libfontconfig1 libfreetype6
  xfonts-cyrillic xfonts-scalable fonts-liberation fonts-ipafont-gothic
  fonts-wqy-zenhei fonts-tlwg-loma-otf fonts-freefont-ttf
)
METADATA_URL=http://metadata.google.internal/computeMetadata/v1/instance/attributes
APT_OPTS=(-o DPkg::Lock::Timeout=600 -y --no-install-recommends)

log() { echo "ghr: $*"; }

metadata() {
  curl -sf -H 'Metadata-Flavor: Google' "${METADATA_URL}/$1"
}

shutdown_now() {
  trap - ERR
  log "powering off"
  systemctl poweroff || true
  exit 0
}

# Any failing command stops the script and powers the VM off. In run mode the
# controller then deletes the VM; in bake mode no image is created.
# shellcheck disable=SC2317 # called by the ERR trap, not directly
on_error() {
  # Inside $(...) only fail the substitution. Logging here would put the log
  # text into the caller's variable; the failed assignment then triggers this
  # handler again in the main shell.
  if [ "${BASH_SUBSHELL}" -gt 0 ]; then
    exit 1
  fi
  log "failed at line $1"
  shutdown_now
}
trap 'on_error ${LINENO}' ERR

install_runner_host() {
  if [ -f "${INSTALLED_MARKER}" ]; then
    log "docker and runner already installed"
    return
  fi

  local version sha256
  version="$(metadata runner-version)"
  sha256="$(metadata runner-sha256)"
  log "installing docker and runner ${version}"

  export DEBIAN_FRONTEND=noninteractive
  apt-get -o DPkg::Lock::Timeout=600 update
  apt-get install "${APT_OPTS[@]}" \
    build-essential ca-certificates curl git gnupg jq python3 python3-venv sudo unzip xz-utils zip zstd \
    "${PLAYWRIGHT_CHROMIUM_PACKAGES[@]}"

  # GitHub CLI from GitHub's own repository.
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli.gpg
  chmod a+r /etc/apt/keyrings/githubcli.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli.gpg] https://cli.github.com/packages stable main" \
    >/etc/apt/sources.list.d/github-cli.list

  # Docker Engine, buildx and compose from Docker's own repository.
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  # shellcheck source=/dev/null
  . /etc/os-release
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
    >/etc/apt/sources.list.d/docker.list
  apt-get -o DPkg::Lock::Timeout=600 update
  apt-get install "${APT_OPTS[@]}" \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin gh
  cat >/etc/docker/daemon.json <<'JSON'
{"log-driver": "json-file", "log-opts": {"max-size": "10m", "max-file": "3"}}
JSON
  systemctl enable --now docker
  systemctl restart docker

  # The job runs as an unprivileged user with Docker access and passwordless
  # sudo, like a GitHub-hosted runner. The VM is used for one job only.
  id -u "${RUNNER_USER}" >/dev/null 2>&1 || useradd -m -s /bin/bash "${RUNNER_USER}"
  usermod -aG docker "${RUNNER_USER}"
  echo "${RUNNER_USER} ALL=(ALL) NOPASSWD:ALL" >/etc/sudoers.d/90-runner
  chmod 0440 /etc/sudoers.d/90-runner

  install_node
  install_runner "${version}" "${sha256}"
  touch "${INSTALLED_MARKER}"
}

# Installs Node into /usr/local, checked against nodejs.org's SHA-256 list,
# and lets the runner user install global npm packages there, as on a
# GitHub-hosted runner.
install_node() {
  local tarball="node-v${NODE_VERSION}-linux-x64.tar.xz"
  local workdir
  workdir="$(mktemp -d)"
  curl -fsSL -o "${workdir}/${tarball}" "https://nodejs.org/dist/v${NODE_VERSION}/${tarball}"
  curl -fsSL -o "${workdir}/SHASUMS256.txt" "https://nodejs.org/dist/v${NODE_VERSION}/SHASUMS256.txt"
  (cd "${workdir}" && grep " ${tarball}\$" SHASUMS256.txt | sha256sum -c -)
  tar -xJf "${workdir}/${tarball}" -C /usr/local --strip-components=1 --no-same-owner
  rm -rf "${workdir}"
  chown -R "${RUNNER_USER}:${RUNNER_USER}" /usr/local/lib/node_modules /usr/local/bin
}

# Downloads the runner and checks it against the pinned SHA-256 (Terraform
# variable runner_sha256), so a boot makes no GitHub API call.
install_runner() {
  local version="$1"
  local sha256="$2"
  local tarball
  tarball="$(mktemp)"
  curl -fsSL -o "${tarball}" \
    "https://github.com/actions/runner/releases/download/v${version}/actions-runner-linux-x64-${version}.tar.gz"
  echo "${sha256}  ${tarball}" | sha256sum -c -

  mkdir -p "${RUNNER_DIR}"
  tar xzf "${tarball}" -C "${RUNNER_DIR}"
  rm -f "${tarball}"
  "${RUNNER_DIR}/bin/installdependencies.sh"
  chown -R "${RUNNER_USER}:${RUNNER_USER}" "${RUNNER_DIR}"
}

bake() {
  install_runner_host
  apt-get clean
  rm -rf /var/lib/apt/lists/* /tmp/*
  log "bake complete"
  # bake-image.sh reads the serial console only while the VM runs (Compute
  # Engine returns none for a stopped VM) and polls every 15 seconds, so stay
  # up long enough for it to see the line above.
  sleep "${BAKE_GRACE_SECONDS}"
  shutdown_now
}

run_one_job() {
  local jit_config
  if ! jit_config="$(metadata jit-config)"; then
    log "no jit-config in metadata"
    shutdown_now
  fi

  install_runner_host

  local idle_timeout
  idle_timeout="$(metadata idle-timeout-seconds)"

  # --jitconfig registers this VM as an ephemeral runner for a single job.
  # run.sh returns after that job, or when the controller removes the runner.
  log "starting runner"
  runuser -u "${RUNNER_USER}" -- "${RUNNER_DIR}/run.sh" --jitconfig "${jit_config}" &
  local runner_pid=$!

  # Power off when no job starts in time, even if the controller is down.
  local deadline=$((SECONDS + idle_timeout))
  while kill -0 "${runner_pid}" 2>/dev/null; do
    if ! job_started && [ "${SECONDS}" -ge "${deadline}" ]; then
      log "no job within ${idle_timeout}s"
      kill -TERM "${runner_pid}" 2>/dev/null || true
      shutdown_now
    fi
    sleep "${IDLE_POLL_SECONDS}"
  done

  local exit_code=0
  wait "${runner_pid}" || exit_code=$?
  log "runner exited with ${exit_code}"
  shutdown_now
}

# The runner writes a Worker_*.log when it starts a job.
job_started() {
  compgen -G "${RUNNER_DIR}/_diag/Worker_*.log" >/dev/null
}

main() {
  if [ "$(metadata ghr-bake || true)" = "true" ]; then
    bake
  else
    run_one_job
  fi
}

# runner/tests set GHR_SOURCE_ONLY to load the functions without running.
if [ -z "${GHR_SOURCE_ONLY:-}" ]; then
  main
fi
