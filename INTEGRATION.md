# StackRamp — Integration Guide

StackRamp is a zero-config deployment platform for GCP. Add one config file and one workflow file to any repo and get Firebase Hosting (frontend) + Cloud Run (backend) with custom domains, preview URLs on PRs, and fully automated infra provisioning.

---

## Prerequisites

A platform operator must run the bootstrap **once** before any apps can onboard. If you're onboarding an app into an existing StackRamp platform, skip to [Onboarding an App](#onboarding-an-app).

---

## Platform Bootstrap (one-time, operator only)

The bootstrap provisions all shared GCP infrastructure: APIs, Artifact Registry, Firebase project, Workload Identity Federation, and optionally a Cloud DNS zone.

```bash
cd providers/gcp/terraform/bootstrap

terraform init
terraform apply \
  -var=platform_project=YOUR_GCP_PROJECT_ID \
  -var=github_owner=YOUR_GITHUB_ORG_OR_USERNAME \
  -var=region=europe-west1 \
  -var=base_domain=yourdomain.com   # optional — omit if not managing DNS via GCP
```

The `terraform output` after apply prints a summary of all GitHub Variables to set:

| Variable | Description |
|---|---|
| `STACKRAMP_PROJECT` | GCP project ID |
| `STACKRAMP_REGION` | GCP region (e.g. `europe-west1`) |
| `STACKRAMP_WIF_PROVIDER` | Full Workload Identity provider resource name |
| `STACKRAMP_SA_EMAIL` | Platform CI/CD service account email |
| `STACKRAMP_DNS_ZONE` | Cloud DNS zone name (e.g. `yourdomain-com`) — only if `base_domain` was set |

Set these as **GitHub Variables** (not secrets) at the organisation level: `Settings → Secrets and variables → Actions → Variables`. All repos in the org will inherit them automatically.

> **DNS note:** if `base_domain` is set, the bootstrap creates a Cloud DNS managed zone. Point your domain's nameservers at the outputted nameservers at your registrar before deploying any apps with custom domains.

---

## Onboarding an App

Two files in the app repo. That's it.

### 1. `stackramp.yaml` (repo root)

Describes what your app is. All fields except `name` are optional.

```yaml
name: my-app                  # required — lowercase slug, used for service names

frontend:
  framework: react            # react | vue | next | static | none
  dir: frontend               # directory containing your frontend (default: frontend)
  node_version: "20"          # node version, or use .nvmrc in frontend dir

backend:
  language: python            # python | go | node | none
  dir: backend                # directory containing your backend (default: backend)
  port: 8080                  # port your app listens on (default: 8080)
  memory: 512Mi               # Cloud Run memory (default: 512Mi)
  cpu: "1"                    # Cloud Run CPU (default: 1)

domain: my-app.yourdomain.com # optional custom domain
                              # omit for a .web.app Firebase URL

database: false               # false | postgres | mysql (default: false)
```

**Frontend-only example:**
```yaml
name: guardian

domain: guardian.yourdomain.com

frontend:
  framework: static
  dir: website

database: false
```

**Frontend + backend example:**
```yaml
name: my-api-app

domain: my-api-app.yourdomain.com

frontend:
  framework: react
  dir: frontend
  node_version: "20"

backend:
  language: python
  dir: backend
  port: 8080

database: false
```

---

### 2. `.github/workflows/deploy.yml`

```yaml
name: Deploy

on:
  push:
    branches: [main]
  pull_request:
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

That's the entire deploy workflow. No further configuration needed in the app repo.

---

## What Happens on Deploy

```
push to main / PR opened
        │
        ▼
  parse-config
  ┌─────────────────────────────────┐
  │ Reads stackramp.yaml            │
  │ Detects frontend/backend changes│
  └─────────────────────────────────┘
        │
        ▼
  provision (Terraform — idempotent)
  ┌─────────────────────────────────┐
  │ Firebase Hosting site           │
  │ Custom domain + DNS CNAME       │
  │ Cloud Run service shell         │
  └─────────────────────────────────┘
        │
        ├──────────────────────────────────┐
        ▼                                  ▼
  deploy-frontend                    deploy-backend
  ┌──────────────────────┐           ┌──────────────────────┐
  │ npm ci + npm build   │           │ docker build + push  │
  │ firebase deploy      │           │ gcloud run deploy    │
  │ (or preview channel  │           └──────────────────────┘
  │  if PR)              │
  └──────────────────────┘
        │
        ▼ (main branch only, after dev succeeds)
  deploy-frontend-prod + deploy-backend-prod
```

### Branch behaviour

| Trigger | Environment | Frontend | Backend |
|---|---|---|---|
| `push` to `main` | `dev` then `prod` | Firebase live channel | Cloud Run |
| Pull request | `preview` | Firebase preview channel | Cloud Run (preview env) |
| `workflow_dispatch` | `dev` | Forces redeploy | Forces redeploy |

### Change detection

StackRamp uses `dorny/paths-filter` to skip unchanged components. If only the frontend changed, the backend job is skipped, and vice versa. `workflow_dispatch` bypasses this and redeploys everything.

---

## Custom Domains

Set `domain:` in `stackramp.yaml`. StackRamp handles the rest automatically:

- **Apex domain** (`yourdomain.com`): A records → Firebase's load balancer IPs
- **Subdomain** (`app.yourdomain.com`): CNAME → `{site-id}.web.app` (Firebase verifies ownership via CNAME and mints SSL automatically)

For `dev`, the subdomain is prefixed: `app.dev.yourdomain.com`. For `prod`, it uses the domain as-is.

> **Requirement:** `STACKRAMP_DNS_ZONE` must be set as a GitHub Variable and the Cloud DNS zone must be authoritative for the domain (nameservers pointing to GCP).

If you don't set `domain:`, your app gets a `{app-name}-{random}.web.app` Firebase URL.

---

## Backend: `/api` Routing

When `has_backend: true`, Firebase Hosting rewrites all `/api/**` requests to Cloud Run. The frontend and backend share the same origin — no CORS configuration needed.

```
https://my-app.yourdomain.com/           → Firebase Hosting (frontend)
https://my-app.yourdomain.com/api/...    → Cloud Run (backend)
```

The `VITE_API_URL` env var is set to the backend's Cloud Run URL at build time if needed for direct calls.

---

## Backend: Custom Dockerfile

If your backend directory contains a `Dockerfile`, it is used as-is. Otherwise StackRamp uses a platform-provided Dockerfile for your language (`python`, `go`, or `node`).

The following env vars are injected into every Cloud Run service at deploy time:

| Variable | Value |
|---|---|
| `ENVIRONMENT` | `dev` or `prod` |
| `APP_NAME` | Value of `name` in `stackramp.yaml` |
| `FRONTEND_URL` | Firebase Hosting URL for the same environment |

---

## SSO via Google IAP

Set `sso: true` on your frontend and/or backend to put the app behind Google Identity-Aware Proxy. Instead of Firebase Hosting, the frontend is served from Cloud Run (nginx) and both services sit behind a single HTTPS Global Load Balancer with IAP enforcing authentication.

```yaml
name: my-app

domain: my-app.yourdomain.com

frontend:
  framework: react
  sso: true

backend:
  language: python
  sso: true
```

**What the platform provisions (SSO path):**

```
User → HTTPS LB (IAP) → /api/* → Cloud Run (backend)
                      → /*     → Cloud Run (nginx, frontend SPA)
```

- Global HTTPS Load Balancer with managed SSL certificate
- Identity-Aware Proxy on both backend services
- Serverless NEGs routing LB traffic to Cloud Run
- Cloud Run services restricted to `ingress: internal-and-cloud-load-balancing` (direct Cloud Run URLs are unreachable from the internet)
- DNS A record for your custom domain pointing at the LB IP
- Firebase Hosting is **not** used — frontend is nginx on Cloud Run

**API calls from the frontend** use relative paths (`/api/...`) — no separate domain or CORS configuration needed since both frontend and backend are on the same domain.

**Access control** is set via `STACKRAMP_IAP_DOMAIN` GitHub Variable:

| Value | Who can access |
|---|---|
| `bobbyjason.co.uk` | Any Google account `@bobbyjason.co.uk` |
| *(unset)* | Any authenticated Google account |

**One-time operator setup:**
1. Create an OAuth 2.0 Web Client in GCP Console → APIs & Services → Credentials
2. Add `https://iap.googleapis.com/v1/oauth/clientIds/{CLIENT_ID}:handleRedirect` as an authorised redirect URI
3. Store the client ID and secret in Secret Manager: `stackramp-iap-client-id` and `stackramp-iap-client-secret`
4. Set `STACKRAMP_IAP_DOMAIN` as a GitHub Variable (optional — omit to allow all Google accounts)

The bootstrap creates the Secret Manager shells and provisions the IAP service identity automatically. The OAuth client itself is created once in the GCP Console (Google deprecated the Terraform resource for this in 2025).

**Toggling SSO off** is a clean operation — set `sso: false` and the platform destroys the LB/IAP resources and re-provisions Firebase Hosting automatically on the next push.

---

## Pull Request Previews

On every PR:
- Frontend is deployed to a Firebase **preview channel** (isolated, time-limited URL)
- A comment is posted on the PR with the preview URL
- Preview channels are scoped to `pr-{number}` and don't affect the live site

---

## GitHub Variables Reference

Set at org level so all repos inherit them. None of these are secrets.

| Variable | Example | Description |
|---|---|---|
| `STACKRAMP_PROJECT` | `my-platform-dev` | GCP project ID |
| `STACKRAMP_REGION` | `europe-west1` | GCP region for all resources |
| `STACKRAMP_WIF_PROVIDER` | `projects/123/locations/global/...` | Full WIF provider resource name (from bootstrap output) |
| `STACKRAMP_SA_EMAIL` | `stackramp-cicd-sa@my-platform-dev.iam.gserviceaccount.com` | Platform CI/CD service account |
| `STACKRAMP_DNS_ZONE` | `yourdomain-com` | Cloud DNS zone name — only needed for custom domains |
| `STACKRAMP_IAP_DOMAIN` | `bobbyjason.co.uk` | Google Workspace domain allowed through IAP — only needed for SSO apps. Omit to allow any Google account. |

---

## Repo Structure (StackRamp platform repo)

```
stackramp/
├── .github/workflows/
│   ├── platform.yml          # Entry point — consuming repos reference this
│   ├── _frontend.yml         # Reusable: Firebase Hosting deploy
│   └── _backend.yml          # Reusable: Cloud Run build + deploy
├── platform-action/
│   ├── action.yml            # Parses stackramp.yaml, outputs config
│   ├── schema.json           # stackramp.yaml JSON schema
│   └── dockerfiles/
│       ├── python.Dockerfile
│       ├── node.Dockerfile
│       └── go.Dockerfile
└── providers/gcp/terraform/
    ├── bootstrap/            # One-time platform setup
    └── platform/             # Per-app infra (run on every deploy)
```

---

## Troubleshooting

**Deploy skipped (frontend/backend jobs not running)**
The paths-filter detected no changes in the watched directories. Either push a real file change in `frontend/` or `backend/`, or trigger via `workflow_dispatch`.

**Firebase domain stuck on "Needs setup" or "Minting certificate"**
The CNAME record needs to propagate before Firebase can verify ownership. This typically takes a few minutes but can take longer. Check Cloud DNS has the correct CNAME pointing to `{site-id}.web.app` (not a hardcoded name). Firebase will automatically verify and mint the SSL cert once DNS propagates.

**`Error 409: Resource already exists` on Cloud Run**
A previous failed run partially created the service. Delete it manually: `gcloud run services delete {app-name}-{env} --region={region} --project={project}`, then re-trigger.

**Firebase site ID globally reserved**
Firebase site IDs are globally unique and held for 30 days after deletion. StackRamp appends a random suffix to all site IDs (e.g. `my-app-v9y8b-prod`) and uses `lifecycle { ignore_changes = [site_id] }` to prevent recreating existing sites. If you hit this, the suffix ensures a fresh ID is generated.
