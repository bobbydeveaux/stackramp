# Getting Started with StackRamp

## For Platform Operators (One-Time Setup)

A platform operator sets up the shared infrastructure once. After that, any developer in the org can deploy apps with zero infra knowledge.

### Prerequisites

- A GCP project (e.g., `my-platform-dev`)
- [Terraform](https://developer.hashicorp.com/terraform/install) installed
- [gcloud CLI](https://cloud.google.com/sdk/docs/install) installed and authenticated
- A GitHub org or user account

### Step 1: Clone StackRamp

```bash
git clone https://github.com/bobbydeveaux/stackramp
cd stackramp/providers/gcp/terraform/bootstrap
```

### Step 2: Configure

```bash
cp dev.tfvars.example dev.tfvars
```

Edit `dev.tfvars`:
```hcl
platform_project = "my-platform-dev"
github_owner     = "my-github-org"
environment      = "dev"
region           = "europe-west1"

# Optional: set a base domain to enable custom subdomains for all apps
# base_domain = "myapp.io"
```

### Step 3: Bootstrap

```bash
./bootstrap.sh dev
```

The script will:
1. Check your `gcloud` auth and application default credentials
2. Create the GCS state bucket via `gsutil` (Terraform uses remote state from run 1 — no local state ever)
3. Write `backend.tf` pointing at the bucket
4. Run `terraform init / plan / apply`
5. Print the GitHub Variables to set

This creates:
- Artifact Registry for container images
- Workload Identity Federation for secretless GitHub Actions auth
- Platform service account with necessary IAM roles
- Terraform state bucket for per-app state
- Cloud DNS managed zone (if `base_domain` is set)

### Step 4: Set GitHub Variables

Terraform outputs the exact values. Set these as **GitHub Variables** (not secrets) at the org or repo level:

| Variable | Example |
|----------|---------|
| `STACKRAMP_PROVIDER` | `gcp` |
| `STACKRAMP_PROJECT` | `my-platform-dev` |
| `STACKRAMP_REGION` | `europe-west1` |
| `STACKRAMP_WIF_PROVIDER` | `projects/123/.../providers/github-provider` |
| `STACKRAMP_SA_EMAIL` | `stackramp-cicd-sa@my-platform-dev.iam.gserviceaccount.com` |
| `STACKRAMP_BASE_DOMAIN` | `myapp.io` _(only if base_domain set)_ |
| `STACKRAMP_DNS_ZONE` | `myapp-io` _(only if base_domain set)_ |

Go to: GitHub → Settings → Secrets and variables → Actions → Variables

### Step 5 (if using a custom domain): Delegate nameservers

If you set `base_domain`, bootstrap will create a Cloud DNS managed zone and print its nameservers. Point your domain registrar at those nameservers. This only needs to be done once — all subdomains and apps are covered automatically after this.

---

## For Developers (Every New App)

### Step 1: Create your repo structure

```
my-app/
├── frontend/      ← your React/Vite/Next app
├── backend/       ← your Python/Go/Node API
└── stackramp.yaml ← the only config you write
```

### Step 2: Write stackramp.yaml

```yaml
name: my-app

frontend:
  framework: react

backend:
  language: python
  port: 8080

database: false
```

To use a custom domain, add a `domain` field:

```yaml
name: my-app
domain: my-app.io          # explicit root domain

# OR — if the platform has STACKRAMP_BASE_DOMAIN set,
# your app automatically gets my-app.myapp.io with no extra config
```

### Step 3: Add one workflow file

Create `.github/workflows/deploy.yml`:

```yaml
name: Deploy
on:
  push:
    branches: [main]
  pull_request:
    # `closed` is required: without it the PR preview cleanup never runs
    types: [opened, synchronize, reopened, closed]
  workflow_dispatch:

jobs:
  deploy:
    permissions:
      id-token: write       # required for WIF / GCP auth
      contents: read        # required to checkout code
      pull-requests: write  # required to post PR preview URLs
    uses: bobbydeveaux/stackramp/.github/workflows/platform.yml@main
    secrets: inherit
```

### Step 4: Push to GitHub

```bash
git add -A
git commit -m "Initial deploy"
git push
```

That's it. The platform will:
1. Parse your `stackramp.yaml`
2. Detect what changed (frontend / backend / both)
3. Provision infra (Firebase Hosting site, Cloud Run service, custom domain + DNS if configured)
4. Build and deploy only what changed
5. Return live URLs

On pull requests, you'll get preview deployments with URLs posted as PR comments.
