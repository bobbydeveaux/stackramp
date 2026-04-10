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
| Values | `python`, `go`, `node`, `none` |
| Default | `none` |

The backend language. Determines which default Dockerfile to use if you don't provide your own.

- `python` — uses `uvicorn` with `requirements.txt`
- `go` — builds `cmd/server` or root package
- `node` — runs `index.js` or `src/index.js`

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

---

### `backends` (optional — multi-service)

Use `backends` (plural) instead of `backend` (singular) when your application needs multiple independent backend services. Each key is a service name, and each service gets its own Cloud Run deployment with independent language, directory, port, CPU, and memory configuration.

**`backend` and `backends` are mutually exclusive** — use one or the other. Existing apps using `backend` continue to work unchanged.

#### Full Example

```yaml
name: trade-simulator

frontend:
  framework: static
  dir: frontend

backends:
  api:
    language: rust
    dir: backend
    port: 8080
    primary: true
    env:
      PREDICTOR_URL: ${backends.predictor.url}
  predictor:
    language: python
    dir: predictor
    port: 8085
    memory: 1Gi
    cpu: "2"
```

#### Per-service fields

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `language` | `string` | `none` | `python`, `go`, `node`, `rust`, `none` |
| `dir` | `string` | service name | Directory containing service code |
| `port` | `integer` | `8080` | Port the service listens on |
| `memory` | `string` | `512Mi` | Cloud Run memory allocation |
| `cpu` | `string` | `1` | Cloud Run CPU allocation |
| `primary` | `boolean` | `false` | Marks this service as the primary backend for `/api/**` routing |
| `env` | `object` | `{}` | Additional environment variables (key-value pairs) |

#### Service discovery

Each backend automatically receives the URLs of all other backends as environment variables. The variable name is derived from the service name:

- A service named `predictor` is available to other services as `PREDICTOR_URL`
- A service named `auth-service` is available as `AUTH_SERVICE_URL`

You can also explicitly reference other services in the `env` block using the `${backends.<name>.url}` syntax:

```yaml
env:
  PREDICTOR_URL: ${backends.predictor.url}
```

Both automatic injection and explicit references resolve to the Cloud Run service URL (e.g. `https://myapp-predictor-dev-abc123.a.run.app`).

#### Primary backend

The primary backend handles `/api/**` routing from the frontend (via Firebase Hosting rewrites or the SSO load balancer URL map). You can mark a backend as primary with `primary: true`. If no backend is explicitly marked, the first one listed is used.

#### Cloud Run naming

Each backend gets a separate Cloud Run service named `{app_name}-{service_name}-{environment}`:
- `trade-simulator-api-dev`
- `trade-simulator-predictor-dev`
- `trade-simulator-api-prod`
- `trade-simulator-predictor-prod`

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
