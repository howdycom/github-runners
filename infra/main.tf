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

locals {
  is_ssh = startswith(var.docker_host, "ssh://")

  # Parse ssh://[user@]host[:port] properly instead of string-stripping, so a
  # non-default port or a user embedded in docker_host both work.
  ssh_target   = local.is_ssh ? replace(var.docker_host, "ssh://", "") : ""
  ssh_has_user = length(regexall("@", local.ssh_target)) > 0
  ssh_userinfo = local.ssh_has_user ? split("@", local.ssh_target)[0] : ""
  ssh_hostport = local.ssh_has_user ? split("@", local.ssh_target)[1] : local.ssh_target
  ssh_has_port = length(regexall(":", local.ssh_hostport)) > 0
  ssh_host     = local.ssh_has_port ? split(":", local.ssh_hostport)[0] : local.ssh_hostport
  ssh_port     = local.ssh_has_port ? split(":", local.ssh_hostport)[1] : "22"

  # A user in docker_host wins over var.ssh_user.
  ssh_user = local.ssh_userinfo != "" ? local.ssh_userinfo : var.ssh_user

  ssh_opts = "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
}

resource "null_resource" "bootstrap_docker" {
  triggers = {
    docker_host   = var.docker_host
    daemon_config = "v1"
    host_prep     = "v3-docker-install-zram-swap"
    zram_size_mib = var.zram_size_mib
    swap_size_gib = var.swap_size_gib
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<EOT
      set -e

      HOST_PREP_SCRIPT=$(cat <<'REMOTE_SCRIPT'
        set -e

        # --- Docker: install if missing, always start on boot ---
        if ! command -v docker >/dev/null 2>&1; then
          echo "Installing Docker..."
          sudo apt-get update
          sudo DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl gnupg < /dev/null
          sudo install -m 0755 -d /etc/apt/keyrings
          sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
          sudo chmod a+r /etc/apt/keyrings/docker.asc
          echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
          sudo apt-get update
          sudo DEBIAN_FRONTEND=noninteractive apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin < /dev/null
          sudo usermod -aG docker "$(id -un)" || true
        fi
        sudo systemctl enable --now docker

        # --- zRAM: compressed swap in RAM, used first (highest priority) ---
        sudo apt-get update
        sudo DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Options::=--force-confold install -y zram-tools < /dev/null
        printf 'ALGO=zstd\nSIZE=%s\nPRIORITY=100\n' "$ZRAM_SIZE_MIB" > /tmp/zramswap.conf
        if ! sudo cmp -s /tmp/zramswap.conf /etc/default/zramswap; then
          sudo cp /tmp/zramswap.conf /etc/default/zramswap
          sudo systemctl restart zramswap
        fi
        sudo systemctl enable --now zramswap

        # --- Swap file: lower priority, absorbs spikes beyond zRAM ---
        # Rebuild when absent, not a valid swap area, or the wrong size, so that
        # changing swap_size_gib on a later apply is actually honored.
        WANT_BYTES=$(( SWAP_SIZE_GIB * 1024 * 1024 * 1024 ))
        CUR_BYTES=$(sudo stat -c %s /swapfile 2>/dev/null || echo 0)
        CUR_TYPE=$(sudo blkid -o value -s TYPE /swapfile 2>/dev/null || true)
        if [ "$CUR_TYPE" != "swap" ] || [ "$CUR_BYTES" != "$WANT_BYTES" ]; then
          echo "Building /swapfile at $SWAP_SIZE_GIB GiB (was $CUR_BYTES bytes, type '$CUR_TYPE')..."
          sudo swapoff /swapfile 2>/dev/null || true
          sudo rm -f /swapfile
          sudo fallocate -l "$${SWAP_SIZE_GIB}G" /swapfile
          sudo chmod 600 /swapfile
          sudo mkswap /swapfile
        fi
        sudo swapon --show=NAME --noheadings | grep -qx /swapfile || sudo swapon -p 10 /swapfile
        grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw,pri=10 0 0' | sudo tee -a /etc/fstab > /dev/null
        echo 'vm.swappiness=100' | sudo tee /etc/sysctl.d/99-github-runners.conf > /dev/null
        sudo sysctl -q -p /etc/sysctl.d/99-github-runners.conf

        # --- Docker daemon config: rewrite + restart only when changed ---
        DAEMON_JSON='{"default-address-pools":[{"base":"10.0.0.0/8","size":24}]}'
        if [ ! -f /etc/docker/daemon.json ] || [ "$(sudo cat /etc/docker/daemon.json)" != "$DAEMON_JSON" ]; then
          echo "$DAEMON_JSON" | sudo tee /etc/docker/daemon.json > /dev/null
          sudo systemctl restart docker
        fi

        sudo mkdir -p /opt/portainer /opt/github-runner
        sudo chown -R 1000:1000 /opt/portainer /opt/github-runner || true
REMOTE_SCRIPT
      )

      # Host tuning values are passed as environment variables rather than
      # interpolated into the script body, so the remote script stays literal.
      ENV_PREFIX="ZRAM_SIZE_MIB=${var.zram_size_mib} SWAP_SIZE_GIB=${var.swap_size_gib}"

      if [ "${local.is_ssh}" = "true" ]; then
        printf 'export %s\n%s\n' "$ENV_PREFIX" "$HOST_PREP_SCRIPT" \
          | ssh ${local.ssh_opts} -p ${local.ssh_port} "${local.ssh_user}@${local.ssh_host}" 'bash -s'
      else
        printf 'export %s\n%s\n' "$ENV_PREFIX" "$HOST_PREP_SCRIPT" | bash -s
      fi
    EOT
  }
}

resource "null_resource" "deploy_stacks" {
  depends_on = [null_resource.bootstrap_docker]

  triggers = {
    docker_host = var.docker_host

    # Mirrored into triggers so the destroy-time provisioner can reach them:
    # destroy provisioners may only reference `self`.
    is_ssh   = local.is_ssh
    ssh_user = local.ssh_user
    ssh_host = local.ssh_host
    ssh_port = local.ssh_port

    enable_portainer      = var.enable_portainer
    enable_github_runners = var.enable_github_runners

    github_runner_heavy_count  = var.github_runner_heavy_count
    github_runner_light_count  = var.github_runner_light_count
    github_runner_org_url      = var.github_runner_org_url
    github_runner_token        = var.github_runner_token
    github_runner_heavy_labels = var.github_runner_heavy_labels
    github_runner_light_labels = var.github_runner_light_labels
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
      set -e

      DEPLOY_SCRIPT=$(cat <<'REMOTE_SCRIPT'
        set -e

        sudo mkdir -p /opt/portainer /opt/github-runner
        sudo chown -R 1000:1000 /opt/portainer /opt/github-runner || true

        sudo mv /tmp/portainer.docker-compose.yml /opt/portainer/docker-compose.yml
        sudo mv /tmp/github-runner.docker-compose.yml /opt/github-runner/docker-compose.yml
        sudo mv /tmp/github-runner.Dockerfile /opt/github-runner/Dockerfile
        sudo mv /tmp/github-runner.start.sh /opt/github-runner/start.sh
        sudo chmod +x /opt/github-runner/start.sh

        # The registration token lands only in this file, which is never
        # committed and is readable by root only.
        sudo install -m 600 /dev/null /opt/github-runner/.env
        sudo tee /opt/github-runner/.env > /dev/null <<ENV_FILE
GITHUB_ORG_URL=$GITHUB_ORG_URL
RUNNER_REGISTRATION_TOKEN=$RUNNER_REGISTRATION_TOKEN
RUNNER_HEAVY_LABELS=$RUNNER_HEAVY_LABELS
RUNNER_LIGHT_LABELS=$RUNNER_LIGHT_LABELS
RUNNER_HEAVY_REPLICAS=$RUNNER_HEAVY_REPLICAS
RUNNER_LIGHT_REPLICAS=$RUNNER_LIGHT_REPLICAS
RUNNER_NAME_PREFIX=$RUNNER_NAME_PREFIX
RUNNER_VERSION=$RUNNER_VERSION
DOCKER_GID=$(getent group docker | cut -d: -f3)
ENV_FILE

        echo "Configuring Firewall..."
        sudo ufw allow 22/tcp
        sudo ufw allow 8000/tcp
        sudo ufw allow 9000/tcp
        sudo ufw --force enable || true

        if [ "$ENABLE_PORTAINER" = "true" ]; then
          cd /opt/portainer
          sudo docker compose up -d
        else
          echo "Skipping Portainer"
        fi

        if [ "$ENABLE_GITHUB_RUNNERS" = "true" ]; then
          cd /opt/github-runner
          sudo docker compose down --remove-orphans || true
          # Replica counts come from deploy.replicas in the compose file (fed
          # from .env), so a later bare `docker compose up -d` keeps them.
          sudo docker compose up -d --build

          echo "Waiting for runners to register with GitHub..."
          TOTAL=$(sudo docker compose ps -q | wc -l | tr -d ' ')
          DEADLINE=$(( $(date +%s) + 300 ))
          REGISTERED=0
          while [ "$(date +%s)" -lt "$DEADLINE" ]; do
            REGISTERED=0
            for c in $(sudo docker compose ps -q); do
              if sudo docker logs "$c" 2>&1 | grep -q "Listening for Jobs"; then
                REGISTERED=$((REGISTERED + 1))
              fi
            done
            if [ "$REGISTERED" -ge "$TOTAL" ]; then
              break
            fi
            sleep 10
          done
          echo "$REGISTERED/$TOTAL runners registered."
          # Fail on ANY runner that did not come up, not just on a total wipeout.
          if [ "$REGISTERED" -lt "$TOTAL" ]; then
            echo "ERROR: only $REGISTERED of $TOTAL runners registered with GitHub."
            echo "A common cause is an expired registration token (1-hour TTL); generate a fresh one and re-run."
            echo "Recent logs:"
            sudo docker compose logs --tail 20
            exit 1
          fi
        else
          echo "Skipping GitHub Runners"
        fi
REMOTE_SCRIPT
      )

      # Values reach the remote shell as environment variables so that secrets
      # are never interpolated into the script text.
      export GITHUB_ORG_URL='${var.github_runner_org_url}'
      export RUNNER_REGISTRATION_TOKEN='${var.github_runner_token}'
      export RUNNER_HEAVY_LABELS='${var.github_runner_heavy_labels}'
      export RUNNER_LIGHT_LABELS='${var.github_runner_light_labels}'
      export RUNNER_HEAVY_REPLICAS='${var.github_runner_heavy_count}'
      export RUNNER_LIGHT_REPLICAS='${var.github_runner_light_count}'
      export RUNNER_NAME_PREFIX='${var.github_runner_name_prefix}'
      export RUNNER_VERSION='${var.github_runner_version}'
      export ENABLE_PORTAINER='${var.enable_portainer}'
      export ENABLE_GITHUB_RUNNERS='${var.enable_github_runners}'

      VARS="GITHUB_ORG_URL RUNNER_REGISTRATION_TOKEN RUNNER_HEAVY_LABELS RUNNER_LIGHT_LABELS RUNNER_HEAVY_REPLICAS RUNNER_LIGHT_REPLICAS RUNNER_NAME_PREFIX RUNNER_VERSION ENABLE_PORTAINER ENABLE_GITHUB_RUNNERS"

      if [ "${local.is_ssh}" = "true" ]; then
        scp ${local.ssh_opts} -P ${local.ssh_port} "${path.module}/stacks/portainer/docker-compose.yml" "${local.ssh_user}@${local.ssh_host}:/tmp/portainer.docker-compose.yml"
        scp ${local.ssh_opts} -P ${local.ssh_port} "${path.module}/stacks/github-runner/docker-compose.yml" "${local.ssh_user}@${local.ssh_host}:/tmp/github-runner.docker-compose.yml"
        scp ${local.ssh_opts} -P ${local.ssh_port} "${path.module}/stacks/github-runner/Dockerfile" "${local.ssh_user}@${local.ssh_host}:/tmp/github-runner.Dockerfile"
        scp ${local.ssh_opts} -P ${local.ssh_port} "${path.module}/stacks/github-runner/start.sh" "${local.ssh_user}@${local.ssh_host}:/tmp/github-runner.start.sh"

        # shellcheck disable=SC2086
        { for v in $VARS; do printf '%s=%q\n' "$v" "$${!v}"; done; printf 'export %s\n' "$VARS"; printf '%s\n' "$DEPLOY_SCRIPT"; } \
          | ssh ${local.ssh_opts} -p ${local.ssh_port} "${local.ssh_user}@${local.ssh_host}" 'bash -s'
      else
        cp "${path.module}/stacks/portainer/docker-compose.yml" /tmp/portainer.docker-compose.yml
        cp "${path.module}/stacks/github-runner/docker-compose.yml" /tmp/github-runner.docker-compose.yml
        cp "${path.module}/stacks/github-runner/Dockerfile" /tmp/github-runner.Dockerfile
        cp "${path.module}/stacks/github-runner/start.sh" /tmp/github-runner.start.sh

        printf '%s\n' "$DEPLOY_SCRIPT" | bash -s
      fi
    EOT
  }

  # Tear the host down on `terraform destroy` instead of leaving live runners
  # registered with the org. Destroy provisioners may only reference `self`,
  # hence the mirrored triggers above.
  provisioner "local-exec" {
    when        = destroy
    on_failure  = continue
    interpreter = ["/bin/bash", "-c"]
    command     = <<EOT
      set -e

      TEARDOWN_SCRIPT=$(cat <<'REMOTE_SCRIPT'
        set -e
        if [ -f /opt/github-runner/docker-compose.yml ]; then
          cd /opt/github-runner
          sudo docker compose down --remove-orphans || true
        fi
        if [ -f /opt/portainer/docker-compose.yml ]; then
          cd /opt/portainer
          sudo docker compose down --remove-orphans || true
        fi
        # Remove the file holding the registration token.
        sudo rm -f /opt/github-runner/.env
        echo "Stacks stopped. Host tuning (swapfile, zram, sysctl, daemon.json) left in place deliberately."
        echo "Runners may remain listed as offline in GitHub until garbage-collected (~14 days)."
REMOTE_SCRIPT
      )

      if [ "${self.triggers.is_ssh}" = "true" ]; then
        printf '%s\n' "$TEARDOWN_SCRIPT" | ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p ${self.triggers.ssh_port} "${self.triggers.ssh_user}@${self.triggers.ssh_host}" 'bash -s'
      else
        printf '%s\n' "$TEARDOWN_SCRIPT" | bash -s
      fi
    EOT
  }
}
