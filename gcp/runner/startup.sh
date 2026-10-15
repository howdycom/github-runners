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

  local version
  version="$(metadata runner-version)"
  log "installing docker and runner ${version}"

  export DEBIAN_FRONTEND=noninteractive
  apt-get -o DPkg::Lock::Timeout=600 update
  apt-get install "${APT_OPTS[@]}" \
    build-essential ca-certificates curl git gnupg jq python3 python3-venv sudo unzip zip zstd

  # Docker Engine, buildx and compose from Docker's own repository.
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  # shellcheck source=/dev/null
  . /etc/os-release
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
    >/etc/apt/sources.list.d/docker.list
  apt-get -o DPkg::Lock::Timeout=600 update
  apt-get install "${APT_OPTS[@]}" \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
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

  # Download the runner and check it against the SHA-256 that GitHub
  # publishes in the release notes.
  local tarball=/tmp/actions-runner.tar.gz
  local expected_sha
  expected_sha="$(curl -fsSL "https://api.github.com/repos/actions/runner/releases/tags/v${version}" \
    | jq -r '.body' \
    | sed -n 's/.*<!-- BEGIN SHA linux-x64 -->\([0-9a-f]\{64\}\)<!-- END SHA linux-x64 -->.*/\1/p')"
  if [ -z "${expected_sha}" ]; then
    log "no published checksum for runner ${version}"
    false
  fi
  curl -fsSL -o "${tarball}" \
    "https://github.com/actions/runner/releases/download/v${version}/actions-runner-linux-x64-${version}.tar.gz"
  echo "${expected_sha}  ${tarball}" | sha256sum -c -

  mkdir -p "${RUNNER_DIR}"
  tar xzf "${tarball}" -C "${RUNNER_DIR}"
  rm -f "${tarball}"
  "${RUNNER_DIR}/bin/installdependencies.sh"
  chown -R "${RUNNER_USER}:${RUNNER_USER}" "${RUNNER_DIR}"

  touch "${INSTALLED_MARKER}"
}

bake() {
  install_runner_host
  apt-get clean
  rm -rf /var/lib/apt/lists/* /tmp/*
  log "bake complete"
  shutdown_now
}

run_one_job() {
  local jit_config
  if ! jit_config="$(metadata jit-config)"; then
    log "no jit-config in metadata"
    shutdown_now
  fi

  install_runner_host

  # --jitconfig registers this VM as an ephemeral runner for a single job.
  # run.sh returns after that job, or when the controller removes the runner.
  log "starting runner"
  local exit_code=0
  runuser -u "${RUNNER_USER}" -- "${RUNNER_DIR}/run.sh" --jitconfig "${jit_config}" || exit_code=$?
  log "runner exited with ${exit_code}"
  shutdown_now
}

if [ "$(metadata ghr-bake || true)" = "true" ]; then
  bake
else
  run_one_job
fi
