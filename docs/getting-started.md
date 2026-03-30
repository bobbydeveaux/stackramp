# Getting Started with Launchpad

## For Platform Operators (One-Time Setup)

A platform operator sets up the shared infrastructure once. After that, any developer in the org can deploy apps with zero infra knowledge.

### Prerequisites

- A GCP project (e.g., `my-platform-dev`)
- [Terraform](https://developer.hashicorp.com/terraform/install) installed
- [gcloud CLI](https://cloud.google.com/sdk/docs/install) installed and authenticated
- A GitHub org or user account

### Step 1: Clone Launchpad

```bash
git clone https://github.com/bobbydeveaux/launchpad
cd launchpad/providers/gcp/terraform/bootstrap
```

### Step 2: Configure

```bash
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`:
```hcl
platform_project = "my-platform-dev"
github_owner     = "my-github-org"
environment      = "dev"
region           = "europe-west1"
```

### Step 3: Bootstrap

```bash
terraform init
terraform apply
```

This creates:
- Artifact Registry for container images
- Workload Identity Federation for secretless GitHub Actions auth
- Platform service account with necessary IAM roles
- Terraform state bucket for per-app state

### Step 4: Set GitHub Variables

Terraform outputs the values you need. Set these as **GitHub Variables** (not secrets) at the org or repo level:

| Variable | Example |
|----------|---------|
| `LAUNCHPAD_PROVIDER` | `gcp` |
| `LAUNCHPAD_PROJECT` | `my-platform-dev` |
| `LAUNCHPAD_REGION` | `europe-west1` |
| `LAUNCHPAD_WIF_PROVIDER` | `projects/123/locations/global/workloadIdentityPools/launchpad-github-pool/providers/github-provider` |
| `LAUNCHPAD_SA_EMAIL` | `launchpad-cicd-sa@my-platform-dev.iam.gserviceaccount.com` |

Go to: GitHub → Settings → Secrets and variables → Actions → Variables

---

## For Developers (Every New App)

### Step 1: Create your repo structure

```
my-app/
├── frontend/      ← your React/Vite/Next app
├── backend/       ← your Python/Go/Node API
└── launchpad.yaml ← the only config you write
```

### Step 2: Write launchpad.yaml

```yaml
name: my-app

frontend:
  framework: react

backend:
  language: python
  port: 8080

database: false
```

### Step 3: Add one workflow file

Create `.github/workflows/deploy.yml`:

```yaml
name: Deploy
on:
  push:
    branches: [main]
  pull_request:

jobs:
  deploy:
    uses: bobbydeveaux/launchpad/.github/workflows/platform.yml@main
    secrets: inherit
```

### Step 4: Push to GitHub

```bash
git add -A
git commit -m "Initial deploy"
git push
```

That's it. The platform will:
1. Parse your `launchpad.yaml`
2. Detect what changed
3. Build and deploy your frontend and/or backend
4. Return live URLs

On pull requests, you'll get preview deployments with URLs posted as PR comments.
