# stackramp.yaml Reference

`stackramp.yaml` is the single configuration file that describes your application to the StackRamp platform. Place it in your repository root.

## Full Example

```yaml
name: my-app

frontend:
  framework: react
  dir: frontend
  node_version: "20"

backend:
  language: python
  dir: backend
  port: 8080
  memory: 512Mi
  cpu: "1"

database: false
```

## Fields

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

## What NOT to Put in stackramp.yaml

The following are **platform operator concerns**, not app developer concerns:

- Cloud provider (set via `STACKRAMP_PROVIDER` GitHub Variable)
- GCP project / AWS account (set via `STACKRAMP_PROJECT`)
- Region (set via `STACKRAMP_REGION`)
- Service account / IAM (set via `STACKRAMP_SA_EMAIL`)
- WIF / OIDC configuration (set via `STACKRAMP_WIF_PROVIDER`)

This separation means your `stackramp.yaml` works identically whether the platform runs on GCP, AWS, or Azure.
