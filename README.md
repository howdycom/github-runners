# GitHub Runners

This project manages a GitHub Actions runner host using Terraform and Docker, plus a Portainer UI for container management.

Runners are deployed in two tiers:
- **Heavy** runners (label `heavy`) for Docker/build workloads — 2 by default.
- **Light** runners (label `light`) for lighter CI jobs — 4 by default.

Terraform also prepares the host itself: it installs Docker if missing (enabled to start on boot via `systemctl enable docker`), configures zRAM (8 GiB by default) plus an on-disk swap file (16 GiB by default) to absorb memory spikes, and sets `restart: unless-stopped` on all runner containers — so the machine recovers on its own after a reboot or power loss and re-registers the runners without manual intervention.

> **Note on unattended power-on:** the software side recovers by itself, but if the machine is fully powered off by an outage it still needs firmware to turn it back on. Set **Restore on AC Power Loss** (also called *AC Power Recovery*, *After Power Failure*, or *State after G3*) to **Power On** in BIOS, and disable **ErP / EuP Ready** if present — ErP cuts standby power and prevents auto-power-on regardless of that setting.

## Project Structure
```
infra/            # Terraform configuration
  bootstrap.sh    # Manual bootstrap script (optional — terraform apply does this too)
  main.tf         # Main Terraform logic
  variables.tf    # Variable definitions
  outputs.tf      # Deployment outputs
  stacks/         # Docker Compose files grouped by purpose
    github-runner/  # GitHub Actions runner container build + entrypoint (heavy + light services)
    portainer/      # Portainer UI
```

## Prerequisites
- You must be an organization owner or have appropriate permissions to manage runners at the organization level.
- You need a server/VM running Ubuntu (24.04 LTS recommended). Docker is installed automatically if missing.
- You will generate a time-limited **runner registration token** from the GitHub UI (or via the REST API) for authentication. **Note: registration tokens expire after 1 hour** — generate it right before running `terraform apply`.

## Step-by-Step Guide
### 1. Add the Runner to Your GitHub Organization
1. Navigate to your organization’s settings on GitHub.
2. In the left sidebar, click **Actions**, then click **Runners**.
3. Click **New self-hosted runner**.
4. Select the operating system (Linux) and architecture (x64).
5. Copy the time-limited **runner registration token** shown in the configuration command; you will use it in Terraform.

> **Important:** A single runner instance can only be registered to one scope (repository, organization, or enterprise) at a time. To share a runner across multiple repositories, register it at the organization level.

### 2. Deploy with Terraform
Terraform bootstraps the host (Docker, zRAM, swap), copies the Dockerfile and start script to your server, builds the image, and starts the runner containers.

```bash
cd infra
terraform init
terraform apply \
  -var="docker_host=ssh://youruser@192.168.1.100" \
  -var="enable_portainer=true" \
  -var="enable_github_runners=true" \
  -var="github_runner_org_url=https://github.com/your-org" \
  -var="github_runner_token=YOUR_REGISTRATION_TOKEN" \
  -var="github_runner_heavy_count=2" \
  -var="github_runner_light_count=4"
```

**Notes:**
- Replace `192.168.1.100` with your actual server IP and `youruser` with your SSH user. A non-default SSH port works too: `ssh://youruser@host:2222`. If you omit the user from the URL, pass it with `-var="ssh_user=youruser"`.
- Ensure `github_runner_org_url` includes an organization or repository path (for example, `https://github.com/your-org` or `https://github.com/your-org/your-repo`), not just `https://github.com`.
- Set `docker_host=unix:///var/run/docker.sock` to deploy to the local machine instead of over SSH.

### 3. Verify and Use
- Verify the runners are online: **Organization Settings → Actions → Runners**. You should see the heavy and light runners listed with a green status icon (Idle).
- Use the runners in workflows by matching their labels:

```yaml
jobs:
  build:
    # Heavy Docker/build workloads
    runs-on: [self-hosted, docker, heavy]
    steps:
      - uses: actions/checkout@v4

  test:
    # Lighter CI jobs
    runs-on: [self-hosted, docker, light]
    steps:
      - uses: actions/checkout@v4
```

## Accessing Portainer
- **Portainer:** `http://<server-ip>:9000`

On first launch you must create the admin account. Portainer 2.39+ requires a one-time setup token, printed in the container log, and it **seals itself roughly 5 minutes after start** if no admin has been created. To claim it:

```bash
ssh youruser@<server-ip> "sudo docker restart portainer && sleep 6 && sudo docker logs portainer 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -o 'setup_token=[a-f0-9]\{32,\}' | tail -1"
```

Use that token on the setup screen. It rotates on every restart, so only the most recent one is valid.

## System Prerequisites
Before running Terraform, ensure:
1. **SSH Access:** Keys are copied to the server (`ssh-copy-id`).
2. **Passwordless Sudo:** The user must be able to run sudo without a password for Terraform automation.
   Run this on the server (or via SSH) once:
   ```bash
   ssh -t youruser@<server-ip> "echo \"$(whoami) ALL=(ALL) NOPASSWD:ALL\" | sudo tee /etc/sudoers.d/$(whoami)"
   ```

## Checking Logs
To check the logs of the GitHub runner containers, SSH into the server and run:

```bash
ssh youruser@<server-ip> "sudo docker compose -f /opt/github-runner/docker-compose.yml logs -f"
```

## Deploy Behavior Notes
- **Registration health gate:** after `docker compose up`, the deploy waits (up to 5 minutes) for runners to log `Listening for Jobs`. If *any* runner fails to register, `terraform apply` fails loudly rather than reporting success over a partially dead fleet. The usual cause is an expired registration token.
- **Docker-capable runners:** the runner image ships the `docker` CLI, buildx, and compose plugins, and the deploy injects the host's `docker` group gid (`DOCKER_GID` in `.env`, used by `group_add`) so jobs can use the mounted Docker socket. Note that this grants jobs root-equivalent control of the host daemon — only run trusted workflows on these runners.
- **Token is kept out of jobs:** the registration token is passed as `RUNNER_REGISTRATION_TOKEN` (deliberately *not* `GITHUB_TOKEN`, which would collide with the per-job token GitHub injects), and `start.sh` unsets it from the environment before starting the listener, so workflow steps cannot read it. It is written only to `/opt/github-runner/.env`, mode 600, which is never committed.
- **Graceful shutdown:** `stop_grace_period: 120s` plus signal forwarding in `start.sh` lets in-flight jobs wind down and the runner attempt deregistration on `docker compose down`.
- **Replica counts are durable:** counts are written to `.env` and consumed by `deploy.replicas` in the compose file, so running a bare `docker compose up -d` on the host (or acting through Portainer) does not collapse each tier to a single runner.
- **`terraform destroy` stops the stacks:** a destroy-time provisioner brings both compose stacks down and removes the `.env` holding the token. Host tuning (swapfile, zram, sysctl, `daemon.json`) is intentionally left in place.

## Known Limitation: Runner Deregistration
`config.sh remove` requires a token from GitHub's separate *remove-token* endpoint, but this project only has the ~1-hour registration token, which has usually expired by the time containers stop. Deregistration is therefore **best-effort and normally fails**, leaving offline runner entries that GitHub garbage-collects after about 14 days. Because runner names derive from container hostnames (new on every recreate), `--replace` does not reclaim the old entries either.

The durable fix is to supply a fine-grained PAT or GitHub App credential (org permission: *self-hosted runners* read/write) and have each container mint its own registration and remove tokens at start/stop, ideally combined with `--ephemeral` runners so GitHub removes each record after a job.

## Host Memory Tuning
The bootstrap step configures:
- **zRAM** (`zram-tools`, zstd, priority 100): compressed swap in RAM, used first. Size via `zram_size_mib` (default 8192).
- **Swap file** (`/swapfile`, priority 10): absorbs spikes beyond zRAM. Size via `swap_size_gib` (default 16). Changing this on a later apply rebuilds the file at the new size.
- **`vm.swappiness=100`**: encourages the kernel to use the (cheap) zRAM swap early.

Note that an integrated GPU can reserve a large slice of physical RAM in firmware, so `free -h` may report noticeably less than the installed total. Check it before sizing runner counts.
