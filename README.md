# GitHub Runners

This project manages a GitHub Actions runner host using Terraform and Docker, plus a Portainer UI for container management.

## Project Structure
```
infra/            # Terraform configuration
  bootstrap.sh    # Manual bootstrap script (optional)
  main.tf         # Main Terraform logic
  variables.tf    # Variable definitions
  outputs.tf      # Deployment outputs
  stacks/         # Docker Compose files grouped by purpose
    github-runner/  # GitHub Actions runner container build + entrypoint
    portainer/      # Portainer UI
```

## How Registration Works
Runner containers mint their own short-lived registration tokens at startup with `gh api` (`POST /orgs/{org}/actions/runners/registration-token`). On shutdown they mint a remove token the same way and deregister themselves.

The credential behind those calls comes from your local **gh CLI** by default: at apply time Terraform runs `gh auth token` on your machine, verifies it can mint runner tokens, and ships it to the host's `.env`. You never copy/paste a token. (Setting `github_runner_pat` explicitly overrides this, e.g. for CI.) This means:

- No manually generated registration token that expires after 1 hour — re-applies always work.
- No PAT to copy from the GitHub UI — `gh auth login` once, done.
- By default runners register as **ephemeral**: each job gets a clean environment, and GitHub automatically removes the runner record after the job finishes, so redeploys don't orphan offline runner entries.

Runners come in two tiers, each independently scalable with its own labels and resource limits:

| Tier  | Default labels               | Default limits |
|-------|------------------------------|----------------|
| heavy | `docker,ubuntu-22.04,heavy`  | 4 CPUs, 8 GB   |
| light | `docker,ubuntu-22.04,light`  | 1 CPU, 2 GB    |

## Prerequisites
- You must be an organization owner or have appropriate permissions to manage runners at the organization level.
- You need a server/VM with Docker installed (and `python3` + `curl`, present by default on Ubuntu — used by the post-deploy registration health check).
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

### 2. Deploy the Docker Environment with Terraform
Terraform copies a Dockerfile and start script to your server, builds the image, and starts the runner containers. After `docker compose up`, the apply waits until all expected runners report **online** in GitHub (configurable via `github_runner_registration_timeout`) and fails otherwise.

```bash
cd infra
terraform init
terraform apply \
  -var="docker_host=ssh://michael@192.168.86.42" \
  -var="ssh_user=michael" \
  -var="enable_portainer=true" \
  -var="enable_github_runners=true" \
  -var="github_runner_org_url=https://github.com/your-org" \
  -var="github_runner_heavy_count=1" \
  -var="github_runner_light_count=2"
```

No token variable needed — the credential is pulled from `gh auth token` automatically.

**Note:** replace `192.168.86.42` with your actual server IP. Ensure `github_runner_org_url` includes an organization or repository path (for example, `https://github.com/your-org` or `https://github.com/your-org/your-repo`), not just `https://github.com`.

### 3. Verify and Use
- Verify the runners are online: **Organization Settings → Actions → Runners**. Your new runners should be listed and show a green status icon (Idle). Ephemeral runners disappear from the list after finishing a job and re-register automatically when their container restarts.
- Use the runners in workflows by matching their tier labels:

```yaml
jobs:
  build:
    runs-on: [self-hosted, docker, ubuntu-22.04, heavy]
    steps:
      - uses: actions/checkout@v4
  lint:
    runs-on: [self-hosted, docker, ubuntu-22.04, light]
    steps:
      - uses: actions/checkout@v4
```

## Accessing Portainer
- **Portainer:** `http://<server-ip>:9000`

## System Prerequisites
Before running Terraform, ensure:
1. **SSH Access:** Keys are copied to the server (`ssh-copy-id`).
2. **Passwordless Sudo:** The user must be able to run sudo without a password for Terraform automation.
   Run this on the server (or via SSH) once:
   ```bash
   ssh -t michael@<server-ip> "echo 'michael ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/michael"
   ```

## Checking Logs
To check the logs of the GitHub runner containers, SSH into the server and run:

```bash
ssh michael@192.168.86.42 "sudo docker compose -f /opt/github-runner/docker-compose.yml logs -f"
```
