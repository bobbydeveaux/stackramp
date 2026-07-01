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
  sso: false                  # true to serve frontend behind Google IAP (default: false)

backend:
  language: python            # python | go | node | none
  dir: backend                # directory containing your backend (default: backend)
  port: 8080                  # port your app listens on (default: 8080)
  memory: 512Mi               # Cloud Run memory (default: 512Mi)
  cpu: "1"                    # Cloud Run CPU (default: 1)
  sso: false                  # true to put backend behind Google IAP (default: false)

domain: my-app.yourdomain.com # optional custom domain
                              # omit for a .web.app Firebase URL

database: false               # false | postgres | mysql (default: false)

storage: false                # false | gcs | { buckets: [...] } (default: false)
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

That's the entire deploy workflow. No further configuration needed in the app repo. The `closed` type is needed so StackRamp can clean up preview environments when PRs are merged or closed.

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
  │ Custom domain + DNS records     │
  │ Cloud Run service shell         │
  │ GCS bucket (if storage: gcs)    │
  │ IAP + HTTPS LB (if sso: true)  │
  └─────────────────────────────────┘
        │
        ▼
  deploy-backend
  ┌──────────────────────┐
  │ docker build + push  │
  │ gcloud run deploy    │
  └──────────────────────┘
        │
        ▼
  deploy-frontend
  ┌──────────────────────┐
  │ npm ci + npm build   │
  │ firebase deploy      │
  │ (or preview channel  │
  │  if PR)              │
  └──────────────────────┘
        │
        ▼ (main branch only, after dev succeeds)
  deploy-frontend-prod + deploy-backend-prod

PR closed/merged
        │
        ▼
  cleanup-preview
  ┌──────────────────────────────┐
  │ Delete Cloud Run pr-N service│
  │ Delete Firebase preview chan │
  └──────────────────────────────┘
```

### Branch behaviour

| Trigger | Environment | Frontend | Backend |
|---|---|---|---|
| `push` to `main` | `dev` then `prod` | Firebase live channel | Cloud Run |
| Pull request | `pr-{number}` | Firebase preview channel | Cloud Run (`{app}-pr-{number}`) |
| PR closed/merged | — | Preview channel deleted | Cloud Run preview deleted |
| `workflow_dispatch` | `dev` + `prod` | Forces redeploy | Forces redeploy |

### Change detection

StackRamp uses `dorny/paths-filter` to skip unchanged components on pushes. If only the frontend changed, the backend job is skipped, and vice versa. PRs and `workflow_dispatch` bypass this and deploy everything — PRs need a full deployment so Firebase preview channels can wire API rewrites to the PR-scoped Cloud Run service.

---

## Custom Domains

Set `domain:` in `stackramp.yaml`. At deploy time the platform looks up the Cloud
DNS managed zone **authoritative for that domain** (longest matching zone) and
picks the mode automatically — you don't declare which mode you're in:

- **Managed** (a Cloud DNS zone exists for the domain): StackRamp injects the
  records for you.
  - **Apex** (`yourdomain.com` — the zone root): A records → Firebase's load-balancer IPs.
  - **Subdomain** (`app.yourdomain.com`): CNAME → `{site-id}.web.app`.

  Apex vs subdomain is decided by comparing the domain to the zone's `dns_name`,
  so multi-part TLDs like `flowbydeveaux.co.uk` are treated correctly as apex.

- **External** (no Cloud DNS zone for the domain): StackRamp registers the
  Firebase custom domain only and prints the records Firebase requires — you add
  the A/TXT records at your own registrar (e.g. 123-reg). DNS stays with you.

For `dev`, an auto-generated base-domain subdomain is prefixed (`app.dev.yourdomain.com`);
explicit domains are used as-is in both environments.

If you don't set `domain:`, your app gets a `{app-name}-{random}.web.app` Firebase URL.

### Using your own domain (managed mode)

To have StackRamp manage a domain that isn't a subdomain of `STACKRAMP_BASE_DOMAIN`,
add it to the **bootstrap** so it gets its own Cloud DNS zone — exactly like the
platform base domain:

```hcl
# bootstrap dev.tfvars / prod.tfvars
custom_domains = ["flowbydeveaux.co.uk"]
```

Apply the bootstrap, then read the nameservers to delegate:

```bash
terraform output custom_domain_nameservers
# flowbydeveaux.co.uk = ["ns-cloud-XX.googledomains.com.", ...]
```

Set those four nameservers at the domain's registrar. Once delegation propagates,
any app can set `domain: flowbydeveaux.co.uk` (or a subdomain of it) and the
platform will detect the zone and manage records automatically.

> **Note:** delegating nameservers moves *all* DNS for that domain into Cloud DNS —
> recreate any existing records (email/MX, etc.) in the zone. If you'd rather keep
> DNS at your registrar, simply **don't** add the domain to `custom_domains`: the
> app still deploys and you add the Firebase-reported records at your registrar
> (external mode above).

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
| `ENVIRONMENT` | `dev`, `prod`, or `pr-{number}` |
| `APP_NAME` | Value of `name` in `stackramp.yaml` |
| `FRONTEND_URL` | Firebase Hosting URL for the same environment |
| `GCS_BUCKET` | GCS bucket name (only if `storage: gcs`, the legacy scalar form) |
| `BUCKET_<NAME>` | One per `storage.buckets` entry, e.g. `BUCKET_DOWNLOADS` (block form) |
| `DATABASE_SECRET_NAME` | Secret Manager secret name for DB URL (only if `database:` is set) |

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
- Backend is deployed as a Cloud Run service named `{app}-pr-{number}` (e.g. `arcade-pr-21`)
- Frontend is deployed to a Firebase preview channel scoped to `pr-{number}`
- Firebase wires `/api/**` rewrites to the PR-scoped Cloud Run service, so the preview is fully functional
- A comment is posted on the PR with the preview URL
- Preview channels auto-expire after 7 days, but StackRamp actively cleans up both Cloud Run services and Firebase channels when the PR is closed or merged
- Multiple open PRs get independent preview environments (no collisions)

> **Note:** The deploy workflow must include `pull_request: types: [opened, synchronize, reopened, closed]` for cleanup to trigger on PR close.

---

## GCS Storage

StackRamp provisions private GCS buckets for your app, wires the Cloud Run runtime service account's IAM, and injects the bucket name(s) as env vars. No manual GCP steps. There are two forms.

### Legacy scalar form

Set `storage: gcs` to provision a single bucket named `{app}-data-{env}`. The `GCS_BUCKET` env var is injected into the Cloud Run service at deploy time, and the runtime SA is granted `roles/storage.objectAdmin` on it.

```yaml
name: my-app

backend:
  language: python
  dir: backend

storage: gcs
```

### Block form (one or more named buckets)

Declare named buckets under `storage.buckets`:

```yaml
name: my-app

backend:
  language: go
  dir: backend

storage:
  buckets:
    - name: downloads        # -> env var BUCKET_DOWNLOADS
      access: private        # private only — public is not yet supported
      signed_urls: true      # keyless V4 signed URLs (signBlob, no key file)
      lifecycle_days: 2      # delete objects after 2 days (0 = no rule)
```

For each entry the platform provisions a **private** bucket named `{project}-{app}-{env}-{name}` (e.g. `bj-platform-dev-my-app-dev-downloads`) with uniform bucket-level access, grants the runtime SA `roles/storage.objectAdmin` scoped to that bucket, and injects the bucket name as `BUCKET_<NAME_UPPER>` (hyphens become underscores). The resolved name must be 63 characters or fewer (the GCS limit) — longer names fail validation early, so keep logical names short.

- **`access`** — only `private` (the default) is supported: public access prevention is enforced and anonymous reads are rejected. `access: public` is reserved for a future release and is currently a hard validation error (public buckets / CDN fronting are out of scope).
- **`signed_urls: true`** grants the runtime SA `roles/iam.serviceAccountTokenCreator` on itself, so the backend can mint V4 signed URLs via the IAM `signBlob` API with **no downloaded key file**. This is the keyless signing pattern: build the signer from the runtime credentials, set `GoogleAccessID` to the runtime SA email, and the IAM credentials API signs the bytes.
- **`lifecycle_days`** adds an age-based delete lifecycle rule when greater than 0.

**Back-compat:** `storage: false` and `storage: gcs` are unchanged. Use either the scalar form or the block form, not both in one file.

---

## Secrets

Secrets stored in GCP Secret Manager are automatically injected into Cloud Run as environment variables. The platform injects any secrets matching the pattern `{app}-{env}-{secret-name}`.

To add a secret for your app:
```bash
echo -n "my-secret-value" | gcloud secrets create my-app-dev-api-key \
  --data-file=- --project=YOUR_PROJECT
```

The secret is available as the `API_KEY` env var in your Cloud Run service (the `{app}-{env}-` prefix is stripped).

---

## GitHub Variables Reference

Set at org level so all repos inherit them. None of these are secrets.

| Variable | Example | Description |
|---|---|---|
| `STACKRAMP_PROJECT` | `my-platform-dev` | GCP project ID |
| `STACKRAMP_REGION` | `europe-west1` | GCP region for all resources |
| `STACKRAMP_WIF_PROVIDER` | `projects/123/locations/global/...` | Full WIF provider resource name (from bootstrap output) |
| `STACKRAMP_SA_EMAIL` | `stackramp-cicd-sa@my-platform-dev.iam.gserviceaccount.com` | Platform CI/CD service account |
| `STACKRAMP_DNS_ZONE` | `yourdomain-com` | Informational only — the platform now auto-detects the Cloud DNS zone for each app's domain, so this is no longer required for custom domains |
| `STACKRAMP_BASE_DOMAIN` | `stackramp.io` | Base domain for auto-generating dev subdomains (e.g. `app.dev.stackramp.io`) |
| `STACKRAMP_IAP_DOMAIN` | `bobbyjason.co.uk` | Google Workspace domain allowed through IAP — only needed for SSO apps. Omit to allow any Google account. |
| `STACKRAMP_CLOUDSQL_CONNECTION` | `project:region:instance` | Cloud SQL connection name — only needed for database apps |

---

## Repo Structure (StackRamp platform repo)

```
stackramp/
├── .github/workflows/
│   ├── platform.yml              # Entry point — consuming repos reference this
│   ├── _frontend.yml             # Reusable: Firebase Hosting / Cloud Run (SSO) deploy
│   ├── _backend.yml              # Reusable: Cloud Run build + deploy
│   └── _cleanup-preview.yml      # Reusable: deletes PR preview resources on close
├── platform-action/
│   ├── action.yml                # Parses stackramp.yaml, outputs config
│   ├── schema.json               # stackramp.yaml JSON schema
│   └── dockerfiles/
│       ├── python.Dockerfile
│       ├── node.Dockerfile
│       └── go.Dockerfile
├── dashboard/                    # StackRamp monitoring dashboard (dogfooded)
│   ├── backend/                  # Go API — lists Cloud Run services via GCP APIs
│   └── frontend/                 # React dashboard with service status
└── providers/gcp/terraform/
    ├── bootstrap/                # One-time platform setup
    └── platform/                 # Per-app infra (run on every deploy)
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
