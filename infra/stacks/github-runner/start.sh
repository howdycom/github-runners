#!/bin/bash
set -euo pipefail

if [ -z "${GITHUB_ORG_URL:-}" ] || [ -z "${RUNNER_REGISTRATION_TOKEN:-}" ]; then
  echo "GITHUB_ORG_URL and RUNNER_REGISTRATION_TOKEN must be set."
  exit 1
fi

if [[ ! "${GITHUB_ORG_URL}" =~ ^https?://[^/]+/[^/]+(/[^/]+)?/?$ ]]; then
  echo "GITHUB_ORG_URL must include an organization or repository path (e.g., https://github.com/my-org or https://github.com/my-org/my-repo)."
  exit 1
fi

# Move the token out of the environment immediately: the runner listener passes
# its environment down to Runner.Worker and to every job step, so anything left
# exported here is readable by any workflow that lands on this runner (and would
# be printed by a step running `env`). A plain shell variable stays available to
# this script — including cleanup() — without being inherited by children.
REG_TOKEN="$RUNNER_REGISTRATION_TOKEN"
unset RUNNER_REGISTRATION_TOKEN

RUNNER_VERSION="${RUNNER_VERSION:-2.323.0}"
RUNNER_LABELS="${RUNNER_LABELS:-docker,ubuntu-22.04}"
RUNNER_NAME_PREFIX="${RUNNER_NAME_PREFIX:-github-runner}"

cleanup() {
  if [ -f .runner ]; then
    # Best-effort only: `config.sh remove` expects a token from the
    # remove-token endpoint, and REG_TOKEN is a registration token that has
    # very likely expired (~1 hour TTL) by the time a container is stopped.
    # Expect this to fail and leave an offline runner entry that GitHub
    # garbage-collects after 14 days. Minting remove tokens from a PAT or
    # GitHub App credential is the real fix; see README.
    echo "Attempting to remove runner registration..."
    ./config.sh remove --unattended --token "$REG_TOKEN" || true
  fi
}

# Installed before the download so an abort under `set -e` still gets a chance
# to deregister.
trap cleanup EXIT

# Download once per container; restarts reuse the extracted runner.
if [ ! -f ./run.sh ]; then
  echo "Downloading GitHub Actions runner v${RUNNER_VERSION}..."
  curl -fL -o actions-runner.tar.gz \
    "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
  tar xzf actions-runner.tar.gz
  rm actions-runner.tar.gz
fi

if [ ! -f .runner ]; then
  RUNNER_NAME="${RUNNER_NAME_PREFIX}-${HOSTNAME}"

  echo "Configuring runner ${RUNNER_NAME}..."
  if ! ./config.sh --url "$GITHUB_ORG_URL" \
    --token "$REG_TOKEN" \
    --labels "$RUNNER_LABELS" \
    --name "$RUNNER_NAME" \
    --unattended \
    --replace; then
    echo "Runner configuration failed — the registration token is likely expired (tokens last ~1 hour)."
    echo "Generate a fresh token and re-run the deploy. Sleeping 5 minutes to avoid a hot restart loop."
    sleep 300
    exit 1
  fi
fi

# Run the listener in the background and forward SIGTERM/SIGINT to it, so
# `docker stop` reaches the runner (bash won't deliver signals while a
# foreground child runs) and cleanup gets a chance to deregister.
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

exit "$EXIT_CODE"
