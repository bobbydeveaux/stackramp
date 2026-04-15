# stackramp.yaml Reference

`stackramp.yaml` is the single configuration file that describes your application to the StackRamp platform. Place it in your repository root.

## Full Example

```yaml
name: my-app

domain: my-app.io   # optional — explicit custom domain

frontend:
  framework: react
  dir: frontend
  node_version: "20"
  sso: true          # optional — serve via Cloud Run + IAP (see SSO section)

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

Custom domain for this app. Supports both root domains and subdomains.

If omitted and the platform has `STACKRAMP_BASE_DOMAIN` configured, the app automatically gets `{name}.{STACKRAMP_BASE_DOMAIN}` (e.g. `my-app.myorg.io`).

If neither is set, the app is served on the default Firebase Hosting URL (`{site-id}.web.app`).

Domain verification is fully automatic — because StackRamp manages Cloud DNS, it injects the required TXT and A records itself with no manual steps.

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

#### `backend.iam` (optional)

| | |
|---|---|
| Type | `array` of objects |
| Default | `[]` (no cross-project bindings) |

Cross-project IAM bindings for the Cloud Run service account. Each entry grants an IAM role on a target GCP project or resource. This is useful when your backend needs to access resources in a different project (e.g. BigQuery datasets, Cloud Storage buckets).

Each entry has the following fields:

| Field | Required | Description |
|---|---|---|
| `role` | Yes | IAM role to grant (e.g. `roles/bigquery.dataViewer`, `roles/bigquery.jobUser`) |
| `project` | Yes | Target GCP project ID |
| `resource` | No | Resource path for resource-level bindings. Currently supports `datasets/{dataset_id}` for BigQuery dataset-level grants. Omit for project-level bindings. |

**Prerequisites:** The deploying Workload Identity Federation (WIF) service account must have `roles/iam.securityAdmin` or equivalent on each target project.

**Example:**
```yaml
name: my-api

backend:
  language: rust
  dir: backend
  port: 8080
  iam:
    - role: roles/bigquery.dataViewer
      project: data-warehouse-prod
      resource: datasets/analytics    # dataset-level binding
    - role: roles/bigquery.jobUser
      project: data-warehouse-prod    # project-level binding
```

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
| Type | `boolean` or `string` |
| Values | `false`, `gcs` |
| Default | `false` |

Whether the app needs persistent object storage. When `gcs` is set:
- A GCS bucket named `{app_name}-data-{environment}` is provisioned
- The Cloud Run service account is granted `roles/storage.objectAdmin`
- `GCS_BUCKET` env var is automatically injected into the backend service

**Example:**
```yaml
name: my-app

backend:
  language: go
  dir: backend
  port: 8080

storage: gcs
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
