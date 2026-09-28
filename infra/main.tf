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

  # A user embedded in docker_host wins over var.ssh_user.
  ssh_user = local.ssh_userinfo != "" ? local.ssh_userinfo : var.ssh_user

  ssh_opts = "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
}

resource "null_resource" "bootstrap_docker" {
  triggers = {
    docker_host   = var.docker_host
    daemon_config = "v2-log-rotation"
    host_prep     = "v4-docker-install-zram-swap-disk-guard"
    zram_size_mib = var.zram_size_mib
    swap_size_gib = var.swap_size_gib
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<EOT
      set -e

      HOST_PREP=$(cat <<'REMOTE_SCRIPT'
        set -e

        # --- Root LV: grow into free VG space (Ubuntu defaults to a 100G LV
        # even on much larger disks; a full root takes the whole machine down).
        # -r resizes the filesystem online. No-op when the root is not on LVM
        # or no extents are free.
        if command -v lvextend >/dev/null 2>&1; then
          ROOT_SRC=$(findmnt -no SOURCE / 2>/dev/null || true)
          case "$ROOT_SRC" in
            /dev/mapper/*|/dev/dm-*)
              VG_NAME=$(sudo lvs --noheadings -o vg_name "$ROOT_SRC" 2>/dev/null | tr -d ' ' || true)
              FREE_EXTENTS=$(sudo vgs --noheadings -o vg_free_count "$VG_NAME" 2>/dev/null | tr -dc '0-9' || true)
              if [ -n "$VG_NAME" ] && [ -n "$FREE_EXTENTS" ] && [ "$FREE_EXTENTS" -gt 0 ]; then
                echo "Growing $ROOT_SRC into $FREE_EXTENTS free extents in $VG_NAME..."
                sudo lvextend -r -l +100%FREE "$ROOT_SRC"
              fi
              ;;
          esac
        fi

        # --- Docker: install if missing, always start on boot ---
        if ! command -v docker >/dev/null 2>&1; then
          echo "Installing Docker..."
          sudo apt-get -o DPkg::Lock::Timeout=600 update
          sudo DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 install -y ca-certificates curl gnupg < /dev/null
          sudo install -m 0755 -d /etc/apt/keyrings
          sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
          sudo chmod a+r /etc/apt/keyrings/docker.asc
          echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
          sudo apt-get -o DPkg::Lock::Timeout=600 update
          sudo DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin < /dev/null
          sudo usermod -aG docker "$(id -un)" || true
        fi
        sudo systemctl enable --now docker

        # python3 and curl back the post-deploy registration health gate.
        command -v python3 >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 || {
          sudo apt-get -o DPkg::Lock::Timeout=600 update
          sudo DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 install -y python3 curl < /dev/null
        }

        # --- zRAM: compressed swap in RAM, used first (highest priority) ---
        sudo apt-get -o DPkg::Lock::Timeout=600 update
        sudo DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 -o Dpkg::Options::=--force-confold install -y zram-tools < /dev/null
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

        # --- journald cap: bound log growth so it can never fill the disk ---
        printf '[Journal]\nSystemMaxUse=500M\nRuntimeMaxUse=200M\n' > /tmp/github-runners-journald.conf
        if ! sudo cmp -s /tmp/github-runners-journald.conf /etc/systemd/journald.conf.d/99-github-runners.conf; then
          sudo mkdir -p /etc/systemd/journald.conf.d
          sudo cp /tmp/github-runners-journald.conf /etc/systemd/journald.conf.d/99-github-runners.conf
          sudo systemctl restart systemd-journald
        fi

        # --- Disk guard: reclaim space automatically before pressure becomes
        # an outage. Only touches build cache, unused images, journals, and
        # caches — never running containers or checked-out jobs.
        sudo tee /usr/local/bin/disk-guard.sh > /dev/null <<'GUARD_EOF'
#!/bin/bash
USAGE=$(df --output=pcent / | tail -1 | tr -dc '0-9')
[ -z "$USAGE" ] && exit 0
if [ "$USAGE" -ge 80 ]; then
  logger -t disk-guard "/ at $USAGE%: pruning docker build cache, dangling images, journal"
  docker builder prune -af >/dev/null 2>&1 || true
  docker image prune -f >/dev/null 2>&1 || true
  journalctl --vacuum-size=200M >/dev/null 2>&1 || true
fi
if [ "$USAGE" -ge 90 ]; then
  logger -t disk-guard "/ at $USAGE%: aggressive reclaim (unused images, caches)"
  docker image prune -af >/dev/null 2>&1 || true
  docker system prune -f >/dev/null 2>&1 || true
  journalctl --vacuum-size=100M >/dev/null 2>&1 || true
  apt-get clean >/dev/null 2>&1 || true
  find /tmp /var/tmp -mindepth 1 -maxdepth 1 -mtime +7 -exec rm -rf {} + 2>/dev/null || true
fi
GUARD_EOF
        sudo chmod +x /usr/local/bin/disk-guard.sh
        printf '*/15 * * * * root /usr/local/bin/disk-guard.sh\n' | sudo tee /etc/cron.d/github-runners-disk-guard > /dev/null
        sudo chmod 644 /etc/cron.d/github-runners-disk-guard

        # --- Docker daemon config: rewrite + restart only when changed, so a
        # re-apply does not bounce dockerd and kill in-flight jobs ---
        # Log rotation is part of the disk defense: the default json-file
        # driver grows container logs without bound.
        DAEMON_JSON='{"default-address-pools":[{"base":"10.0.0.0/8","size":24}],"log-driver":"json-file","log-opts":{"max-size":"10m","max-file":"3"}}'
        if [ ! -f /etc/docker/daemon.json ] || [ "$(sudo cat /etc/docker/daemon.json)" != "$DAEMON_JSON" ]; then
          echo "$DAEMON_JSON" | sudo tee /etc/docker/daemon.json > /dev/null
          sudo systemctl restart docker
        fi

        sudo mkdir -p /opt/portainer /opt/github-runner
        sudo chown -R 1000:1000 /opt/portainer /opt/github-runner || true
REMOTE_SCRIPT
      )

      # Sizes are passed as environment variables so the remote script body
      # stays literal.
      PREFIX="export ZRAM_SIZE_MIB=${var.zram_size_mib} SWAP_SIZE_GIB=${var.swap_size_gib}"

      if [ "${local.is_ssh}" = "true" ]; then
        printf '%s\n%s\n' "$PREFIX" "$HOST_PREP" \
          | ssh ${local.ssh_opts} -p ${local.ssh_port} "${local.ssh_user}@${local.ssh_host}" 'bash -s'
      else
        printf '%s\n%s\n' "$PREFIX" "$HOST_PREP" | bash -s
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
      set -e

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

      # The credential travels in this file only — never interpolated into the
      # script text, and mode 600 on the host.
      ENV_TMP="$(mktemp)"
      chmod 600 "$ENV_TMP"
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
HEAVY_REPLICAS=${var.github_runner_heavy_count}
LIGHT_REPLICAS=${var.github_runner_light_count}
ENV_FILE

      DEPLOY=$(cat <<'REMOTE_SCRIPT'
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

        # The host's docker gid must be resolved here, not on the machine
        # running terraform, so the runner user can use the mounted socket.
        echo "DOCKER_GID=$(getent group docker | cut -d: -f3)" | sudo tee -a /opt/github-runner/.env > /dev/null

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

          EXPECTED=$(( HEAVY_COUNT + LIGHT_COUNT ))
          if [ "$EXPECTED" -gt 0 ]; then
            if ! command -v python3 >/dev/null; then
              echo "python3 is required on the host for the runner registration health gate."
              exit 1
            fi

            GITHUB_PAT_VALUE="$(sudo grep '^GITHUB_PAT=' /opt/github-runner/.env | cut -d= -f2-)"
            TARGET_PATH="$${GITHUB_ORG_URL_RAW#*://*/}"
            TARGET_PATH="$${TARGET_PATH%/}"
            if [[ "$TARGET_PATH" == */* ]]; then
              RUNNERS_API="https://api.github.com/repos/$TARGET_PATH/actions/runners"
            else
              RUNNERS_API="https://api.github.com/orgs/$TARGET_PATH/actions/runners"
            fi

            echo "Waiting for $EXPECTED runner(s) to come online..."
            DEADLINE=$((SECONDS + REGISTRATION_TIMEOUT))
            while true; do
              ONLINE=$(curl -sf -H "Authorization: Bearer $GITHUB_PAT_VALUE" -H "Accept: application/vnd.github+json" "$RUNNERS_API?per_page=100" \
                | NAME_PREFIX="$NAME_PREFIX" python3 -c 'import json,os,sys; d=json.load(sys.stdin); p=os.environ["NAME_PREFIX"]; print(sum(1 for r in d.get("runners",[]) if r["status"] == "online" and r["name"].startswith(p)))' \
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
      )

      # Non-secret settings the remote script needs, passed as env rather than
      # interpolated into its body.
      PREFIX=$(printf 'export ENABLE_PORTAINER=%q ENABLE_GITHUB_RUNNERS=%q HEAVY_COUNT=%q LIGHT_COUNT=%q REGISTRATION_TIMEOUT=%q NAME_PREFIX=%q GITHUB_ORG_URL_RAW=%q' \
        '${var.enable_portainer}' '${var.enable_github_runners}' '${var.github_runner_heavy_count}' '${var.github_runner_light_count}' \
        '${var.github_runner_registration_timeout}' '${var.github_runner_name_prefix}' '${var.github_runner_org_url}')

      if [ "${local.is_ssh}" = "true" ]; then
        SSH_DEST="${local.ssh_user}@${local.ssh_host}"
        scp ${local.ssh_opts} -P ${local.ssh_port} "${path.module}/stacks/portainer/docker-compose.yml" "$SSH_DEST:/tmp/portainer.docker-compose.yml"
        scp ${local.ssh_opts} -P ${local.ssh_port} "${path.module}/stacks/github-runner/docker-compose.yml" "$SSH_DEST:/tmp/github-runner.docker-compose.yml"
        scp ${local.ssh_opts} -P ${local.ssh_port} "${path.module}/stacks/github-runner/Dockerfile" "$SSH_DEST:/tmp/github-runner.Dockerfile"
        scp ${local.ssh_opts} -P ${local.ssh_port} "${path.module}/stacks/github-runner/start.sh" "$SSH_DEST:/tmp/github-runner.start.sh"
        scp ${local.ssh_opts} -P ${local.ssh_port} "$ENV_TMP" "$SSH_DEST:/tmp/github-runner.env"
        rm -f "$ENV_TMP"

        printf '%s\n%s\n' "$PREFIX" "$DEPLOY" \
          | ssh ${local.ssh_opts} -p ${local.ssh_port} "$SSH_DEST" 'bash -s'
      else
        cp "${path.module}/stacks/portainer/docker-compose.yml" /tmp/portainer.docker-compose.yml
        cp "${path.module}/stacks/github-runner/docker-compose.yml" /tmp/github-runner.docker-compose.yml
        cp "${path.module}/stacks/github-runner/Dockerfile" /tmp/github-runner.Dockerfile
        cp "${path.module}/stacks/github-runner/start.sh" /tmp/github-runner.start.sh
        mv "$ENV_TMP" /tmp/github-runner.env

        printf '%s\n%s\n' "$PREFIX" "$DEPLOY" | bash -s
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

      TEARDOWN=$(cat <<'REMOTE_SCRIPT'
        set -e
        # Containers deregister themselves on stop (start.sh mints a remove
        # token), so bring them down before deleting the credential.
        if [ -f /opt/github-runner/docker-compose.yml ]; then
          cd /opt/github-runner
          sudo docker compose down --remove-orphans || true
        fi
        if [ -f /opt/portainer/docker-compose.yml ]; then
          cd /opt/portainer
          sudo docker compose down --remove-orphans || true
        fi
        sudo rm -f /opt/github-runner/.env
        echo "Stacks stopped and credential removed."
        echo "Host tuning (swapfile, zram, sysctl, daemon.json) left in place deliberately."
REMOTE_SCRIPT
      )

      # Read triggers with lookup() defaults: a resource created before these
      # keys existed is still in state without them, and Terraform evaluates
      # destroy provisioners against that older state.
      IS_SSH='${lookup(self.triggers, "is_ssh", "")}'
      SSH_HOST='${lookup(self.triggers, "ssh_host", "")}'
      SSH_USER='${lookup(self.triggers, "ssh_user", "")}'
      SSH_PORT='${lookup(self.triggers, "ssh_port", "22")}'

      if [ "$IS_SSH" = "true" ] && [ -n "$SSH_HOST" ]; then
        printf '%s\n' "$TEARDOWN" | ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "$SSH_PORT" "$SSH_USER@$SSH_HOST" 'bash -s'
      elif [ "$IS_SSH" = "true" ]; then
        echo "Skipping remote teardown: this resource predates the ssh_host trigger, so the target host is unknown."
        echo "Stop the stacks manually if needed: docker compose -f /opt/github-runner/docker-compose.yml down"
      else
        printf '%s\n' "$TEARDOWN" | bash -s
      fi
    EOT
  }
}
