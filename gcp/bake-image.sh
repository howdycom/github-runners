#!/bin/bash
# Builds the runner VM image: Ubuntu 24.04 with Docker and the GitHub Actions
# runner preinstalled. Runner VMs boot from the newest image in the family.
#
# Usage: ./bake-image.sh <project> <zone> <runner-version> <runner-sha256> [subnet] [image-family]
#   runner-version, runner-sha256: the same values as the Terraform variables
#   subnet: optional. Without it, the script creates a temporary network and
#     gives the builder a public IP. Pass the stack's `subnet` output instead
#     when an organization policy forbids external IPs (use_cloud_nat = true).
#   image-family: defaults to github-runner, the family the stack boots from.
#
# Run it before the first terraform apply, then monthly for OS and Docker updates.
set -euo pipefail

if [ "$#" -lt 4 ]; then
  sed -n '2,12p' "$0"
  exit 1
fi

PROJECT="$1"
ZONE="$2"
RUNNER_VERSION="$3"
RUNNER_SHA256="$4"
SUBNET="${5:-}"
FAMILY="${6:-github-runner}"
REGION="${ZONE%-*}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BUILDER="${FAMILY}-bake-${STAMP}"
TIMEOUT_SECONDS=1800
POLL_SECONDS="${GHR_POLL_SECONDS:-15}"
TEMP_NETWORK=""
SERIAL_LOG="$(mktemp)"

cleanup() {
  rm -f "${SERIAL_LOG}"
  gcloud compute instances delete "${BUILDER}" --project="${PROJECT}" --zone="${ZONE}" --quiet >/dev/null 2>&1 || true
  if [ -n "${TEMP_NETWORK}" ]; then
    gcloud compute networks subnets delete "${TEMP_NETWORK}" --project="${PROJECT}" --region="${REGION}" --quiet >/dev/null 2>&1 || true
    gcloud compute networks delete "${TEMP_NETWORK}" --project="${PROJECT}" --quiet >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

if [ -n "${SUBNET}" ]; then
  # The stack's subnet with Cloud NAT: no public IP needed.
  network_flags=(--subnet="${SUBNET}" --no-address)
else
  # A temporary network with no firewall rules: outbound traffic only.
  TEMP_NETWORK="${BUILDER}"
  gcloud compute networks create "${TEMP_NETWORK}" --project="${PROJECT}" --subnet-mode=custom
  gcloud compute networks subnets create "${TEMP_NETWORK}" \
    --project="${PROJECT}" --network="${TEMP_NETWORK}" --region="${REGION}" --range=10.250.0.0/24
  network_flags=(--subnet="${TEMP_NETWORK}")
fi

# The builder carries no ghr_managed label, so the controller never touches it.
gcloud compute instances create "${BUILDER}" \
  --project="${PROJECT}" \
  --zone="${ZONE}" \
  --machine-type=n2d-standard-2 \
  "${network_flags[@]}" \
  --image-family=ubuntu-2404-lts-amd64 \
  --image-project=ubuntu-os-cloud \
  --boot-disk-size=20GB \
  --boot-disk-type=pd-balanced \
  --no-service-account \
  --no-scopes \
  --metadata="ghr-bake=true,runner-version=${RUNNER_VERSION},runner-sha256=${RUNNER_SHA256}" \
  --metadata-from-file="startup-script=${SCRIPT_DIR}/runner/startup.sh"

echo "Waiting for ${BUILDER} to install and power off..."
deadline=$((SECONDS + TIMEOUT_SECONDS))
until [ "$(gcloud compute instances describe "${BUILDER}" --project="${PROJECT}" --zone="${ZONE}" --format='value(status)')" = "TERMINATED" ]; do
  if [ "${SECONDS}" -ge "${deadline}" ]; then
    echo "Timed out. Check the serial console: gcloud compute instances get-serial-port-output ${BUILDER} --zone=${ZONE} --project=${PROJECT}"
    exit 1
  fi
  sleep "${POLL_SECONDS}"
done

# Save the serial log before searching it. Piping gcloud into grep -q fails
# under pipefail: grep stops reading at the match, and gcloud, still writing a
# log of several megabytes, exits with SIGPIPE.
gcloud compute instances get-serial-port-output "${BUILDER}" --project="${PROJECT}" --zone="${ZONE}" \
  >"${SERIAL_LOG}" 2>/dev/null || true
if ! grep -q 'ghr: bake complete' "${SERIAL_LOG}"; then
  echo "The builder stopped without finishing the install. Not creating an image."
  echo "Last lines of its serial console:"
  tail -n 40 "${SERIAL_LOG}"
  exit 1
fi

gcloud compute images create "${FAMILY}-${STAMP}" \
  --project="${PROJECT}" \
  --source-disk="${BUILDER}" \
  --source-disk-zone="${ZONE}" \
  --family="${FAMILY}"

echo "Created image ${FAMILY}-${STAMP} in family ${FAMILY}."
