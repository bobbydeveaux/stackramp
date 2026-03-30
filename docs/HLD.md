# Launchpad — High Level Design

**Version:** 0.1  
**Status:** Draft  
**Owner:** Bobby Deveaux  
**Last updated:** 2026-03-31

---

## 1. Overview

Launchpad is a **reusable GitHub Actions platform** that provides zero-config deployment of frontend + backend applications to shared cloud infrastructure. A developer commits code; the platform handles everything else.

This document covers the architectural decisions, component design, and data flows.

---

## 2. Architecture Diagram

```
Developer Repo                    Launchpad Repo                     Cloud Platform
─────────────────                 ──────────────────────             ──────────────────

launchpad.yaml   ──────────────►  platform.yml (reusable workflow)
.github/
  workflows/
    deploy.yml                     │
    (references launchpad)         ▼
                                  parse-config
                                  (reads launchpad.yaml)
                                        │
                          ┌─────────────┼─────────────┐
                          ▼             ▼              ▼
                    detect-changes  provision-infra  (skip if no change)
                          │             │
                          │             ▼
                          │         provider/gcp/terraform/
                          │         (Cloud Run svc + Firebase site)
                          │             │ idempotent
                          ▼             ▼
                 ┌──────────────┐  ┌──────────────┐
                 │deploy-frontend│  │deploy-backend │
                 └──────┬───────┘  └──────┬────────┘
                        │                 │
                        ▼                 ▼
                 Firebase Hosting    Cloud Run
                 (GCP provider)      (GCP provider)
                        │                 │
                        ▼                 ▼
                 https://my-app       https://my-app-
                 .web.app             api-ew1.run.app
```

---

## 3. Component Design

### 3.1 launchpad.yaml (App Config)

Lives in the developer's repo root. Describes the app — not the infrastructure.

```yaml
name: my-app
frontend:
  framework: react
  dir: frontend
backend:
  language: python
  dir: backend
  port: 8080
database: false
```

The `provider` block is intentionally omitted from most app configs. It is injected by the platform via GitHub Variables at the org/repo level, so developers don't need to know or care which cloud they're deploying to.

**Schema validation** happens as the first step of the workflow (fail fast, clear error messages).

---

### 3.2 platform.yml (Reusable Workflow — Entry Point)

```
bobbydeveaux/launchpad/.github/workflows/platform.yml
```

This is the **only file the platform exposes publicly**. It is a `workflow_call` reusable workflow that:

1. Reads and validates `launchpad.yaml`
2. Detects which paths changed (frontend/backend/both/neither)
3. Calls `_provision-infra.yml` if it's a push to main
4. Conditionally calls `_deploy-frontend.yml` and/or `_deploy-backend.yml`
5. Reports status back to GitHub

**Inputs (via GitHub Variables — not secrets):**
```
LAUNCHPAD_PROVIDER       gcp
LAUNCHPAD_PROJECT        bj-platform-dev
LAUNCHPAD_REGION         europe-west1
LAUNCHPAD_WIF_PROVIDER   projects/123/locations/global/workloadIdentityPools/...
LAUNCHPAD_SA_EMAIL       launchpad-sa@bj-platform-dev.iam.gserviceaccount.com
```

---

### 3.3 Parse Config Action

A composite action (`platform-action/action.yml`) that:
- Reads `launchpad.yaml` using `yq`
- Validates required fields
- Exports all values as step outputs for downstream jobs
- Determines provider (from env var, falling back to `launchpad.yaml` if present)

---

### 3.4 Change Detection

Uses `dorny/paths-filter` to determine which jobs to run:

```yaml
- frontend/**  → run frontend deploy
- backend/**   → run backend deploy
- launchpad.yaml → run both + infra provision
```

On first deploy (no prior runs), all paths are treated as changed.

---

### 3.5 Infra Provision (Idempotent)

Calls the provider-specific Terraform module:

```
terraform/providers/gcp/platform/
├── main.tf          ← Cloud Run service + Firebase Hosting site
├── variables.tf     ← app name, region, project, etc.
└── outputs.tf       ← service URLs
```

**Idempotency guarantee:** Running this N times produces the same result. Cloud Run service and Firebase site already existing is not an error.

**State management:** Each app's Terraform state lives in a separate prefix within the platform's shared GCS state bucket:
```
gs://bj-platform-tfstate-dev/<app-name>/terraform.tfstate
```

No per-app state buckets. No per-app GCP projects.

---

### 3.6 Frontend Deploy

Provider: **GCP → Firebase Hosting**

Steps:
1. Detect framework (react/vue/next/static)
2. Run appropriate build command (`npm run build`, `next build`, etc.)
3. Deploy to Firebase Hosting site `<app-name>` within the platform project
4. Site URL: `https://<app-name>--<env>.web.app` (or custom domain later)

For PRs: deploys to a preview channel (`pr-<number>`) and posts URL as PR comment.

---

### 3.7 Backend Deploy

Provider: **GCP → Cloud Run**

Steps:
1. Build Docker image (using language-specific Dockerfile from `platform-action/dockerfiles/`)
2. Push to Artifact Registry in platform project: `<region>-docker.pkg.dev/<project>/apps/<app-name>:<sha>`
3. Deploy to Cloud Run: service name `<app-name>-api` in platform project
4. Inject environment variables:
   - `ENVIRONMENT` (dev/prod)
   - `APP_NAME`
   - Any Secret Manager secrets (if database enabled)

If the app provides its own `Dockerfile` in `backend/`, that is used instead of the platform default.

---

### 3.8 Database Injection (Phase 2)

When `database: postgres` is set in `launchpad.yaml`:

1. Infra provision creates a database + user on the shared Cloud SQL instance
2. Password is generated and stored in Secret Manager at `projects/<project>/secrets/<app-name>-db-password`
3. Cloud Run service is configured to mount the secret as env var `DB_PASSWORD`
4. Standard env vars injected: `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASSWORD`

The developer never sees, stores, or manages the password.

---

## 4. Multi-Cloud Provider Interface

The provider layer is the core abstraction. All cloud-specific logic lives inside a provider.

### 4.1 Directory Structure

```
providers/
├── gcp/
│   ├── terraform/
│   │   ├── bootstrap/     ← one-time platform setup
│   │   └── platform/      ← per-app infra (Cloud Run + Firebase)
│   └── workflows/
│       ├── auth.yml       ← WIF authentication step
│       ├── frontend.yml   ← Firebase Hosting deploy
│       └── backend.yml    ← Cloud Run build + deploy
├── aws/                   ← future
│   ├── terraform/
│   │   ├── bootstrap/     ← S3 state, OIDC, ECR
│   │   └── platform/      ← App Runner + CloudFront
│   └── workflows/
│       ├── auth.yml       ← OIDC auth (no secrets)
│       ├── frontend.yml   ← S3 + CloudFront invalidation
│       └── backend.yml    ← ECR build + App Runner deploy
└── interface.md           ← contract each provider must fulfil
```

### 4.2 Provider Contract

Each provider must implement these workflow files with standardised inputs/outputs:

#### `auth.yml`
**Inputs:** `wif_provider`, `service_account` (GCP) or `role_arn` (AWS)  
**Effect:** Authenticates the runner to the cloud provider  
**Output:** credentials available to subsequent steps

#### `frontend.yml`
**Inputs:** `app_name`, `build_dir`, `environment`  
**Effect:** Deploys built frontend assets  
**Output:** `url` — the live frontend URL

#### `backend.yml`
**Inputs:** `app_name`, `image_tag`, `port`, `environment`, `memory`, `cpu`  
**Effect:** Pushes image and deploys backend service  
**Output:** `url` — the live backend URL

#### `bootstrap/` (Terraform)
**Inputs:** `project_id`/`account_id`, `region`, `org_id` (optional)  
**Effect:** Provisions all shared platform infrastructure once  
**Output:** Variables needed by app workflows (WIF provider, SA email, etc.)

### 4.3 Provider Selection

The active provider is determined at workflow runtime by `LAUNCHPAD_PROVIDER` env var. The `platform.yml` workflow selects the appropriate provider sub-workflows dynamically:

```yaml
- name: Deploy frontend
  uses: ./providers/${{ env.LAUNCHPAD_PROVIDER }}/workflows/frontend.yml
```

This means adding AWS support requires:
1. Implementing `providers/aws/`
2. Adding `LAUNCHPAD_PROVIDER=aws` to the org's GitHub Variables
3. Zero changes to any app's `launchpad.yaml` or `deploy.yml`

---

## 5. Authentication Design

### No GitHub Secrets

Authentication to cloud providers uses **OIDC/Workload Identity** — the GitHub Actions runner proves its identity cryptographically. No long-lived credentials are stored anywhere.

**GCP flow:**
```
GitHub Actions runner
    │ (OIDC token: "I am the workflow running for repo X on branch Y")
    ▼
GCP Workload Identity Pool
    │ (validates OIDC token against WIF binding rules)
    ▼
Platform Service Account
    │ (has IAM permissions scoped to platform project)
    ▼
Cloud Run / Firebase / Artifact Registry
```

**AWS flow (future):**
```
GitHub Actions runner
    │ (OIDC token)
    ▼
AWS IAM Identity Provider (OIDC)
    │
    ▼
IAM Role (AssumeRoleWithWebIdentity)
    │
    ▼
ECR / App Runner / S3
```

### Platform Variables (Public, Not Secret)

These are set once at the GitHub org or repo level as **plain variables** (not secrets):

```
LAUNCHPAD_PROVIDER=gcp
LAUNCHPAD_PROJECT=bj-platform-dev
LAUNCHPAD_WIF_PROVIDER=projects/123456/locations/global/workloadIdentityPools/launchpad/providers/github
LAUNCHPAD_SA_EMAIL=launchpad-sa@bj-platform-dev.iam.gserviceaccount.com
LAUNCHPAD_REGION=europe-west1
```

These contain no credentials. Knowing them gives you nothing without the OIDC token from the correct repo.

---

## 6. Naming Conventions

All platform-managed resources follow a consistent naming scheme to avoid collisions in the shared project:

| Resource | Name Pattern | Example |
|----------|-------------|---------|
| Cloud Run service | `{app-name}-api` | `my-app-api` |
| Firebase Hosting site | `{app-name}` | `my-app` |
| Artifact Registry image | `apps/{app-name}:{sha}` | `apps/my-app:abc1234` |
| Cloud SQL database | `{app-name}` | `my-app` |
| Cloud SQL user | `{app-name}-user` | `my-app-user` |
| Secret Manager secret | `{app-name}-db-password` | `my-app-db-password` |
| TF state prefix | `gs://{bucket}/{app-name}/` | `gs://bj-platform-tfstate-dev/my-app/` |

---

## 7. Repository Structure

```
bobbydeveaux/launchpad/
├── README.md
├── .github/
│   └── workflows/
│       └── platform.yml              ← public entry point (workflow_call)
├── platform-action/
│   ├── action.yml                    ← composite action: parse + validate launchpad.yaml
│   ├── schema.json                   ← launchpad.yaml JSON schema
│   └── dockerfiles/
│       ├── python.Dockerfile         ← default Python backend image
│       ├── go.Dockerfile             ← default Go backend image
│       └── node.Dockerfile           ← default Node backend image
├── providers/
│   ├── interface.md                  ← provider contract
│   ├── gcp/
│   │   ├── terraform/
│   │   │   ├── bootstrap/            ← one-time: WIF, AR, platform SA
│   │   │   └── platform/             ← per-app: Cloud Run + Firebase site
│   │   └── workflows/
│   │       ├── auth.yml
│   │       ├── frontend.yml
│   │       └── backend.yml
│   └── aws/                          ← future
│       ├── terraform/
│       └── workflows/
├── docs/
│   ├── PRD.md
│   ├── HLD.md                        ← this file
│   ├── getting-started.md
│   ├── launchpad-yaml-reference.md
│   ├── operator-guide.md
│   └── database-guide.md
└── example-app/
    ├── launchpad.yaml
    ├── .github/
    │   └── workflows/
    │       └── deploy.yml
    ├── frontend/
    │   └── (React scaffold)
    └── backend/
        └── (Python scaffold)
```

---

## 8. Deployment Flow (End-to-End)

### 8.1 First Deploy (New App)

```
1. Developer pushes to main
2. platform.yml triggers
3. parse-config: reads launchpad.yaml, validates, exports values
4. detect-changes: all paths "changed" (no prior run)
5. provision-infra:
   a. terraform init (remote state in platform bucket)
   b. terraform apply providers/gcp/terraform/platform/
   c. Creates Cloud Run service (no traffic yet) + Firebase site
6. deploy-backend:
   a. Build Docker image (default or custom Dockerfile)
   b. Push to Artifact Registry
   c. Deploy new revision to Cloud Run → service URL emitted
7. deploy-frontend:
   a. npm install && npm run build
   b. firebase deploy --only hosting:<app-name>
   c. Live URL emitted
8. (future) post URLs as commit status / PR comment
```

### 8.2 Subsequent Deploys

Steps 5 (provision-infra) is still called but Terraform finds nothing to change (idempotent). Steps 6+7 only run for changed paths.

### 8.3 PR Preview

```
1. PR opened/updated
2. platform.yml triggers with environment=preview
3. provision-infra: skipped (no infra changes on PRs)
4. deploy-backend: deploys Cloud Run revision with tag pr-<number> (no traffic split)
5. deploy-frontend: deploys Firebase Hosting preview channel pr-<number>
6. Bot comments on PR with preview URLs
```

---

## 9. Decisions & Rationale

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Config format | YAML | Familiar, readable, well-supported in Actions |
| Config file name | `launchpad.yaml` | Matches repo/project name, consistent |
| Shared vs per-app GCP project | Shared | Eliminates per-app bootstrap overhead |
| TF state | Shared bucket, per-app prefix | No per-app bucket creation; still isolated state |
| Secrets | Secret Manager only | No secrets ever in GitHub; industry standard |
| Auth | OIDC/WIF | Secretless; best practice for cloud auth from Actions |
| Provider abstraction | Internal interface, external Terraform + workflows | Allows multi-cloud without changing developer-facing API |
| Dockerfile | Platform default with override | Works out of box; escape hatch for custom needs |
| Versioning | Semver tags (`@v1`) | Operators can pin; `@main` = latest for dev |

---

## 10. Open Questions

- [ ] Should `launchpad.yaml` support multiple backends (e.g., 2 Cloud Run services)?
- [ ] How do we handle apps that need environment-specific config (dev DB vs prod DB)?
- [ ] Should custom domains be self-service or operator-managed in v1?
- [ ] For Toucanberry: shared platform project or each org operator runs their own bootstrap?
- [ ] Cost attribution per app — is this needed in v1?
