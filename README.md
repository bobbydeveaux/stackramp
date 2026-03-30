# Launchpad

> You commit code. The platform handles the rest.

Launchpad is an open-source, zero-config deployment platform delivered as a GitHub Action. Developers describe their app in a single YAML file, add one workflow, and push. The platform builds, provisions infrastructure, and deploys — no cloud console, no Terraform, no secrets.

## The Problem

Every new project requires the same bootstrapping ritual:

- Create GCP project(s) for dev/prod
- Set up Terraform state buckets
- Configure Workload Identity Federation for GitHub Actions
- Provision Firebase Hosting, Artifact Registry, Cloud Run
- Write 500+ lines of workflow YAML, find/replacing project names
- Repeat for every project, every developer

**Launchpad kills this entirely.**

## The Developer Experience

### Step 1: Create your repo

```
my-app/
├── frontend/      ← your React/Vite/Next app
├── backend/       ← your Python/Go/Node API
└── launchpad.yaml
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

```yaml
# .github/workflows/deploy.yml
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

### Step 4: Push

That's it. The platform:
- Detects what changed (frontend, backend, or both)
- Builds your app
- Provisions cloud infrastructure (idempotently)
- Deploys and returns live URLs
- On PRs: creates preview deployments with URLs posted as comments

**No GCP console. No Terraform. No secrets. No YAML beyond the above.**

## Architecture

```
Developer's Repo                  Launchpad                        Cloud
────────────────                  ────────                         ─────
launchpad.yaml  ──────►  platform.yml (reusable workflow)
deploy.yml                       │
                                 ├── parse config
                                 ├── detect changes
                                 ├── build frontend ──────►  Firebase Hosting
                                 └── build backend  ──────►  Cloud Run
```

Platform config lives in GitHub Variables (not secrets):

| Variable | Example |
|----------|---------|
| `LAUNCHPAD_PROVIDER` | `gcp` |
| `LAUNCHPAD_PROJECT` | `my-platform-dev` |
| `LAUNCHPAD_REGION` | `europe-west1` |
| `LAUNCHPAD_WIF_PROVIDER` | `projects/123/locations/global/...` |
| `LAUNCHPAD_SA_EMAIL` | `launchpad-cicd-sa@project.iam...` |

## Quick Start

### For Operators (one-time)

```bash
git clone https://github.com/bobbydeveaux/launchpad
cd launchpad/providers/gcp/terraform/bootstrap
cp terraform.tfvars.example terraform.tfvars
# Edit with your GCP project, region, GitHub org
terraform init && terraform apply
# Set the output values as GitHub Variables
```

See the full [Operator Guide](docs/operator-guide.md).

### For Developers

1. Add `launchpad.yaml` to your repo root ([reference](docs/launchpad-yaml-reference.md))
2. Add `.github/workflows/deploy.yml` (see above)
3. Push to `main`
4. Check the Actions tab for your deploy URL

See the full [Getting Started guide](docs/getting-started.md).

## Multi-Cloud

Launchpad is built around a **provider abstraction**. The developer's `launchpad.yaml` never mentions a cloud provider — that's an operator concern.

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
2. Setting `LAUNCHPAD_PROVIDER=aws` in GitHub Variables
3. **Zero changes to any app's `launchpad.yaml`**

See the [Provider Interface](providers/interface.md) for details.

## Repository Structure

```
bobbydeveaux/launchpad/
├── README.md
├── launchpad.yaml.example
├── .github/workflows/
│   └── platform.yml              ← public entry point
├── platform-action/
│   ├── action.yml                ← config parser
│   ├── schema.json               ← validation schema
│   └── dockerfiles/              ← default Dockerfiles
├── providers/
│   ├── interface.md              ← provider contract
│   └── gcp/
│       ├── terraform/bootstrap/  ← one-time setup
│       ├── terraform/platform/   ← per-app infra
│       └── workflows/            ← GCP-specific actions
├── docs/
│   ├── PRD.md
│   ├── HLD.md
│   ├── getting-started.md
│   ├── launchpad-yaml-reference.md
│   └── operator-guide.md
└── example-app/                  ← working example
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
- [ ] Database injection (Cloud SQL)
- [ ] AWS provider
- [ ] Custom domain support
- [ ] Deploy status dashboard

## License

MIT
