#!/bin/bash
# Builds a runner VM image with Docker and the GitHub Actions runner
# preinstalled, so runner VMs start in about a minute instead of three.
#
# Usage: ./bake-image.sh <project> <zone> <subnet> <runner-version> [image-family]
#   subnet: the `subnet` output of this stack
#
# Then set source_image = "projects/<project>/global/images/family/<image-family>"
# and run terraform apply. Re-run monthly to pick up OS and Docker updates.
set -euo pipefail

if [ "$#" -lt 4 ]; then
  sed -n '2,10p' "$0"
  exit 1
fi

PROJECT="$1"
ZONE="$2"
SUBNET="$3"
RUNNER_VERSION="$4"
FAMILY="${5:-github-runner}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BUILDER="${FAMILY}-bake-${STAMP}"
TIMEOUT_SECONDS=1800

cleanup() {
  gcloud compute instances delete "${BUILDER}" --project="${PROJECT}" --zone="${ZONE}" --quiet >/dev/null 2>&1 || true
}
trap cleanup EXIT

# The builder carries no ghr_managed label, so the controller never touches it.
gcloud compute instances create "${BUILDER}" \
  --project="${PROJECT}" \
  --zone="${ZONE}" \
  --machine-type=n2d-standard-2 \
  --subnet="${SUBNET}" \
  --image-family=ubuntu-2404-lts-amd64 \
  --image-project=ubuntu-os-cloud \
  --boot-disk-size=20GB \
  --boot-disk-type=pd-balanced \
  --no-service-account \
  --no-scopes \
  --metadata="ghr-bake=true,runner-version=${RUNNER_VERSION}" \
  --metadata-from-file="startup-script=${SCRIPT_DIR}/runner/startup.sh"

echo "Waiting for ${BUILDER} to install and power off..."
deadline=$((SECONDS + TIMEOUT_SECONDS))
until [ "$(gcloud compute instances describe "${BUILDER}" --project="${PROJECT}" --zone="${ZONE}" --format='value(status)')" = "TERMINATED" ]; do
  if [ "${SECONDS}" -ge "${deadline}" ]; then
    echo "Timed out. Check the serial console: gcloud compute instances get-serial-port-output ${BUILDER} --zone=${ZONE} --project=${PROJECT}"
    exit 1
  fi
  sleep 15
done

if ! gcloud compute instances get-serial-port-output "${BUILDER}" --project="${PROJECT}" --zone="${ZONE}" 2>/dev/null \
  | grep -q 'ghr: bake complete'; then
  echo "The builder stopped without finishing the install. Not creating an image."
  exit 1
fi

gcloud compute images create "${FAMILY}-${STAMP}" \
  --project="${PROJECT}" \
  --source-disk="${BUILDER}" \
  --source-disk-zone="${ZONE}" \
  --family="${FAMILY}"

echo "Created image ${FAMILY}-${STAMP} in family ${FAMILY}."
