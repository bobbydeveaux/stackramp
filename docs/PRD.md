# Launchpad — Product Requirements Document

**Version:** 0.1  
**Status:** Draft  
**Owner:** Bobby Deveaux  
**Last updated:** 2026-03-31

---

## 1. Problem Statement

Every new project at BobbyJason (and Toucanberry) requires the same ~2-hour bootstrapping ritual before a single line of product code can be deployed:

- Create GCP project(s) — typically dev/uat/prod
- Set up Terraform state buckets
- Configure Workload Identity Federation for GitHub Actions
- Provision Firebase Hosting, Artifact Registry, Cloud Run
- Write and wire up 500+ lines of workflow YAML, find/replacing project names throughout
- Repeat for every developer on every project

This creates a high barrier to entry for new projects, discourages experimentation, and wastes experienced developer time on infrastructure boilerplate rather than product work.

The same problem exists at Toucanberry: creative developers have nowhere easy to deploy their ideas.

---

## 2. Goals

### Must Have (v1 POC)
- A developer can deploy a frontend + backend app with **zero infrastructure knowledge**
- Setup time for a new app: **under 10 minutes**
- Developer's repo contains **one workflow file** and **one config file** — nothing else platform-related
- No per-app cloud account setup, no per-app Terraform, no secrets management
- Works for **any GitHub user** — open source, bring your own cloud account
- Frontend: Firebase Hosting (React/Vite/Next/static)
- Backend: Cloud Run (Python/Go/Node)

### Should Have (v2)
- Optional managed database — developer declares `database: postgres`, credentials auto-injected
- Preview environments on pull requests
- Basic deploy status reporting back to GitHub (commit status / PR comment)
- Multi-org support (Toucanberry pilot)

### Nice to Have (v3+)
- AWS support (S3/CloudFront + Lambda/ECS)
- Custom domain support
- Shared GKE cluster with namespace isolation
- Dashboard / deploy history UI
- Slack/Discord deploy notifications

### Non-Goals
- Replacing Kubernetes for high-scale production systems
- Multi-region active-active deployments
- Full IDP (no score.yaml, no full Humanitec-scale platform)
- Managing CI testing (lint/test is the app's own concern)

---

## 3. Target Users

### Primary
- **Bobby / BobbyJason** — the creator; needs to spin up personal projects fast
- **Toucanberry developers** — creative developers who want to ship without ops knowledge

### Secondary  
- Any developer with a GitHub account + a cloud provider account who is tired of infra boilerplate

---

## 4. Developer Experience (The North Star)

This is the **complete** developer experience for a new app:

### Step 1: Create repo structure
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

### Step 4: Push to GitHub

That's it. The platform:
- Detects it's a new app
- Provisions the necessary cloud infra (idempotently)
- Builds and deploys frontend and backend
- Returns a live URL

**No GCP console. No Terraform. No secrets. No YAML beyond the above.**

---

## 5. Configuration Reference

`launchpad.yaml` is the single source of truth for an app's platform requirements.

```yaml
# launchpad.yaml

name: my-app           # slug — used for service names, URLs, etc.

frontend:
  framework: react     # react | vue | next | static | none
  dir: frontend        # default: frontend
  node_version: "20"   # default: 20

backend:
  language: python     # python | go | node | none
  dir: backend         # default: backend
  port: 8080
  memory: 512Mi
  cpu: "1"

database: false        # false | postgres | mysql

# Provider block is OPTIONAL — defaults to the platform operator's configured provider
# The app developer should NOT need to set this
provider:
  cloud: gcp           # gcp | aws | azure (future)
  region: europe-west1
```

> **Key principle**: The `provider` block is optional and operator-managed. A developer deploying to a GCP-backed platform writes exactly the same `launchpad.yaml` as one deploying to an AWS-backed platform. If support is added for AWS in the future, existing `launchpad.yaml` files do not change.

---

## 6. Platform Operator Experience

Someone (Bobby, or a Toucanberry admin) runs the bootstrap once to set up a platform environment:

```bash
# Clone launchpad
git clone https://github.com/bobbydeveaux/launchpad
cd launchpad/terraform/bootstrap

# Configure
cp terraform.tfvars.example terraform.tfvars
# edit: cloud provider, project/account ID, region, org

# Bootstrap
terraform init && terraform apply
```

This provisions:
- A shared cloud project/account for the platform
- IAM / Workload Identity Federation for GitHub Actions
- Artifact Registry / ECR (per cloud)
- Platform service account / role

Output: a set of **non-secret** platform variables that platform users add to their GitHub org/repo variables:

```
LAUNCHPAD_PROVIDER=gcp
LAUNCHPAD_PROJECT=bj-platform-dev
LAUNCHPAD_WIF_PROVIDER=projects/123/locations/global/...
LAUNCHPAD_SERVICE_ACCOUNT=launchpad-sa@bj-platform-dev.iam...
LAUNCHPAD_REGION=europe-west1
```

These are not secrets. They are configuration. They can live in GitHub org variables or be hardcoded in a fork.

---

## 7. Multi-Cloud Strategy

### Design Principle: Cloud Provider is an Implementation Detail

`launchpad.yaml` describes **what** an app needs. The platform decides **where** it runs. This means:

- A `frontend: react` maps to Firebase Hosting on GCP, S3/CloudFront on AWS, Static Web Apps on Azure
- A `backend: python` maps to Cloud Run on GCP, App Runner/Lambda on AWS, Container Apps on Azure
- A `database: postgres` maps to Cloud SQL on GCP, RDS on AWS

The app never knows or cares which cloud it's on.

### Provider Interface (v1 internal, v2 public)

Internally, the platform is built around a **provider interface**:

```
providers/
├── gcp/
│   ├── terraform/          ← GCP-specific modules
│   └── workflows/          ← GCP-specific deploy steps
├── aws/                    ← future
│   ├── terraform/
│   └── workflows/
└── interface.md            ← what each provider must implement
```

Each provider must implement:
- `deploy-frontend` — takes a built artifact, returns a URL
- `deploy-backend` — takes a container image, returns a URL
- `provision-database` — creates a DB, injects creds into Secret Manager equivalent
- `bootstrap` — one-time platform setup

### Migration Path

When AWS support is added:
1. `providers/aws/` is implemented
2. Platform operator re-runs bootstrap targeting AWS
3. Apps using `LAUNCHPAD_PROVIDER=aws` get AWS deployments
4. **Zero changes to any app's `launchpad.yaml`**

---

## 8. Success Metrics

| Metric | Target |
|--------|--------|
| New app deploy time (from empty repo) | < 10 minutes |
| Lines of infra config in app repo | < 30 (launchpad.yaml + deploy.yml) |
| Platform bootstrap time (one-time) | < 30 minutes |
| Supported runtimes at launch | 3 (React, Python, Go) |
| Toucanberry pilot apps | 2+ |

---

## 9. Risks & Mitigations

| Risk | Mitigation |
|------|------------|
| GCP-only at launch limits adoption | Multi-cloud interface designed in from day 1 |
| Shared platform project = blast radius | Namespace isolation via naming; IAM scoping per-app SA |
| Terraform state in shared project | Separate state bucket per app within platform project |
| Developer ports their own secrets | Doc clearly: zero secrets in app repo, everything via Secret Manager |
| Reusable workflow breaking changes | Version pinning (`@v1`, `@v2`) — never break `@main` without major bump |

---

## 10. Phases

### Phase 1 — POC (now)
- GCP only
- Firebase Hosting frontend + Cloud Run backend
- No database
- Single environment (dev)
- Manual bootstrap (Terraform)

### Phase 2 — Production Ready
- Dev + Prod environments
- Optional Cloud SQL database with auto-injection
- PR preview environments
- GitHub deploy status integration

### Phase 3 — Multi-tenant
- Toucanberry org support
- Per-developer cost attribution
- Basic dashboard

### Phase 4 — Multi-cloud
- AWS provider (S3/CloudFront + App Runner)
- Provider-agnostic bootstrap CLI

---

## Appendix: Name

**Launchpad** — every project has one. You build on it. Then you launch.

Repo: `bobbydeveaux/launchpad`  
Config file: `launchpad.yaml`  
Action: `uses: bobbydeveaux/launchpad/.github/workflows/platform.yml@main`
