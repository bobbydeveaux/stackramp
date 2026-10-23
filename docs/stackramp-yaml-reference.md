# stackramp.yaml Reference

`stackramp.yaml` is the single configuration file that describes your application to the StackRamp platform. Place it in your repository root.

## Full Example

```yaml
name: my-app

domain: my-app.io   # optional — explicit custom domain
domain_txt:         # optional — extra TXT values at the apex (SPF, site verification)
  - v=spf1 include:_spf.google.com ~all

frontend:
  framework: react
  dir: frontend
  node_version: "20"
  sso: true          # optional — serve via Cloud Run + IAP (see SSO section)
  proxy_paths:       # optional — extra site paths rewritten to the backend
    - "/.well-known/**"   #   besides /api/** (Firebase globs; needs a backend)
    - "/mcp"

backend:
  language: python
  dir: backend
  port: 8080         # optional — defaults to 8080
  memory: 512Mi
  cpu: "1"
  sso: true          # optional — restrict to IAP-authenticated users

database: false

storage: gcs         # optional — provisions a GCS bucket
```

## Fields

### `domain` (optional)

| | |
|---|---|
| Type | `string` |
| Pattern | `^([a-z0-9-]+\.)+[a-z]{2,}$` |
| Example | `myapp.io`, `dashboard.myorg.io` |

Custom domain for this app. Supports both root (apex) domains and subdomains, including multi-part TLDs like `flowbydeveaux.co.uk`.

If omitted and the platform has `STACKRAMP_BASE_DOMAIN` configured, the app automatically gets `{name}.{STACKRAMP_BASE_DOMAIN}` (e.g. `my-app.myorg.io`).

If neither is set, the app is served on the default Firebase Hosting URL (`{site-id}.web.app`).

At deploy time the platform auto-detects the Cloud DNS zone authoritative for this domain:

- **Managed** — a Cloud DNS zone exists for the domain (the base domain, or one added to the bootstrap `custom_domains` list). StackRamp injects the required TXT + A/CNAME records automatically, with no manual steps.
- **External** — no Cloud DNS zone exists. StackRamp registers the Firebase custom domain and reports the records to add at your own registrar; your DNS stays where it is.

See INTEGRATION.md → *Custom Domains* for how to provision a zone for your own domain.

### `domain_txt` (optional)

| | |
|---|---|
| Type | `list of string` |
| Default | `[]` |
| Example | `["v=spf1 include:_spf.google.com ~all", "google-site-verification=abc123"]` |

Extra TXT values to keep at the zone apex when `domain` is the apex of a **managed** Cloud DNS zone (e.g. `thedeveauxgroup.co.uk`, not `app.thedeveauxgroup.co.uk`). Use it for SPF, `google-site-verification=...` tokens and other apex TXT records.

```yaml
domain: thedeveauxgroup.co.uk
domain_txt:
  - v=spf1 include:_spf.google.com ~all
  - google-site-verification=abc123
```

Why it exists: for an apex domain StackRamp already owns the apex TXT record set (it holds the `hosting-site=<site_id>` value Firebase uses to verify the domain), and Cloud DNS allows only one TXT record set per name. A TXT record added by hand in the console would fail to create, or be overwritten on the next deploy. `domain_txt` values go into that same record set.

- One TXT value per item, written **without** surrounding quotes. StackRamp quotes and escapes them.
- Values longer than 255 characters (e.g. a 2048-bit DKIM key) are split into 255-character strings automatically, which is how DNS stores long TXT values.
- Values must be non-empty strings and must not contain `${` or `%{`.
- Prod only, like an explicit `domain`. Ignored for subdomains, external (unmanaged) domains and Kubernetes apps. TXT records on other names (e.g. `google._domainkey`) are not covered; add those in the zone directly.

---

### `name` (required)

| | |
|---|---|
| Type | `string` |
| Pattern | `^[a-z][a-z0-9-]*$` |
| Example | `my-app`, `todo-api`, `company-dashboard` |

The application slug. Used for all resource naming: Cloud Run service names, Firebase site IDs, container image tags, Terraform state prefixes.

Must start with a lowercase letter and contain only lowercase letters, numbers, and hyphens.

---

### `frontend` (optional)

Omit this block or set `framework: none` if your app has no frontend.

#### `frontend.framework`

| | |
|---|---|
| Type | `string` |
| Values | `react`, `vue`, `next`, `static`, `none` |
| Default | `none` |

The frontend framework. Determines build commands and hosting configuration.

- `react` / `vue` — standard SPA, built with `npm run build`
- `next` — Next.js app with SSR support
- `static` — plain HTML/CSS/JS, no build step
- `none` — no frontend

#### `frontend.dir`

| | |
|---|---|
| Type | `string` |
| Default | `frontend` |

Directory containing your frontend source code, relative to repo root.

#### `frontend.node_version`

| | |
|---|---|
| Type | `string` |
| Default | `20` |

Node.js version for building the frontend. Can also be set via `.nvmrc` in the frontend directory.

#### `frontend.sso`

| | |
|---|---|
| Type | `boolean` |
| Default | `false` |

When `true`, the frontend is served from Cloud Run (nginx) behind a Google IAP-protected HTTPS Load Balancer instead of Firebase Hosting. Requires `domain` to be set and the operator to have completed the [one-time IAP setup](../INTEGRATION.md#sso-via-google-iap).

---

### `backend` (optional)

Omit this block or set `language: none` if your app has no backend.

#### `backend.language`

| | |
|---|---|
| Type | `string` |
| Values | `python`, `go`, `node`, `rust`, `none` |
| Default | `none` |

The backend language. Determines which default Dockerfile to use if you don't provide your own.

- `python` — uses `uvicorn` with `requirements.txt`
- `go` — builds `cmd/server` or root package
- `node` — runs `index.js` or `src/index.js`
- `rust` — multi-stage build with `cargo build --release`, binary name parsed from `Cargo.toml`

You can override the default by placing a `Dockerfile` in your backend directory.

#### `backend.dir`

| | |
|---|---|
| Type | `string` |
| Default | `backend` |

Directory containing your backend source code, relative to repo root.

#### `backend.port`

| | |
|---|---|
| Type | `integer` |
| Default | `8080` |

Port your backend application listens on.

#### `backend.sso`

| | |
|---|---|
| Type | `boolean` |
| Default | `false` |

When `true`, the backend Cloud Run service is placed behind the IAP load balancer and its ingress is restricted to the load balancer only. Direct Cloud Run URLs are inaccessible from the internet.

Typically set together with `frontend.sso: true`. Access control is managed by the platform operator via `STACKRAMP_IAP_DOMAIN`.

#### `backend.memory`

| | |
|---|---|
| Type | `string` |
| Default | `512Mi` |

Memory allocation for the backend service. Examples: `256Mi`, `512Mi`, `1Gi`, `2Gi`.

#### `backend.cpu`

| | |
|---|---|
| Type | `string` |
| Default | `1` |

CPU allocation for the backend service. Examples: `1`, `2`, `4`.

#### `backend.max_instances`

| | |
|---|---|
| Type | `integer` |
| Default | `10` |

The most Cloud Run instances the backend scales to. Lower it when every instance holds database connections, so instances × pool size stays within the database's connection limit (for example 3 instances × 5 connections = 15 on a small shared instance). Entries in `backends:` take the same field.

> **PR previews always scale to zero.** `min_instances` and `always_on` (on
> `backend:`, `backends:` entries and `mcp:`) apply to `dev` and `prod` only.
> A PR preview (`pr-<number>`) is always deployed with `--min-instances=0`
> and CPU throttled (CPU only during requests), so an instance kept warm for
> prod latency doesn't run 24/7 for every open PR. Background work outside a
> request, or long-lived connections, won't run between requests on a
> preview; try those on `dev`. See [PR previews](#pr-previews).

---

### `database`

| | |
|---|---|
| Type | `boolean` or `string` |
| Values | `false`, `postgres`, `mysql` |
| Default | `false` |

Whether the app needs a managed database. When enabled (Phase 2), the platform will:
1. Create a database on the shared Cloud SQL instance
2. Generate and store credentials in Secret Manager
3. Inject `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASSWORD` into the backend service

---

### `storage` (optional)

| | |
|---|---|
| Type | `boolean`, `string`, or `object` |
| Values | `false`, `gcs`, or a `{ buckets: [...] }` block |
| Default | `false` |

Object storage. There are two forms, both supported:

**Scalar form (legacy, unchanged):** `storage: gcs` provisions a single bucket named `{app_name}-data-{environment}`, grants the Cloud Run runtime service account `roles/storage.objectAdmin`, and injects `GCS_BUCKET` into the backend. `storage: false` (the default) provisions nothing.

**Block form (one or more named buckets):**

```yaml
storage:
  buckets:
    - name: downloads        # logical name -> env var BUCKET_DOWNLOADS
      access: private        # private only — public is not yet supported
      signed_urls: true      # grant the SA keyless V4 signBlob (no key file)
      lifecycle_days: 0      # optional object TTL in days (0 = no rule)
```

For each entry in `buckets` the platform provisions a **private** bucket named `{project}-{app}-{env}-{name}` with uniform bucket-level access. The resolved name must be **63 characters or fewer** (the GCS limit); deploys with a longer name fail validation early, so keep logical names short. Each bucket has:

| Field | Default | Behaviour |
|---|---|---|
| `name` | *(required)* | Logical name. Lowercase slug. Injected as env var `BUCKET_<NAME_UPPER>` (hyphens become underscores, e.g. `user-uploads` -> `BUCKET_USER_UPLOADS`). Bucket resolves to `{project}-{app}-{env}-{name}`. |
| `access` | `private` | Only `private` is supported: **public access prevention** is enforced (anonymous access is rejected). `access: public` is reserved for a future release and is currently a hard validation error — public buckets / CDN fronting are out of scope. |
| `signed_urls` | `false` | When `true`, grants the runtime SA `roles/iam.serviceAccountTokenCreator` **on itself** so the backend can mint V4 signed URLs via `signBlob` with **no exported key file** (keyless signing). |
| `lifecycle_days` | `0` | When `> 0`, adds an age-based **delete** lifecycle rule of that many days. `0` adds no rule. |

The runtime SA is granted `roles/storage.objectAdmin` scoped to each bucket only.

**Keyless signed URLs:** with `signed_urls: true`, application code generates V4 signed URLs without a downloaded service account key. In Go, construct the signer from the runtime credentials and let the IAM `signBlob` API do the signing (`storage.SignedURLOptions` with `GoogleAccessID` set to the runtime SA email and a `SignBytes`/IAM-credentials signer). No `GOOGLE_APPLICATION_CREDENTIALS` key file is needed.

**Back-compat:** `storage: false` and `storage: gcs` continue to behave exactly as before. The block form is additive; mixing the scalar `gcs` form and the block form in one file is not supported (use one or the other).

**Example (block form):**
```yaml
name: my-app

backend:
  language: go
  dir: backend
  port: 8080

storage:
  buckets:
    - name: downloads
      access: private
      signed_urls: true
      lifecycle_days: 2
```

**Example (legacy scalar form):**
```yaml
name: my-app

backend:
  language: go
  dir: backend
  port: 8080

storage: gcs
```

---

### `kubernetes` (optional)

For apps that need a real Kubernetes cluster (dispatch k8s Jobs, run a Helm
chart) instead of Cloud Run. Helm-installs the app into its own namespace on the
shared GKE cluster (requires `enable_gke = true` at bootstrap).

```yaml
kubernetes:
  chart: deploy/helm/myapp        # default: deploy/helm/<app>
  namespace: myapp                # default: app name
  domain: myapp.stackramp.io      # optional — GKE ingress + managed cert
  images:                         # StackRamp builds + pushes (tag = git SHA)
    - { name: myapp-api, dockerfile: Dockerfile.api, context: . }
  values: { ... }                 # inline Helm value overrides
```

> ⚠️ **Known limitation — single-node cluster, no horizontal scale.** The shared
> GKE cluster is intentionally single-node (the shared `hostPath` volume is
> node-local). You can scale **up** (bigger machine) but **not out** until shared
> RWX storage (Filestore) replaces the hostPath. See
> [kubernetes-primitive.md](./kubernetes-primitive.md#-known-limitation-single-node-no-horizontal-scale-fix-before-high-load)
> for the full constraint and the fix path — **read it before raising node count
> or going regional.**

---

### `deploy` (optional) — what a push deploys

Each push deploys only the services whose files changed:

| Service | Deploys when a changed file matches |
|---|---|
| frontend | `frontend.dir/**`, `frontend.watch_paths` |
| backend (API) | `backend.dir/**`, `backend.watch_paths` |
| each `backends[]` entry | its `dir/**`, its `watch_paths` |
| mcp | `mcp.dir/**`, `mcp.watch_paths` |
| kubernetes | the chart dir, each image's context/dockerfile, `kubernetes.watch_paths` |

Services that share a dir (for example an API and a worker built from the same
`api/` dir) all deploy when it changes, from one image build.

Files matching the ignore list never trigger a deploy, even inside a service
dir. Built-in list: `*.md` (repo root), `**/README.md`, `**/CHANGELOG.md`,
`LICENSE`, `docs/**`, `marketing/**`, `brand/**`, `.github/**`, `.claude/**`,
`.vscode/**`, `.idea/**`. When nothing deployable changed, the run skips
everything, including the security scan and the quality gate.

**Everything deploys** on a manual run (`workflow_dispatch`), a scheduled run,
the `deploy_all: true` workflow input, a branch's first push, when the change
list can't be computed, and when `stackramp.yaml`, the calling workflow file or
a `full_deploy_paths` glob changed.

```yaml
deploy:
  ignore_paths: ["api/testdata/**", "**/*.test.ts"]  # added to the built-in list
  default_ignore_paths: true    # false = use only ignore_paths
  full_deploy_paths: ["shared/**", "package-lock.json"]

backends:
  - name: worker
    dir: worker
    watch_paths: ["proto/**"]   # also deploy the worker when proto/ changes
```

Globs: `*` stays within a path segment, `**` crosses segments, `{a,b}`
alternates, paths are relative to the repo root.

> **A dependency outside the service dir needs `watch_paths`.** The Docker build
> context is the service dir, so normally nothing outside it can reach the
> image. If your build does pull in files from elsewhere (a monorepo package, a
> generated client), list them, or that service will keep running the old code
> until its next deploy.

**Infrastructure (Terraform)** runs only when its inputs changed: the job
fingerprints every Terraform input (stackramp.yaml values, GitHub variables,
the detected DNS zone and the platform's Terraform code) and compares it with
the fingerprint stored after the last successful apply, in the state bucket
next to the state. It also applies when `stackramp.yaml` changed, on scheduled
runs, and when the `provision: true` workflow input (or a `workflow_dispatch`
input named `provision`) is set. Otherwise it reads the outputs from the
Terraform state in a few seconds. Platform secrets (label
`platform-inject=true`, see [Platform secrets](#platform-secrets-secret-manager-labels))
are not Terraform inputs: each deploy lists and mounts them, so a new secret
reaches a service on that service's next deploy (run the workflow manually to
roll it out everywhere).

Recommended caller setup (manual full deploy, forced provisioning, a weekly
full deploy as a safety net):

```yaml
on:
  push:
    branches: [main]
  pull_request:
    types: [opened, synchronize, reopened, closed]
  schedule:
    - cron: "30 3 * * 1"        # Mondays 03:30 UTC: deploy everything
  workflow_dispatch:
    inputs:
      provision:
        description: "Run terraform apply even if nothing changed"
        type: boolean
        default: false
```

Dry run: call the workflow with `dry_run: true` to see the plan (which services
would deploy, whether Terraform would apply) in the run summary. Nothing is
built, scanned, applied or deployed.

---

## Platform secrets (Secret Manager labels)

Platform secrets are not set in `stackramp.yaml`: the platform operator
creates them in Secret Manager in the platform project (the bootstrap
Terraform `platform_secrets` list, or by hand) and labels them. Every Cloud
Run deploy (backend, its migrations job, MCP, machine backends in `backends:`,
and the SSO frontend) mounts each matching secret as an env var of the same
name, `NAME=NAME:latest`. The discovery lives in one place,
`providers/gcp/workflows/platform-secrets`.

| Label | Required | Effect |
|---|---|---|
| `platform-inject=true` | yes | The secret is a platform secret. Without it nothing mounts it. |
| `platform-app=<app>` | no | Mounted only into the services of that app: `<app>` is the `name` in its `stackramp.yaml`. Absent: every app. |
| `platform-env=<dev\|prod>` | no | Mounted only into that environment. Absent: every environment. |

A secret with neither `platform-app` nor `platform-env` is mounted into every
service, as before these labels existed.

**Which services count as an app.** All of an app's services match its
`name`: for `name: myapp`, the backend `myapp-<env>`, its migrations job, the
MCP server `myapp-mcp-<env>`, each `backends:` entry `myapp-<backend>-<env>`
and the SSO frontend `myapp-fe-<env>` all match `platform-app=myapp`.

**Environments.** `dev` and `prod` match themselves. PR previews
(`pr-<number>`) count as `dev`: they get unscoped and `platform-env=dev`
secrets, never `platform-env=prod` ones.

**Label values.** GCP label values allow only lowercase letters, digits, `_`
and `-` (up to 63 characters). The app name and environment are lowercased,
any other character becomes `-`, and they are cut to 63 characters before
matching. An app `name` that follows the schema (`^[a-z][a-z0-9-]*$`) is used
as it is; keep it to 63 characters or less, since two longer names that share
their first 63 characters would match each other's `platform-app` secrets.

Scope a secret (names and labels only; this never touches the value):

```bash
# only myapp's prod services
gcloud secrets update MYAPP_PROD_API_KEY --project=<platform project> \
  --update-labels=platform-app=myapp,platform-env=prod

# undo: mounted everywhere again
gcloud secrets update MYAPP_PROD_API_KEY --project=<platform project> \
  --remove-labels=platform-app,platform-env

# see what a service would mount
gcloud secrets list --project=<platform project> --format="value(name.basename())" \
  --filter="labels.platform-inject=true AND (-labels.platform-app:* OR labels.platform-app=myapp) AND (-labels.platform-env:* OR labels.platform-env=prod)"
```

> **Changes reach a service on its next deploy.** Labels are read at deploy
> time. Adding a label (or removing `platform-inject`) takes the secret off a
> service only when that service is next deployed, since `--set-secrets`
> replaces the service's whole secret list then; until then the running
> revision keeps it. The same goes for the migrations job (updated on the next
> deploy with a `migrate_command`). Run the workflow manually (`deploy_all`)
> to roll a relabel out to every service of an app.
>
> A service that ends up with no matching platform secret and no
> `DATABASE_URL` is deployed with `--clear-secrets`, so scoped-away secrets
> come off it too. In a project with no `platform-inject=true` secrets at all
> no secret flag is passed, as before.

---

## PR previews

Each pull request gets its own services, `<app>-pr-<n>` (backend),
`<app>-<name>-pr-<n>` (each `backends:` entry and `mcp:`), and a Firebase
preview channel `pr-<n>` on the dev site. Previews cost as little as possible
and don't outlive their PR:

- **Scale to zero, CPU throttled**, whatever `min_instances` / `always_on`
  say (those are for `dev` and `prod`). Preview services carry the labels
  `stackramp-app=<app>` and `stackramp-pr=<n>`.
- **Deleted when the PR closes.** The caller's workflow must list `closed` in
  `pull_request: types` (see the recommended setup above).
- **No preview after close.** Each preview deploy asks GitHub whether the PR
  is still open right before `gcloud run deploy` (and before the Firebase
  channel deploy and migrations) and skips when it's closed; after deploying
  it asks again and deletes what it just created if the PR closed meanwhile.
  This covers a PR marked ready and merged seconds later, where the close
  cleanup finished before the ready run's deploy. The workflow token needs
  `pull-requests: read` (the documented `pull-requests: write` covers it).
  If GitHub can't be asked, the deploy goes ahead and the sweep catches it.
- **Sweep.** After each PR's cleanup, and on every scheduled run, StackRamp
  also deletes every preview of the app whose PR is closed. It only touches
  this app's preview services: named exactly `<app>-pr-<n>`, `<app>-fe-pr-<n>`
  or `<app>-<backend>-pr-<n>` for a backend in `stackramp.yaml`, or carrying
  both labels above; never `dev`/`prod` services or other apps' (app `qbot`
  never matches `qbot-ai-pr-5`). It lists before deleting and keeps a preview
  whose PR state it can't read. The run summary shows a table of what it
  found and did.

For a daily sweep without a daily full deploy, add a second workflow that
calls `_sweep-previews.yml` (it does nothing else):

```yaml
name: Preview sweep
on:
  schedule:
    - cron: "0 4 * * *"          # daily 04:00 UTC
  workflow_dispatch:
    inputs:
      dry_run:
        description: "List what would be deleted; delete nothing"
        type: boolean
        default: true
jobs:
  sweep:
    permissions:
      id-token: write
      contents: read
      pull-requests: read
    uses: bobbydeveaux/stackramp/.github/workflows/_sweep-previews.yml@main
    with:
      dry_run: ${{ inputs.dry_run == true }}
    secrets: inherit
```

Run it by hand with `dry_run` to see what it would delete. To try the
listing locally (read-only):

```bash
DRY_RUN=true APP_NAME=myapp BACKENDS='[{"name":"worker"}]' \
  PROJECT=my-platform-project REGION=europe-west1 QUOTA_PROJECT=my-platform-project \
  REPO=me/myapp GH_TOKEN=$(gh auth token) \
  bash providers/gcp/workflows/preview-sweep/preview-sweep.sh
```

---

## What NOT to Put in stackramp.yaml

The following are **platform operator concerns**, not app developer concerns:

- Cloud provider (set via `STACKRAMP_PROVIDER` GitHub Variable)
- GCP project / AWS account (set via `STACKRAMP_PROJECT`)
- Region (set via `STACKRAMP_REGION`)
- Service account / IAM (set via `STACKRAMP_SA_EMAIL`)
- WIF / OIDC configuration (set via `STACKRAMP_WIF_PROVIDER`)

This separation means your `stackramp.yaml` works identically whether the platform runs on GCP, AWS, or Azure.
