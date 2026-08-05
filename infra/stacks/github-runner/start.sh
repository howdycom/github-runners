#!/bin/bash
set -euo pipefail

if [ -z "${GITHUB_ORG_URL:-}" ] || [ -z "${GITHUB_PAT:-}" ]; then
  echo "GITHUB_ORG_URL and GITHUB_PAT must be set."
  exit 1
fi

if [[ ! "${GITHUB_ORG_URL}" =~ ^https?://[^/]+/[^/]+(/[^/]+)?/?$ ]]; then
  echo "GITHUB_ORG_URL must include an organization or repository path (e.g., https://github.com/my-org or https://github.com/my-org/my-repo)."
  exit 1
fi

# Move the credential out of the environment immediately. The runner listener
# passes its environment down to Runner.Worker and to every job step, so a PAT
# left exported here would be readable by any workflow that lands on this runner
# (a step running `env` would print it). This one is long-lived and has org
# self-hosted-runner RW, so leaking it is worse than leaking a registration
# token. A plain shell variable stays available to this script — including
# mint_token and cleanup — without being inherited by children.
PAT_VALUE="$GITHUB_PAT"
unset GITHUB_PAT

RUNNER_VERSION="${RUNNER_VERSION:-2.336.0}"
RUNNER_LABELS="${RUNNER_LABELS:-docker,ubuntu-22.04}"
RUNNER_NAME_PREFIX="${RUNNER_NAME_PREFIX:-github-runner}"
RUNNER_TIER="${RUNNER_TIER:-}"
RUNNER_EPHEMERAL="${RUNNER_EPHEMERAL:-true}"
GITHUB_API_URL="${GITHUB_API_URL:-https://api.github.com}"

# Derive the token API base from the org/repo URL:
#   https://github.com/my-org         -> /orgs/my-org/actions/runners
#   https://github.com/my-org/my-repo -> /repos/my-org/my-repo/actions/runners
TARGET_PATH="${GITHUB_ORG_URL#*://*/}"
TARGET_PATH="${TARGET_PATH%/}"
if [[ "${TARGET_PATH}" == */* ]]; then
  RUNNER_API_BASE="${GITHUB_API_URL}/repos/${TARGET_PATH}/actions/runners"
else
  RUNNER_API_BASE="${GITHUB_API_URL}/orgs/${TARGET_PATH}/actions/runners"
fi

# Mint a short-lived registration/remove token via the gh CLI. Tokens expire
# after 1 hour, so they are requested fresh at every register/remove. The
# assignment is command-scoped, so the PAT is exported only to gh.
mint_token() {
  GH_TOKEN="${PAT_VALUE}" gh api --method POST \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "${RUNNER_API_BASE}/$1" --jq '.token'
}

cleanup() {
  if [ -f .runner ]; then
    echo "Removing runner registration..."
    REMOVE_TOKEN="$(mint_token remove-token || true)"
    if [ -n "${REMOVE_TOKEN}" ]; then
      # `config.sh remove` takes only --token; passing --unattended makes it
      # abort with "Unrecognized command-line input arguments".
      ./config.sh remove --token "${REMOVE_TOKEN}" || true
    else
      echo "Could not mint a remove token; leaving deregistration to GitHub."
    fi
  fi
}

# Installed before the download so an abort under `set -e` still deregisters.
trap cleanup EXIT

if [ ! -f ./config.sh ]; then
  echo "Downloading GitHub Actions runner v${RUNNER_VERSION}..."
  curl -fL -o actions-runner.tar.gz \
    "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
  tar xzf actions-runner.tar.gz
  rm actions-runner.tar.gz
fi

configure_runner() {
  RUNNER_NAME="${RUNNER_NAME_PREFIX}${RUNNER_TIER:+-${RUNNER_TIER}}-${HOSTNAME}"

  echo "Minting registration token..."
  REG_TOKEN="$(mint_token registration-token)"
  if [ -z "${REG_TOKEN}" ]; then
    echo "Failed to mint a registration token for ${TARGET_PATH}."
    echo "The credential needs 'admin:org' scope (classic / gh CLI token) or org 'Self-hosted runners: RW' (fine-grained PAT); for repo-scoped runners, 'repo' scope or repository 'Administration: RW'."
    # Back off rather than exiting straight into a restart loop that would
    # hammer the API and re-download the runner on every iteration.
    sleep 300
    exit 1
  fi

  echo "Configuring runner ${RUNNER_NAME}..."
  EXTRA_FLAGS=()
  if [ "${RUNNER_EPHEMERAL}" = "true" ]; then
    EXTRA_FLAGS+=(--ephemeral)
  fi
  # Deliberately NOT --disableupdate: GitHub deprecates old runner versions and
  # refuses their connections ("Runner version vX is deprecated and cannot
  # receive messages"), which kills the listener on startup. Letting the runner
  # self-update means a pinned RUNNER_VERSION only sets the initial download and
  # the host heals itself instead of going dark when a version ages out.
  ./config.sh --url "$GITHUB_ORG_URL" \
    --token "${REG_TOKEN}" \
    --labels "$RUNNER_LABELS" \
    --name "$RUNNER_NAME" \
    --unattended \
    --replace \
    ${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"}
}

if [ "${RUNNER_EPHEMERAL}" = "true" ]; then
  # Ephemeral runners are auto-removed by GitHub after one job, so any local
  # config left over from a previous container run is stale — drop it and
  # re-register with a fresh token.
  rm -f .runner .credentials .credentials_rsaparams
  configure_runner
elif [ ! -f .runner ]; then
  configure_runner
fi

# Run the listener in the background and forward SIGTERM/SIGINT to it. `docker
# stop` signals PID 1 only, and bash defers trap handlers until the current
# foreground command finishes — so with `./run.sh` in the foreground the runner
# never sees the signal and is SIGKILLed when the grace period expires,
# cancelling any in-flight job and skipping deregistration.
./run.sh &
RUNNER_PID=$!
trap 'echo "Stopping runner..."; kill -TERM "$RUNNER_PID" 2>/dev/null || true' TERM INT

set +e
wait "$RUNNER_PID"
EXIT_CODE=$?
while kill -0 "$RUNNER_PID" 2>/dev/null; do
  wait "$RUNNER_PID"
  EXIT_CODE=$?
done
set -e

# cleanup() runs here via the EXIT trap.
exit "$EXIT_CODE"
