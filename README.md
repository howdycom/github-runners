# GitHub Runners

This project manages a GitHub Actions runner host using Terraform and Docker, plus a Portainer UI for container management.

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

## How Registration Works
Runner containers mint their own short-lived registration tokens at startup with `gh api` (`POST /orgs/{org}/actions/runners/registration-token`). On shutdown they mint a remove token the same way and deregister themselves.

The credential behind those calls comes from your local **gh CLI** by default: at apply time Terraform runs `gh auth token` on your machine, verifies it can mint runner tokens, and ships it to the host's `.env` (mode 600). You never copy/paste a token. (Setting `github_runner_pat` explicitly overrides this, e.g. for CI.) This means:

- No manually generated registration token that expires after 1 hour — re-applies always work.
- No PAT to copy from the GitHub UI — `gh auth login` once, done.
- By default runners register as **ephemeral**: each job gets a clean environment, and GitHub automatically removes the runner record after the job finishes, so redeploys don't orphan offline runner entries.

`start.sh` unsets the credential from the environment before starting the runner listener, so workflow jobs cannot read it. This matters because the listener passes its environment down to every job step — a step running `env` would otherwise print an org-scoped credential into the job log.

Runners come in two tiers, each independently scalable with its own labels and resource limits:

| Tier  | Default labels               | Default count | Default limits |
|-------|------------------------------|---------------|----------------|
| heavy | `docker,ubuntu-22.04,heavy`  | 2             | 4 CPUs, 8 GB   |
| light | `docker,ubuntu-22.04,light`  | 8             | 2 CPUs, 4 GB   |

The heavy tier matches a GitHub-hosted `ubuntu-latest` standard runner on CPU (4 vCPUs). Its memory is capped at 8 GB rather than the hosted 16 GB deliberately: **a `mem_limit` above physical RAM is never actually enforced**, so on a 16 GB host 16 GB would be a decorative number that lets one job exhaust the machine.

The light tier gets 2 CPUs because 1 was measurably too few. Under a real node build, cgroup counters showed a light runner throttled 362 times for 26.8 s against 78.5 s of CPU actually consumed — roughly a quarter of its CPU demand denied by the quota, on a host that was 96% idle. Memory went to 4 GB because the same job peaked at 1.35 GB, uncomfortably close to a 2 GB cap where Docker OOM-kills the job rather than slowing it.

Check for the same symptom on your own workloads before changing these:

```bash
for c in $(sudo docker ps -q --filter name=github-runner); do id=$(sudo docker inspect --format '{{.Id}}' "$c"); sudo cat "/sys/fs/cgroup/system.slice/docker-$id.scope/cpu.stat" | grep -E 'nr_throttled|throttled_usec'; done
```

> **`cpus` and `mem_limit` are ceilings, not reservations.** The defaults above deliberately oversubscribe a 16 GB / 16-thread box, so any single job can burst well beyond `RAM ÷ runners` while the fleet is mostly idle — which is the common case. The tradeoff is that many simultaneous jobs contend and push into zRAM/swap instead of each being throttled to a guaranteed slice.

## Prerequisites
- You must be an organization owner or have appropriate permissions to manage runners at the organization level.
- You need a server/VM running Ubuntu (24.04 LTS recommended). Docker, `python3`, and `curl` are installed automatically if missing.
- You need the **gh CLI** installed and authenticated on the machine running Terraform (or, alternatively, a fine-grained PAT passed via `github_runner_pat`).

## Step-by-Step Guide
### 1. Authenticate the gh CLI
```bash
gh auth login
```

Org-level runner registration needs the `admin:org` scope, which `gh auth login` does not grant by default. Add it once:

```bash
gh auth refresh -h github.com -s admin:org
```

(For a repo-scoped runner the default `repo` scope is sufficient.) Terraform verifies the credential can mint runner registration tokens before deploying and fails fast with a scope hint if it can't.

If you prefer not to use gh (e.g. in CI), create a fine-grained PAT with the org permission **Self-hosted runners: Read and write** (repo-scoped: **Administration: Read and write**) and pass it as `github_runner_pat`.

> **Important:** A single runner instance can only be registered to one scope (repository, organization, or enterprise) at a time. To share a runner across multiple repositories, register it at the organization level. `github_runner_org_url` accepts either an org URL (`https://github.com/your-org`) or a repo URL (`https://github.com/your-org/your-repo`); the containers pick the matching token API endpoint automatically.

### 2. Deploy with Terraform
Terraform bootstraps the host (Docker, zRAM, swap), copies the Dockerfile and start script to your server, builds the image, and starts the runner containers. After `docker compose up`, the apply waits until all expected runners report **online** in GitHub (configurable via `github_runner_registration_timeout`) and fails otherwise.

```bash
cd infra
terraform init
terraform apply \
  -var="docker_host=ssh://youruser@192.168.1.100" \
  -var="enable_portainer=true" \
  -var="enable_github_runners=true" \
  -var="github_runner_org_url=https://github.com/your-org" \
  -var="github_runner_heavy_count=2" \
  -var="github_runner_light_count=4"
```

No token variable needed — the credential is pulled from `gh auth token` automatically.

**Notes:**
- Replace `192.168.1.100` with your actual server IP and `youruser` with your SSH user. A non-default SSH port works too: `ssh://youruser@host:2222`. If you omit the user from the URL, pass it with `-var="ssh_user=youruser"`.
- Ensure `github_runner_org_url` includes an organization or repository path (for example, `https://github.com/your-org` or `https://github.com/your-org/your-repo`), not just `https://github.com`.
- Set `docker_host=unix:///var/run/docker.sock` to deploy to the local machine instead of over SSH.

### 3. Verify and Use
- Verify the runners are online: **Organization Settings → Actions → Runners**. Your new runners should be listed and show a green status icon (Idle). Ephemeral runners disappear from the list after finishing a job and re-register automatically when their container restarts.
- Use the runners in workflows by matching their tier labels:

```yaml
jobs:
  build:
    # Heavy Docker/build workloads
    runs-on: [self-hosted, docker, heavy]
    steps:
      - uses: actions/checkout@v4

  lint:
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
- **Registration health gate:** after `docker compose up`, the deploy polls the GitHub API until every expected runner reports `online`, and fails the apply on timeout. `docker compose up -d` exits 0 even when every container is crash-looping, so without this an apply could report success over a dead fleet.
- **Docker-capable runners:** the runner image ships the `docker` CLI, buildx, and compose plugins, and the deploy injects the host's `docker` group gid (`DOCKER_GID` in `.env`, used by `group_add`) so jobs can use the mounted Docker socket. Note that this grants jobs root-equivalent control of the host daemon — only run trusted workflows on these runners.
- **Credential is kept out of jobs:** see [How Registration Works](#how-registration-works). It is written only to `/opt/github-runner/.env`, mode 600, which is never committed.
- **Graceful shutdown:** `stop_grace_period: 120s` plus signal forwarding in `start.sh` lets in-flight jobs wind down and the runner deregister itself on `docker compose down`. `docker stop` signals PID 1 only, and bash defers traps while a foreground command runs, so the listener must be backgrounded for this to work at all.
- **Replica counts are durable:** counts are written to `.env` and consumed by `deploy.replicas` in the compose file, so running a bare `docker compose up -d` on the host (or acting through Portainer) does not collapse each tier to a single runner.
- **`terraform destroy` stops the stacks:** a destroy-time provisioner brings both compose stacks down — letting the containers deregister themselves — and removes the `.env` holding the credential. Host tuning (swapfile, zram, sysctl, `daemon.json`) is intentionally left in place.
- **Idempotent re-applies:** `daemon.json` and the zram config are only rewritten when their content changes, so a re-apply does not bounce dockerd and kill in-flight jobs.
- **Runner binary is baked into the image**, downloaded once at build time via the `RUNNER_VERSION` build arg rather than once per container at startup. With 10 runners that is 215 MB of downloads instead of 2.1 GB, and it keeps first-boot registration inside the health gate's window on a modest uplink.
- **Runners self-update.** `--disableupdate` is deliberately not passed: GitHub deprecates old runner versions and refuses their connections outright (`Runner version vX is deprecated and cannot receive messages`), which kills the listener on startup. `github_runner_version` therefore sets only the initial download, and the fleet heals itself instead of going dark when a version ages out. Bump it occasionally so fresh images start close to current.
- **apt waits for the dpkg lock** (`-o DPkg::Lock::Timeout=600`). Ubuntu's `unattended-upgrades` routinely holds it for minutes after boot, which would otherwise fail the bootstrap outright.
- **Disk pressure is handled in layers:** the bootstrap grows the root LV into any free VG space (Ubuntu defaults to a 100G LV even on much larger disks), caps journald at 500M, rotates container logs (`max-size 10m`, `max-file 3`), and installs a `disk-guard` cron (every 15 min) that prunes build cache/unused images once `/` passes 80% (more aggressively at 90%). Runner containers also wipe `_work`/`_diag` at startup so job leftovers can't accumulate across ephemeral jobs.

## Host Memory Tuning
The bootstrap step configures:
- **zRAM** (`zram-tools`, zstd, priority 100): compressed swap in RAM, used first. Size via `zram_size_mib` (default 8192).
- **Swap file** (`/swapfile`, priority 10): absorbs spikes beyond zRAM. Size via `swap_size_gib` (default 16). Changing this on a later apply rebuilds the file at the new size.
- **`vm.swappiness=100`**: encourages the kernel to use the (cheap) zRAM swap early.

Note that an integrated GPU can reserve a large slice of physical RAM in firmware, so `free -h` may report noticeably less than the installed total. Check it before sizing runner counts.
