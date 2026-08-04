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

RUNNER_VERSION="${RUNNER_VERSION:-2.323.0}"
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
# after 1 hour, so they are requested fresh at every register/remove.
mint_token() {
  GH_TOKEN="${GITHUB_PAT}" gh api --method POST \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "${RUNNER_API_BASE}/$1" --jq '.token'
}

cleanup() {
  if [ -f .runner ]; then
    echo "Removing runner registration..."
    REMOVE_TOKEN="$(mint_token remove-token || true)"
    if [ -n "${REMOVE_TOKEN}" ]; then
      ./config.sh remove --unattended --token "${REMOVE_TOKEN}" || true
    else
      echo "Could not mint a remove token; leaving deregistration to GitHub."
    fi
  fi
}

trap cleanup EXIT INT TERM

if [ ! -f ./config.sh ]; then
  echo "Downloading GitHub Actions runner v${RUNNER_VERSION}..."
  curl -fL -o actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz \
    "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"

  tar xzf actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz
fi

configure_runner() {
  RUNNER_NAME="${RUNNER_NAME_PREFIX}${RUNNER_TIER:+-${RUNNER_TIER}}-${HOSTNAME}"

  echo "Minting registration token..."
  REG_TOKEN="$(mint_token registration-token)"
  if [ -z "${REG_TOKEN}" ]; then
    echo "Failed to mint a registration token for ${TARGET_PATH}."
    echo "The credential needs 'admin:org' scope (classic / gh CLI token) or org 'Self-hosted runners: RW' (fine-grained PAT); for repo-scoped runners, 'repo' scope or repository 'Administration: RW'."
    exit 1
  fi

  echo "Configuring runner ${RUNNER_NAME}..."
  EXTRA_FLAGS=()
  if [ "${RUNNER_EPHEMERAL}" = "true" ]; then
    EXTRA_FLAGS+=(--ephemeral)
  fi
  ./config.sh --url "$GITHUB_ORG_URL" \
    --token "${REG_TOKEN}" \
    --labels "$RUNNER_LABELS" \
    --name "$RUNNER_NAME" \
    --unattended \
    --replace \
    --disableupdate \
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

./run.sh
