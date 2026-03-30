# Operator Guide

This guide covers how to set up, manage, and operate a Launchpad platform environment.

## What is an Operator?

A Launchpad operator is someone who manages the shared cloud infrastructure that apps deploy to. Typically this is a senior engineer, platform team member, or the org admin.

Developers using Launchpad never need to be operators — they just write code and push.

## Setting Up a New Environment

### Prerequisites

- GCP project with billing enabled
- `gcloud` CLI authenticated as a project owner
- Terraform >= 1.5
- GitHub org or user account

### Bootstrap

```bash
cd providers/gcp/terraform/bootstrap
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your values
terraform init
terraform apply
```

The bootstrap creates:
- **Artifact Registry** (`launchpad-images`) — shared container registry
- **Service Account** (`launchpad-cicd-sa`) — used by all app deployments
- **Workload Identity Federation** (`launchpad-github-pool`) — secretless auth from GitHub Actions
- **IAM bindings** — Cloud Run, Firebase, Artifact Registry, Secret Manager permissions
- **GCS bucket** (`{project}-tf-state`) — per-app Terraform state

### Setting GitHub Variables

After bootstrap, set these as GitHub **Variables** (not secrets) at the org level:

```
LAUNCHPAD_PROVIDER=gcp
LAUNCHPAD_PROJECT=<your-gcp-project>
LAUNCHPAD_REGION=<your-region>
LAUNCHPAD_WIF_PROVIDER=<from terraform output>
LAUNCHPAD_SA_EMAIL=<from terraform output>
```

Setting at the org level means all repos in the org can deploy automatically.

## Managing Apps

### How Apps Are Provisioned

When a developer pushes code with a `launchpad.yaml`, the platform:
1. Parses the config
2. Detects what changed (frontend/backend/both)
3. Builds and deploys only what changed

Infrastructure is created idempotently — running it multiple times is safe.

### Naming Conventions

All resources follow a consistent naming scheme within the shared project:

| Resource | Pattern | Example |
|----------|---------|---------|
| Cloud Run service | `{app-name}-{env}` | `my-app-dev` |
| Firebase site | `{app-name}-{env}` | `my-app-dev` |
| Container image | `launchpad-images/{app-name}:{sha}` | `launchpad-images/my-app:abc1234` |
| TF state prefix | `{app-name}-{env}/` | `my-app-dev/` |

### Monitoring

- **Cloud Run**: GCP Console → Cloud Run → view services, logs, metrics
- **Firebase Hosting**: Firebase Console → Hosting → view sites, release history
- **Artifact Registry**: GCP Console → Artifact Registry → view images

## Multi-Environment Setup

Run bootstrap twice with different `terraform.tfvars`:

```bash
# Dev environment
platform_project = "my-platform-dev"
environment      = "dev"

# Prod environment
platform_project = "my-platform-prod"
environment      = "prod"
```

The platform workflow automatically deploys to dev on every push and promotes to prod on main branch pushes.

## Security Model

- **No GitHub secrets** — authentication uses OIDC/Workload Identity Federation
- **No long-lived credentials** — the GitHub Actions runner proves its identity cryptographically
- **Scoped access** — the WIF pool only trusts repos from your GitHub org/user
- **Shared service account** — one SA handles all deployments; per-app SA is a future enhancement
- **GitHub Variables are not secrets** — knowing them without a valid OIDC token gives no access

## Adding AWS Support (Future)

1. Implement `providers/aws/` following the [provider interface](../providers/interface.md)
2. Run `providers/aws/terraform/bootstrap/`
3. Set `LAUNCHPAD_PROVIDER=aws` in GitHub Variables
4. Apps deploy to AWS with zero changes to `launchpad.yaml`
