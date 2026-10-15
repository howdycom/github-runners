# GitHub runners on GCP

This stack runs ephemeral, Docker-capable GitHub Actions runners on Google Kubernetes Engine (GKE). It uses Google's [`gh-runner-gke`](https://github.com/terraform-google-modules/terraform-google-github-actions-runners/tree/v5.1.0/modules/gh-runner-gke) module, which installs GitHub's [Actions Runner Controller](https://github.com/actions/actions-runner-controller) (ARC).

Use it for heavy jobs, such as Docker image builds and tests that start service containers. The single-host stack in [`infra/`](../infra) stays as it is.

## What it creates

- A dedicated VPC, subnet, Cloud Router and Cloud NAT. Nodes have no public IP. The VPC has no peering or route to other workloads.
- A zonal GKE cluster with one autoscaling node pool (`n2-standard-4` by default).
- ARC in `dind` mode. Each job gets a new pod with its own Docker daemon. The pod is deleted when the job ends.
- One runner scale set (`gcp-heavy` by default), registered to a runner group you choose.

Workflows select these runners by the scale set name:

```yaml
jobs:
  build:
    runs-on: gcp-heavy
```

## How it scales

ARC scales runner pods with the job queue, from 0 up to `max_runners`. Each runner requests 3 CPUs and 10 GiB, so only one runner fits on an `n2-standard-4`. The GKE cluster autoscaler adds a node for each runner and removes idle nodes after about 10 minutes.

The pool keeps `min_nodes` (default 1) running. The module creates a single node pool and waits for the ARC controller to start, so the controller needs a node from the start. That node also takes jobs.

If you change `machine_type`, change `runner_cpu_request` and `runner_memory_request` with it. Keep the CPU request above half of the node's allocatable CPU.

## Prerequisites

1. **GitHub App.** An organization owner creates a GitHub App with the organization permission **Self-hosted runners: Read and write**, and installs it on the organization. See [Authenticating ARC with a GitHub App](https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners-with-actions-runner-controller/authenticating-to-the-github-api#authenticating-arc-with-a-github-app). Record the App ID and the installation ID, and generate a private key.
2. **Runner group.** An organization owner creates a runner group that public repositories cannot use, and limits it to the repositories that need these runners. Jobs run with a privileged Docker daemon, so a public repository must never reach them.
3. **GCP project.** Use a project dedicated to CI. You need permission to enable APIs and to create networks, GKE clusters and service accounts.
4. **Private key in Secret Manager.** Store the PEM file in the project:

   ```bash
   gcloud secrets create github-runners-app-key --replication-policy=automatic --project=<project>
   gcloud secrets versions add github-runners-app-key --data-file=app.private-key.pem --project=<project>
   ```

   Then delete the local PEM file.
5. **State bucket.** Create a private GCS bucket with uniform bucket-level access and versioning. The state holds the App private key, because the module writes it to a Kubernetes secret. Grant access only to the people who apply this stack.

## Apply

```bash
cd gcp
cp backend.hcl.example backend.hcl     # gitignored
cp gcp.tfvars.example gcp.tfvars       # gitignored
# Fill in both files.

gcloud auth application-default login
terraform init -backend-config=backend.hcl
terraform plan -var-file=gcp.tfvars
terraform apply -var-file=gcp.tfvars
```

After the apply, the scale set shows under **Organization settings → Actions → Runner groups → \<your group\>**.

Do not commit `backend.hcl` or `gcp.tfvars`. This repository is public.

## Security notes

- The `dind` container runs privileged. A job can take control of its node. Run only trusted repositories on these runners, and keep public repositories out of the runner group.
- The GKE control plane has a public endpoint. Access to it still requires Google IAM. Version 5.1.0 of the module cannot restrict it to authorized networks.
- Do not put production credentials in this project. Jobs execute pull request code.

## Known limits

- **Node disk.** Node boot disks use the GKE module default (100 GB `pd-standard`). `gh-runner-gke` 5.1.0 does not expose disk size or type.
- **Provider versions.** `gh-runner-gke` 5.1.0 requires the Google provider below 8 and the Helm provider 2.x. The lock file pins the versions in use.
- **Runner image.** `runner_image` defaults to `ghcr.io/actions/actions-runner:latest`, as the ARC chart does. GitHub refuses connections from deprecated runner versions, so a pinned tag goes dark when it ages out.
