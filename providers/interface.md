# Launchpad Provider Interface

Each cloud provider must implement the following components to be compatible with the Launchpad platform.

## Directory Structure

```
providers/<provider>/
├── terraform/
│   ├── bootstrap/     ← one-time platform setup
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   ├── outputs.tf
│   │   └── terraform.tfvars.example
│   └── platform/      ← per-app infrastructure (idempotent)
│       ├── main.tf
│       ├── variables.tf
│       ├── outputs.tf
│       └── backend.tf
└── workflows/
    ├── auth.yml       ← composite action: authenticate to cloud
    ├── frontend.yml   ← reusable workflow: deploy frontend
    └── backend.yml    ← reusable workflow: deploy backend
```

## Required Components

### 1. `workflows/auth.yml` (Composite Action)

Authenticates the GitHub Actions runner to the cloud provider using OIDC (no long-lived secrets).

**Inputs:**
| Input | Type | Description |
|-------|------|-------------|
| `wif_provider` | string | Provider-specific identity federation resource (GCP: WIF provider path, AWS: IAM role ARN) |
| `service_account` | string | Provider-specific service identity (GCP: SA email, AWS: not needed) |

**Effect:** After this action runs, subsequent steps can make authenticated API calls to the cloud provider.

**Output:** None (credentials are injected into the environment).

### 2. `workflows/frontend.yml` (Reusable Workflow)

Deploys built frontend assets to the provider's static hosting service.

**Inputs:**
| Input | Type | Required | Description |
|-------|------|----------|-------------|
| `app_name` | string | yes | Application slug |
| `frontend_dir` | string | yes | Directory containing frontend source |
| `frontend_framework` | string | yes | Framework: react, vue, next, static |
| `environment` | string | yes | Target environment (dev, prod, preview) |
| `platform_project` | string | yes | Cloud project/account identifier |
| `region` | string | yes | Cloud region |
| `wif_provider` | string | yes | Auth identity provider |
| `service_account` | string | yes | Auth service account |
| `is_pr` | string | no | "true" if this is a PR preview deploy |

**Outputs:**
| Output | Type | Description |
|--------|------|-------------|
| `url` | string | Live URL of the deployed frontend |

**Provider mappings:**
| Provider | Service |
|----------|---------|
| GCP | Firebase Hosting |
| AWS | S3 + CloudFront |
| Azure | Static Web Apps |

### 3. `workflows/backend.yml` (Reusable Workflow)

Builds a container image and deploys it as a backend service.

**Inputs:**
| Input | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `app_name` | string | yes | | Application slug |
| `backend_dir` | string | yes | | Directory containing backend source |
| `backend_language` | string | yes | | Language: python, go, node |
| `backend_port` | number | yes | 8080 | Port the app listens on |
| `environment` | string | yes | | Target environment |
| `platform_project` | string | yes | | Cloud project/account |
| `region` | string | yes | | Cloud region |
| `wif_provider` | string | yes | | Auth identity provider |
| `service_account` | string | yes | | Auth service account |
| `memory` | string | no | 512Mi | Memory allocation |
| `cpu` | string | no | 1 | CPU allocation |

**Outputs:**
| Output | Type | Description |
|--------|------|-------------|
| `url` | string | Live URL of the deployed backend |

**Provider mappings:**
| Provider | Service |
|----------|---------|
| GCP | Cloud Run |
| AWS | App Runner / ECS |
| Azure | Container Apps |

### 4. `terraform/bootstrap/` (One-time Setup)

Provisions all shared platform infrastructure for the provider.

**Required variables:**
| Variable | Description |
|----------|-------------|
| `platform_project` | Cloud project/account ID |
| `github_owner` | GitHub org or user for OIDC trust |
| `environment` | dev or prod |
| `region` | Cloud region |

**Required outputs (as GitHub Variables):**
| Output | GitHub Variable |
|--------|----------------|
| Provider name | `LAUNCHPAD_PROVIDER` |
| Project/account ID | `LAUNCHPAD_PROJECT` |
| Region | `LAUNCHPAD_REGION` |
| Identity provider path | `LAUNCHPAD_WIF_PROVIDER` |
| Service account email | `LAUNCHPAD_SA_EMAIL` |

### 5. `terraform/platform/` (Per-App Infrastructure)

Creates app-specific resources idempotently. Called on every deploy.

**Required variables:**
| Variable | Description |
|----------|-------------|
| `app_name` | Application slug |
| `environment` | dev or prod |
| `platform_project` | Cloud project/account |
| `region` | Cloud region |

**Required outputs:**
| Output | Description |
|--------|-------------|
| `frontend_url` | Frontend service URL |
| `backend_url` | Backend service URL |

## Adding a New Provider

1. Create `providers/<name>/` following the structure above
2. Implement all required components
3. Ensure outputs match the contract
4. Add wrapper workflows in `.github/workflows/` (required by GitHub Actions for `workflow_call`)
5. Update `platform.yml` to support the new provider
6. Test with the example-app
