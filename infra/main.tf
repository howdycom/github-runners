terraform {
  required_version = ">= 1.0"

  required_providers {
    null = {
      source  = "hashicorp/null"
      version = ">= 3.2.2"
    }
  }
}

provider "null" {}

resource "null_resource" "bootstrap_docker" {
  triggers = {
    docker_host   = var.docker_host
    daemon_config = "v1"
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<EOT
      USE_SSH=false
      if [[ "${var.docker_host}" == ssh://* ]]; then
        USE_SSH=true
        HOST="${replace(replace(var.docker_host, "ssh://", ""), "${var.ssh_user}@", "")}"
        USER="${var.ssh_user}"
      fi

      if [ "$USE_SSH" = "true" ]; then
        ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$USER@$HOST" 'bash -s' <<'REMOTE_SCRIPT'
          echo '{"default-address-pools":[{"base":"10.0.0.0/8","size":24}]}' | sudo tee /etc/docker/daemon.json > /dev/null
          sudo systemctl restart docker

          sudo mkdir -p /opt/portainer /opt/github-runner
          sudo chown -R 1000:1000 /opt/portainer /opt/github-runner || true
REMOTE_SCRIPT
      else
        echo '{"default-address-pools":[{"base":"10.0.0.0/8","size":24}]}' | sudo tee /etc/docker/daemon.json > /dev/null
        sudo systemctl restart docker

        sudo mkdir -p /opt/portainer /opt/github-runner
        sudo chown -R 1000:1000 /opt/portainer /opt/github-runner || true
      fi
    EOT
  }
}

resource "null_resource" "deploy_stacks" {
  depends_on = [null_resource.bootstrap_docker]

  triggers = {
    docker_host = var.docker_host

    enable_portainer      = var.enable_portainer
    enable_github_runners = var.enable_github_runners

    github_runner_heavy_count  = var.github_runner_heavy_count
    github_runner_light_count  = var.github_runner_light_count
    github_runner_org_url      = var.github_runner_org_url
    github_runner_pat_hash     = sha256(var.github_runner_pat)
    github_runner_ephemeral    = var.github_runner_ephemeral
    github_runner_heavy_labels = var.github_runner_heavy_labels
    github_runner_light_labels = var.github_runner_light_labels
    github_runner_heavy_cpus   = var.github_runner_heavy_cpus
    github_runner_heavy_memory = var.github_runner_heavy_memory
    github_runner_light_cpus   = var.github_runner_light_cpus
    github_runner_light_memory = var.github_runner_light_memory
    github_runner_name_prefix  = var.github_runner_name_prefix
    github_runner_version      = var.github_runner_version

    portainer_compose_hash = filesha256("${path.module}/stacks/portainer/docker-compose.yml")

    github_runner_compose_hash    = filesha256("${path.module}/stacks/github-runner/docker-compose.yml")
    github_runner_dockerfile_hash = filesha256("${path.module}/stacks/github-runner/Dockerfile")
    github_runner_start_hash      = filesha256("${path.module}/stacks/github-runner/start.sh")
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<EOT
      USE_SSH=false
      if [[ "${var.docker_host}" == ssh://* ]]; then
        USE_SSH=true
        HOST="${replace(replace(var.docker_host, "ssh://", ""), "${var.ssh_user}@", "")}"
        USER="${var.ssh_user}"
      fi

      # Resolve the GitHub credential on the machine running terraform.
      # Preference: explicit github_runner_pat var, otherwise the gh CLI's
      # stored token (no copy/paste needed).
      EFFECTIVE_PAT=""
      if [ "${var.enable_github_runners}" = "true" ]; then
        EFFECTIVE_PAT="${var.github_runner_pat}"
        if [ -z "$EFFECTIVE_PAT" ] && command -v gh >/dev/null 2>&1; then
          echo "github_runner_pat not set; using the gh CLI credential."
          EFFECTIVE_PAT="$(gh auth token 2>/dev/null || true)"
        fi
        if [ -z "$EFFECTIVE_PAT" ]; then
          echo "ERROR: no GitHub credential available. Authenticate the gh CLI (gh auth login) or set -var github_runner_pat=..." >&2
          exit 1
        fi

        ORG_URL="${var.github_runner_org_url}"
        TARGET="$${ORG_URL#*://*/}"
        TARGET="$${TARGET%/}"
        if [[ "$TARGET" == */* ]]; then
          TOKEN_API="https://api.github.com/repos/$TARGET/actions/runners/registration-token"
          SCOPE_HINT="the 'repo' scope (classic / gh CLI token) or repository 'Administration: Read and write' (fine-grained PAT)"
        else
          TOKEN_API="https://api.github.com/orgs/$TARGET/actions/runners/registration-token"
          SCOPE_HINT="the 'admin:org' scope (grant it with: gh auth refresh -h github.com -s admin:org) or org 'Self-hosted runners: Read and write' (fine-grained PAT)"
        fi

        echo "Verifying the credential can mint runner registration tokens for $TARGET..."
        if ! curl -sf -X POST \
          -H "Authorization: Bearer $EFFECTIVE_PAT" \
          -H "Accept: application/vnd.github+json" \
          -H "X-GitHub-Api-Version: 2022-11-28" \
          "$TOKEN_API" > /dev/null; then
          echo "ERROR: the credential cannot mint runner registration tokens for $TARGET. It needs $SCOPE_HINT." >&2
          exit 1
        fi
      fi

      ENV_TMP="$(mktemp)"
      cat > "$ENV_TMP" <<ENV_FILE
GITHUB_ORG_URL=${var.github_runner_org_url}
GITHUB_PAT=$EFFECTIVE_PAT
RUNNER_LABELS_HEAVY=${var.github_runner_heavy_labels}
RUNNER_LABELS_LIGHT=${var.github_runner_light_labels}
RUNNER_NAME_PREFIX=${var.github_runner_name_prefix}
RUNNER_VERSION=${var.github_runner_version}
RUNNER_EPHEMERAL=${var.github_runner_ephemeral}
HEAVY_CPUS=${var.github_runner_heavy_cpus}
HEAVY_MEMORY=${var.github_runner_heavy_memory}
LIGHT_CPUS=${var.github_runner_light_cpus}
LIGHT_MEMORY=${var.github_runner_light_memory}
ENV_FILE

      if [ "$USE_SSH" = "true" ]; then
        scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "${path.module}/stacks/portainer/docker-compose.yml" "$USER@$HOST:/tmp/portainer.docker-compose.yml"
        scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "${path.module}/stacks/github-runner/docker-compose.yml" "$USER@$HOST:/tmp/github-runner.docker-compose.yml"
        scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "${path.module}/stacks/github-runner/Dockerfile" "$USER@$HOST:/tmp/github-runner.Dockerfile"
        scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "${path.module}/stacks/github-runner/start.sh" "$USER@$HOST:/tmp/github-runner.start.sh"
        scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$ENV_TMP" "$USER@$HOST:/tmp/github-runner.env"
        rm -f "$ENV_TMP"

        ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$USER@$HOST" 'bash -s' <<'REMOTE_SCRIPT'
          set -e

          sudo mkdir -p /opt/portainer /opt/github-runner
          sudo chown -R 1000:1000 /opt/portainer /opt/github-runner || true

          sudo mv /tmp/portainer.docker-compose.yml /opt/portainer/docker-compose.yml
          sudo mv /tmp/github-runner.docker-compose.yml /opt/github-runner/docker-compose.yml
          sudo mv /tmp/github-runner.Dockerfile /opt/github-runner/Dockerfile
          sudo mv /tmp/github-runner.start.sh /opt/github-runner/start.sh
          sudo chmod +x /opt/github-runner/start.sh
          sudo mv /tmp/github-runner.env /opt/github-runner/.env
          sudo chmod 600 /opt/github-runner/.env

          echo "Configuring Firewall..."
          sudo ufw allow 22/tcp
          sudo ufw allow 8000/tcp
          sudo ufw allow 9000/tcp
          sudo ufw --force enable || true

          if [ "${var.enable_portainer}" = "true" ]; then
            cd /opt/portainer
            sudo docker compose up -d
          else
            echo "Skipping Portainer"
          fi

          if [ "${var.enable_github_runners}" = "true" ]; then
            cd /opt/github-runner
            sudo docker compose down --remove-orphans || true
            sudo docker compose up -d --build \
              --scale github-runner-heavy=${var.github_runner_heavy_count} \
              --scale github-runner-light=${var.github_runner_light_count}

            EXPECTED=$((${var.github_runner_heavy_count} + ${var.github_runner_light_count}))
            if [ "$EXPECTED" -gt 0 ]; then
              if ! command -v python3 >/dev/null; then
                echo "python3 is required on the host for the runner registration health gate."
                exit 1
              fi

              GITHUB_PAT_VALUE="$(sudo grep '^GITHUB_PAT=' /opt/github-runner/.env | cut -d= -f2-)"
              GITHUB_ORG_URL_RAW="${var.github_runner_org_url}"
              TARGET_PATH="$${GITHUB_ORG_URL_RAW#*://*/}"
              TARGET_PATH="$${TARGET_PATH%/}"
              if [[ "$TARGET_PATH" == */* ]]; then
                RUNNERS_API="https://api.github.com/repos/$TARGET_PATH/actions/runners"
              else
                RUNNERS_API="https://api.github.com/orgs/$TARGET_PATH/actions/runners"
              fi

              echo "Waiting for $EXPECTED runner(s) to come online..."
              DEADLINE=$((SECONDS + ${var.github_runner_registration_timeout}))
              while true; do
                ONLINE=$(curl -sf -H "Authorization: Bearer $GITHUB_PAT_VALUE" -H "Accept: application/vnd.github+json" "$RUNNERS_API?per_page=100" \
                  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(sum(1 for r in d.get("runners",[]) if r["status"] == "online" and r["name"].startswith("${var.github_runner_name_prefix}")))' \
                  || echo 0)
                if [ "$ONLINE" -ge "$EXPECTED" ]; then
                  echo "$ONLINE/$EXPECTED runner(s) online."
                  break
                fi
                if [ "$SECONDS" -ge "$DEADLINE" ]; then
                  echo "Timed out waiting for runner registration ($ONLINE/$EXPECTED online)."
                  sudo docker compose logs --tail 50
                  exit 1
                fi
                sleep 5
              done
            fi
          else
            echo "Skipping GitHub Runners"
          fi
REMOTE_SCRIPT
      else
        cp "${path.module}/stacks/portainer/docker-compose.yml" /tmp/portainer.docker-compose.yml
        cp "${path.module}/stacks/github-runner/docker-compose.yml" /tmp/github-runner.docker-compose.yml
        cp "${path.module}/stacks/github-runner/Dockerfile" /tmp/github-runner.Dockerfile
        cp "${path.module}/stacks/github-runner/start.sh" /tmp/github-runner.start.sh

        sudo mkdir -p /opt/portainer /opt/github-runner
        sudo chown -R 1000:1000 /opt/portainer /opt/github-runner || true

        sudo mv /tmp/portainer.docker-compose.yml /opt/portainer/docker-compose.yml
        sudo mv /tmp/github-runner.docker-compose.yml /opt/github-runner/docker-compose.yml
        sudo mv /tmp/github-runner.Dockerfile /opt/github-runner/Dockerfile
        sudo mv /tmp/github-runner.start.sh /opt/github-runner/start.sh
        sudo chmod +x /opt/github-runner/start.sh
        sudo mv "$ENV_TMP" /opt/github-runner/.env
        sudo chmod 600 /opt/github-runner/.env

        if [ "${var.enable_portainer}" = "true" ]; then
          cd /opt/portainer
          sudo docker compose up -d
        else
          echo "Skipping Portainer"
        fi

        if [ "${var.enable_github_runners}" = "true" ]; then
          cd /opt/github-runner
          sudo docker compose down --remove-orphans || true
          sudo docker compose up -d --build \
            --scale github-runner-heavy=${var.github_runner_heavy_count} \
            --scale github-runner-light=${var.github_runner_light_count}

          EXPECTED=$((${var.github_runner_heavy_count} + ${var.github_runner_light_count}))
          if [ "$EXPECTED" -gt 0 ]; then
            if ! command -v python3 >/dev/null; then
              echo "python3 is required on the host for the runner registration health gate."
              exit 1
            fi

            GITHUB_PAT_VALUE="$(sudo grep '^GITHUB_PAT=' /opt/github-runner/.env | cut -d= -f2-)"
            GITHUB_ORG_URL_RAW="${var.github_runner_org_url}"
            TARGET_PATH="$${GITHUB_ORG_URL_RAW#*://*/}"
            TARGET_PATH="$${TARGET_PATH%/}"
            if [[ "$TARGET_PATH" == */* ]]; then
              RUNNERS_API="https://api.github.com/repos/$TARGET_PATH/actions/runners"
            else
              RUNNERS_API="https://api.github.com/orgs/$TARGET_PATH/actions/runners"
            fi

            echo "Waiting for $EXPECTED runner(s) to come online..."
            DEADLINE=$((SECONDS + ${var.github_runner_registration_timeout}))
            while true; do
              ONLINE=$(curl -sf -H "Authorization: Bearer $GITHUB_PAT_VALUE" -H "Accept: application/vnd.github+json" "$RUNNERS_API?per_page=100" \
                | python3 -c 'import json,sys; d=json.load(sys.stdin); print(sum(1 for r in d.get("runners",[]) if r["status"] == "online" and r["name"].startswith("${var.github_runner_name_prefix}")))' \
                || echo 0)
              if [ "$ONLINE" -ge "$EXPECTED" ]; then
                echo "$ONLINE/$EXPECTED runner(s) online."
                break
              fi
              if [ "$SECONDS" -ge "$DEADLINE" ]; then
                echo "Timed out waiting for runner registration ($ONLINE/$EXPECTED online)."
                sudo docker compose logs --tail 50
                exit 1
              fi
              sleep 5
            done
          fi
        else
          echo "Skipping GitHub Runners"
        fi
      fi
    EOT
  }
}
