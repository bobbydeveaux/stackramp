# StackRamp

> You commit code. The platform handles the rest.

StackRamp is an open-source, zero-config deployment platform delivered as a GitHub Action. Developers describe their app in a single YAML file, add one workflow, and push. The platform builds, provisions infrastructure, and deploys — no cloud console, no Terraform, no secrets.

## The Problem

Every new project requires the same bootstrapping ritual:

- Create GCP project(s) for dev/prod
- Set up Terraform state buckets
- Configure Workload Identity Federation for GitHub Actions
- Provision Firebase Hosting, Artifact Registry, Cloud Run
- Write 500+ lines of workflow YAML, find/replacing project names
- Repeat for every project, every developer

**StackRamp kills this entirely.**

## The Developer Experience

### Step 1: Create your repo

```
my-app/
├── frontend/      ← your React/Vite/Next app
├── backend/       ← your Python/Go/Node API
└── stackramp.yaml
```

### Step 2: Write stackramp.yaml

```yaml
name: my-app

frontend:
  framework: react
  sso: true         # optional — IAP-protected, served from Cloud Run

backend:
  language: python

database: false
storage: gcs        # optional — provisions a GCS bucket
```

### Step 3: Add one workflow file

```yaml
# .github/workflows/deploy.yml
name: Deploy
on:
  push:
    branches: [main]
  pull_request:
    types: [opened, synchronize, reopened, closed]
  workflow_dispatch:

jobs:
  deploy:
    permissions:
      id-token: write
      contents: read
      pull-requests: write
    uses: bobbydeveaux/stackramp/.github/workflows/platform.yml@main
    secrets: inherit
```

### Step 4: Push

That's it. The platform:
- Detects what changed (frontend, backend, or both)
- Builds your app using platform-provided or custom Dockerfiles
- Provisions cloud infrastructure (idempotently via Terraform)
- Deploys to dev, then promotes to prod on main
- On PRs: creates isolated preview environments (`{app}-pr-{number}`) with URLs posted as comments
- On PR close: automatically cleans up preview Cloud Run services and Firebase channels

**No GCP console. No Terraform. No secrets. No YAML beyond the above.**

## Architecture

```
Developer's Repo                  StackRamp                        Cloud
────────────────                  ────────                         ─────
stackramp.yaml  ──────►  platform.yml (reusable workflow)
deploy.yml                       │
                                 ├── parse config
                                 ├── detect changes
                                 ├── build frontend ──────►  Firebase Hosting
                                 └── build backend  ──────►  Cloud Run
```

Platform config lives in GitHub Variables (not secrets):

| Variable | Example |
|----------|---------|
| `STACKRAMP_PROJECT` | `my-platform-dev` |
| `STACKRAMP_REGION` | `europe-west1` |
| `STACKRAMP_WIF_PROVIDER` | `projects/123/locations/global/...` |
| `STACKRAMP_SA_EMAIL` | `stackramp-cicd-sa@project.iam...` |
| `STACKRAMP_DNS_ZONE` | `yourdomain-com` |
| `STACKRAMP_BASE_DOMAIN` | `yourdomain.com` |
| `STACKRAMP_IAP_DOMAIN` | `yourdomain.com` (for SSO) |
| `STACKRAMP_CLOUDSQL_CONNECTION` | `project:region:instance` |

## Quick Start

### For Operators (one-time)

```bash
git clone https://github.com/bobbydeveaux/stackramp
cd stackramp/providers/gcp/terraform/bootstrap
cp terraform.tfvars.example terraform.tfvars
# Edit with your GCP project, region, GitHub org
terraform init && terraform apply
# Set the output values as GitHub Variables
```

See the full [Operator Guide](docs/operator-guide.md).

### For Developers

1. Add `stackramp.yaml` to your repo root ([reference](docs/stackramp-yaml-reference.md))
2. Add `.github/workflows/deploy.yml` (see above)
3. Push to `main`
4. Check the Actions tab for your deploy URL

See the full [Getting Started guide](docs/getting-started.md).

## Multi-Cloud

StackRamp is built around a **provider abstraction**. The developer's `stackramp.yaml` never mentions a cloud provider — that's an operator concern.

```
providers/
├── gcp/           ← implemented (v1)
│   ├── terraform/
│   └── workflows/
├── aws/           ← coming soon
└── interface.md   ← provider contract
```

Adding AWS support means:
1. Implementing `providers/aws/`
2. Setting `STACKRAMP_PROVIDER=aws` in GitHub Variables
3. **Zero changes to any app's `stackramp.yaml`**

See the [Provider Interface](providers/interface.md) for details.

## Repository Structure

```
bobbydeveaux/stackramp/
├── README.md
├── INTEGRATION.md                    ← full integration guide
├── .github/workflows/
│   ├── platform.yml                  ← public entry point
│   ├── _frontend.yml                 ← reusable: frontend deploy
│   ├── _backend.yml                  ← reusable: backend deploy
│   └── _cleanup-preview.yml          ← reusable: PR preview cleanup
├── platform-action/
│   ├── action.yml                    ← config parser
│   ├── schema.json                   ← validation schema
│   └── dockerfiles/                  ← default Dockerfiles (Python, Go, Node)
├── providers/
│   ├── interface.md                  ← provider contract
│   └── gcp/
│       ├── terraform/bootstrap/      ← one-time platform setup
│       ├── terraform/platform/       ← per-app infra (Cloud Run, Firebase, IAP, DNS, GCS)
│       └── workflows/                ← GCP-specific actions
├── dashboard/                        ← StackRamp monitoring dashboard (dogfooded)
│   ├── backend/                      ← Go API — Cloud Run + Cloud DNS
│   └── frontend/                     ← React dashboard
├── docs/
│   ├── PRD.md
│   ├── HLD.md
│   ├── getting-started.md
│   ├── stackramp-yaml-reference.md
│   └── operator-guide.md
└── example-app/                      ← working example
```

## Supported Runtimes

| Frontend | Backend |
|----------|---------|
| React | Python (uvicorn) |
| Vue | Go |
| Next.js | Node.js |
| Static HTML | |

Custom `Dockerfile` in your backend directory is always supported as an override.

## Status

- [x] Platform architecture and provider abstraction
- [x] GCP bootstrap Terraform (WIF, Artifact Registry, IAM)
- [x] GCP per-app Terraform (Cloud Run, Firebase Hosting)
- [x] Reusable workflow — frontend deploy (Firebase Hosting)
- [x] Reusable workflow — backend deploy (Cloud Run)
- [x] Config parser + validation
- [x] Default Dockerfiles (Python, Go, Node)
- [x] Change detection (only deploy what changed)
- [x] PR preview deployments
- [x] Custom domain support (Cloud DNS, SSL auto-provisioned)
- [x] GCS storage bucket support
- [x] Cloud SQL (Postgres) with `DATABASE_URL` injected via Secret Manager
- [x] Platform secrets auto-injected from Secret Manager (label-based)
- [x] SSO via GCP IAP — Global HTTPS LB + Identity-Aware Proxy, opt-in per app
- [x] PR preview environments — isolated per PR, auto-cleanup on close
- [x] Deploy status dashboard — dogfooded on the platform at dashboard.stackramp.io
- [ ] AWS provider
- [ ] Documentation website

## License

MIT
