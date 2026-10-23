# GitHub runners on GCP

This stack runs self-hosted GitHub Actions runners on Google Cloud. Each job gets its own Compute Engine VM, which is deleted after the job. Nothing runs when no jobs are queued.

The single-host stack in [`infra/`](../infra) does not change.

## How it works

1. A job with `runs-on: [self-hosted, gcp-x64]` is queued. GitHub sends a signed `workflow_job` webhook to the **webhook** function (Cloud Run functions).
2. The function checks the signature, the organization, the job's labels and that the repository is private.
3. It asks GitHub for a just-in-time (JIT) runner config. The config registers one ephemeral runner for one job.
4. It creates a VM from the instance template and passes the JIT config as instance metadata.
5. The VM's startup script runs the runner. The runner takes one job, and the VM powers off.
6. When GitHub reports the job as completed, the function deletes the VM.

A **reconcile** function runs every minute. It:

- deletes VMs that powered off;
- deletes VMs whose runner never took a job (for example, the job was cancelled while the VM booted);
- removes runner registrations whose VM no longer exists;
- creates up to 40 VMs for jobs in `repositories` queued for more than 45 seconds that no free VM will take. It sends each create and does not wait for the VM to boot. This covers lost webhooks, zones without capacity and a full pool.

Compute Engine also deletes every VM after `max_vm_lifetime_hours` (default 6, GitHub's default job timeout), whatever happens to the job or the controller. A job still running then fails as a lost runner, not as a timeout. Set `timeout-minutes` below that limit on jobs that use these runners, so a stuck job fails with a clear timeout and frees its VM sooner.

## Credentials

| From → to | How |
| --- | --- |
| GitHub → GCP | GitHub App webhook, signed with HMAC-SHA256 using the webhook secret. The function rejects any request without a valid signature. |
| GCP → GitHub | The functions authenticate as the GitHub App with short-lived installation tokens (1 hour). The App private key stays in Secret Manager. |
| GCP → VM | The VM receives only its JIT runner config. It is valid for one runner and one job. |
| VM → GCP | None. VMs have no service account, so job code cannot get a GCP token. |

VMs accept no inbound traffic: the network has no ingress firewall rules, so the implied deny-all rule applies.

The controller has a custom Compute Engine role with only the permissions it calls: create, read and delete instances and disks, read the instance template and image, use the subnet, and read operations. It has no permission on instance groups. An IAM condition limits instances and disks to names that start with `<prefix>-`. The internet-facing webhook cannot change or delete any other VM in the project.

## Network

Each VM gets an ephemeral public IP for outbound traffic: GitHub, package mirrors and container registries. It has no inbound access.

Many organizations enforce the policy `constraints/compute.vmExternalIpAccess`, which forbids external IPs on VMs. With that policy, the controller cannot create any runner VM. Set `use_cloud_nat = true` for those projects: VMs then have no public IP and reach the internet through Cloud NAT. The default (`false`) creates no router or NAT gateway. Cloud NAT adds an hourly charge per VM and a charge per GB processed.

## Machine size

Two pools. A job selects one with its `runs-on` label. A VM registers only that pool's label, so a heavy VM cannot take a standard job.

| Pool | Label | Default machine | Image family |
| --- | --- | --- | --- |
| Standard | `gcp-x64` | `n2d-standard-2` (2 vCPU, 8 GB) | `github-runner` |
| Heavy | `gcp-x64-heavy` | off until you set `heavy_machine_type` | `github-runner-heavy` |

`e2-standard-2` costs about 20% less than `n2d-standard-2`, but build times vary more. For the heavy pool use an 8 vCPU type: `e2-standard-8` costs less, and `n2-standard-8` is faster per core. In `us-central1`, `n2` and `n2d` have run out of capacity in some zones while `e2` still had it.

`heavy_fallback_machine_types` lists other machine types for the heavy pool. The controller tries every zone with `heavy_machine_type` first, and moves to the next type only when no zone has capacity for it. Each type gets its own instance template with the heavy image and label.

```hcl
heavy_machine_type           = "e2-standard-8"
heavy_fallback_machine_types = ["n2-standard-8"]
```

Each pool has its own cap: `max_vms` and `max_heavy_vms`. A fallback VM counts against `max_heavy_vms`. Check the regional CPU quota for each machine type separately. N2 and E2 quotas are not the same number.

The VMs of one pool are interchangeable. GitHub gives a new runner any queued job with its label, not the job its VM is named after. So reconcile counts each VM whose runner is not busy as a free runner for one queued job of its pool, and starts a VM for each queued job left over. A job whose own VM took another job gets a VM named `<prefix>-<job id>-2`.

```yaml
jobs:
  test:
    runs-on: [self-hosted, gcp-x64-heavy]
  build:
    runs-on: [self-hosted, gcp-x64]
```

## Prerequisites

1. **GitHub App.** An organization owner creates a GitHub App:
   - Organization permission **Self-hosted runners: Read and write**.
   - Repository permission **Actions: Read**.
   - Webhook active, subscribed to **Workflow job** events. The URL comes from the first apply; use a placeholder until then.
   - A webhook secret (a long random string).

   Install it on the organization, and note the App ID and the installation ID. Generate a private key.
2. **Runner group.** Create a runner group that public repositories cannot use, and limit it to the repositories that use these runners. The controller refuses to register runners in a group that allows public repositories.
3. **GCP project.** Use a project dedicated to CI. Check the regional CPU quota: `max_vms` × the machine's vCPUs.
4. **Secrets.** Store the App private key and the webhook secret in Secret Manager in that project:

   ```bash
   gcloud secrets create github-runners-app-key --data-file=app.private-key.pem --project=<project>
   printf '%s' '<webhook secret>' | gcloud secrets create github-runners-webhook-secret --data-file=- --project=<project>
   ```

   Then delete the local PEM file.
5. **State bucket.** Create a private GCS bucket for Terraform state, with versioning.
6. **Public invoker.** GitHub calls the webhook function without Google credentials, so the function allows `allUsers` to invoke it. If an organization policy restricts IAM members to your domain, allow an exception for this project.

## Deploy

`gcp/` is a Terraform module. The caller sets the backend and the `google` provider. [`example/`](example) is a minimal root that does both, so you can deploy straight from this repository.

First build the VM image. Standard VMs boot from the newest image in the `github-runner` family, with Docker and the runner already installed. Use the same `runner_version` and `runner_sha256` as the module (see `variables.tf` for the defaults):

```bash
cd gcp/example
../bake-image.sh <project> <zone> <runner_version> <runner_sha256>
```

The heavy pool needs its own family before you set `heavy_machine_type`. The install is the same. The script still builds it on a small `e2-standard-2`. The 8 vCPUs come from the instance template, not from the image.

```bash
../bake-image.sh <project> <zone> <runner_version> <runner_sha256> "" github-runner-heavy
```

Bake the heavy family before the apply that creates the heavy template. Terraform resolves the image family when it creates the template.

The script builds the image in a temporary network with a public IP, then deletes the network. If an organization policy forbids external IPs, set `use_cloud_nat = true` in the module call, apply the network first, then pass the stack's subnet as the fifth argument:

```bash
terraform apply -var-file=gcp.tfvars -target=module.runners.google_compute_router_nat.runners
../bake-image.sh <project> <zone> <runner_version> <runner_sha256> "$(terraform output -raw subnet)"
```

Re-run both bake commands monthly for OS and Docker updates. New VMs use the new image in that family at once. A rebuild of `github-runner` does not change heavy VMs, and the reverse.

Then deploy the stack:

```bash
cp backend.hcl.example backend.hcl     # gitignored
cp gcp.tfvars.example gcp.tfvars       # gitignored
# Fill in both files. Optional settings go in the module call in main.tf.

terraform init -backend-config=backend.hcl
terraform apply -var-file=gcp.tfvars
```

Set the `webhook_url` output as the GitHub App's webhook URL. Then point a workflow at the runners:

```yaml
jobs:
  build:
    runs-on: [self-hosted, gcp-x64]
```

Do not commit `backend.hcl` or `gcp.tfvars`. This repository is public.

### Deploy from another repository

To keep your real values in a private repository, copy `example/` there and point the module at a pinned version of this repository:

```hcl
module "runners" {
  source = "git::https://github.com/<org>/github-runners.git//gcp?ref=<commit or tag>"
  # inputs as in example/main.tf
}
```

To upgrade, change `ref`. The state stays in the backend you configure in that repository.

## What a VM provides

Ubuntu 24.04 with Docker Engine, buildx and Compose, git, curl, jq, zip, zstd, Python 3 and build-essential. The job runs as user `runner`, with Docker access and passwordless sudo, as on GitHub-hosted runners. Other tools come from setup actions (`actions/setup-node` and others).

## Edge cases

- **Duplicate webhooks.** The VM is named `<prefix>-<job id>`, so a second delivery finds the VM and does nothing.
- **A zone without capacity.** The function tries the next zone. If every zone is full, the reconcile job retries.
- **A runner that takes another job.** Any idle runner with the label can take any queued job. Every queued job still gets a VM, so the counts stay equal.
- **Failures while creating a VM.** The function removes the runner registration it created, so no orphan runner is left behind.
- **Limits.** The function stops creating VMs at `max_vms`; the reconcile job starts the rest when VMs free up. Every function instance checks the count and sends the create request while holding one lock, an object in a GCS bucket, so concurrent webhooks cannot exceed the limit.
- **Removing an idle runner.** Before deleting an idle VM, the controller removes its runner registration and deletes the VM only if GitHub accepts. A runner that takes a job in the same instant can still lose it; the job then fails and needs a re-run.

## Costs

You pay for each VM only while its job runs, plus its disk and ephemeral IP. The functions, scheduler and secrets fit in the free tiers at normal volumes. See [Network](#network) for the cost of Cloud NAT.
