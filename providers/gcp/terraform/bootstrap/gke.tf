# ── Shared GKE cluster (opt-in via enable_gke) ────────────────────────────────
# StackRamp's k8s primitive: one shared GKE Standard cluster per environment.
# Apps that declare a `kubernetes:` block in stackramp.yaml are Helm-installed
# into their own namespace on this cluster (see the platform terraform +
# _kubernetes.yml workflow). Single-node by default so a shared hostPath volume
# behaves exactly like the local OrbStack dev cluster; scale by machine size,
# not node count (a multi-node cluster would need RWX/Filestore for shared
# volumes). Workload Identity is on so pods (ESO, Cloud SQL proxy) authenticate
# to Google APIs keylessly.

# Dedicated VPC-native network for the cluster. Kept separate from the private
# Cloud SQL VPC (google_compute_network.platform) — in dev Cloud SQL is public
# IP and the in-cluster Cloud SQL Auth Proxy reaches it over the internet,
# authenticated by Workload Identity, so no VPC peering is required here.
resource "google_compute_network" "gke" {
  count                   = var.enable_gke ? 1 : 0
  name                    = "stackramp-gke-${var.environment}"
  project                 = local.platform_project
  auto_create_subnetworks = false
  depends_on              = [google_project_service.apis]
}

resource "google_compute_subnetwork" "gke" {
  count         = var.enable_gke ? 1 : 0
  name          = "stackramp-gke-${var.environment}"
  project       = local.platform_project
  region        = var.region
  network       = google_compute_network.gke[0].id
  ip_cidr_range = "10.16.0.0/20"

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = "10.20.0.0/14"
  }
  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = "10.24.0.0/20"
  }
  private_ip_google_access = true
}

resource "google_container_cluster" "platform" {
  count   = var.enable_gke ? 1 : 0
  name    = "stackramp-${var.environment}"
  project = local.platform_project
  # ZONAL (a single zone), not regional: a regional cluster replicates the node
  # pool across 3 zones, so node_count=1 would mean 3 nodes — 3× cost AND it
  # breaks the shared /memory hostPath (node-local). Zonal = genuinely one node.
  location = var.gke_zone

  # Manage the node pool separately (below) — the default pool is removed.
  remove_default_node_pool = true
  initial_node_count       = 1

  network    = google_compute_network.gke[0].name
  subnetwork = google_compute_subnetwork.gke[0].name

  # VPC-native (alias IPs) — required for Workload Identity + modern GKE.
  networking_mode = "VPC_NATIVE"
  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  # Keyless pod → Google API auth (ESO reads Secret Manager; Cloud SQL proxy
  # connects) via <project>.svc.id.goog[namespace/ksa].
  workload_identity_config {
    workload_pool = "${local.platform_project}.svc.id.goog"
  }

  release_channel {
    channel = var.gke_release_channel
  }

  # Enable the Kubernetes Gateway API + install the gke-l7-* GatewayClasses, so
  # the shared L7 Gateway (gke-gateway.tf) can be created. Without this the
  # gke-l7-global-external-managed GatewayClass does not exist on the cluster.
  gateway_api_config {
    channel = "CHANNEL_STANDARD"
  }

  deletion_protection = false
  depends_on          = [google_project_service.apis]
}

resource "google_container_node_pool" "primary" {
  count      = var.enable_gke ? 1 : 0
  name       = "primary"
  project    = local.platform_project
  location   = var.gke_zone
  cluster    = google_container_cluster.platform[0].name
  node_count = var.gke_node_count

  node_config {
    machine_type = var.gke_machine_type
    disk_size_gb = 50
    oauth_scopes = ["https://www.googleapis.com/auth/cloud-platform"]

    # Enable the GKE metadata server so pods use Workload Identity, not the
    # node's SA.
    workload_metadata_config {
      mode = "GKE_METADATA"
    }
  }
}

# ── External Secrets Operator (ESO), pre-baked ────────────────────────────────
# Installed once so apps just ship ExternalSecret CRs referencing Secret
# Manager keys — no plaintext in CI, no deploy-time secret sync, and secrets
# reconcile/rotate continuously. ESO authenticates to Secret Manager as
# eso-reader@ via Workload Identity (no SA keys).

resource "google_service_account" "eso_reader" {
  count        = var.enable_gke ? 1 : 0
  account_id   = "eso-reader"
  display_name = "External Secrets Operator — Secret Manager reader"
  description  = "Read-only Secret Manager access for ESO, bound to the ESO KSA via Workload Identity."
}

resource "google_project_iam_member" "eso_reader_accessor" {
  count   = var.enable_gke ? 1 : 0
  project = local.platform_project
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.eso_reader[0].email}"
}

# ── Shared Cloud SQL client identity for k8s apps ─────────────────────────────
# One GSA with roles/cloudsql.client, granted here at bootstrap (the operator
# applies with owner creds, so the project-IAM grant is allowed). Every k8s
# app's Cloud SQL Auth Proxy WI-binds its namespace KSA to this GSA (see the
# per-app platform terraform) — so the platform CICD SA never needs
# project-IAM-admin to grant cloudsql.client per app. The DB user/password
# still gates actual per-app database access.
resource "google_service_account" "gke_cloudsql_client" {
  count        = var.enable_gke ? 1 : 0
  account_id   = "gke-cloudsql-client"
  display_name = "GKE apps — shared Cloud SQL client"
  description  = "Assumed by k8s apps' Cloud SQL Auth Proxy pods via Workload Identity. Holds roles/cloudsql.client on the project."
}

resource "google_project_iam_member" "gke_cloudsql_client" {
  count   = var.enable_gke ? 1 : 0
  project = local.platform_project
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.gke_cloudsql_client[0].email}"
}

# Bind the ESO controller KSA (external-secrets/external-secrets) to the GSA.
# Depends on the cluster: the <project>.svc.id.goog Workload Identity pool only
# exists once a WI-enabled cluster is created, so this binding must run after it.
resource "google_service_account_iam_member" "eso_workload_identity" {
  count              = var.enable_gke ? 1 : 0
  service_account_id = google_service_account.eso_reader[0].name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${local.platform_project}.svc.id.goog[external-secrets/external-secrets]"
  depends_on         = [google_container_cluster.platform]
}

# Providers pointed at the just-created cluster. When enable_gke=false the
# cluster attributes are null and no resource uses these providers, so the
# empty config is inert.
data "google_client_config" "default" {}

provider "helm" {
  kubernetes {
    host                   = var.enable_gke ? "https://${google_container_cluster.platform[0].endpoint}" : ""
    token                  = data.google_client_config.default.access_token
    cluster_ca_certificate = var.enable_gke ? base64decode(google_container_cluster.platform[0].master_auth[0].cluster_ca_certificate) : ""
  }
}

provider "kubectl" {
  host                   = var.enable_gke ? "https://${google_container_cluster.platform[0].endpoint}" : ""
  token                  = data.google_client_config.default.access_token
  cluster_ca_certificate = var.enable_gke ? base64decode(google_container_cluster.platform[0].master_auth[0].cluster_ca_certificate) : ""
  load_config_file       = false
}

resource "helm_release" "external_secrets" {
  count            = var.enable_gke ? 1 : 0
  name             = "external-secrets"
  namespace        = "external-secrets"
  create_namespace = true
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  version          = var.eso_chart_version

  set {
    name  = "installCRDs"
    value = "true"
  }
  # Annotate the controller KSA so its pods assume eso-reader via Workload
  # Identity.
  set {
    name  = "serviceAccount.annotations.iam\\.gke\\.io/gcp-service-account"
    value = google_service_account.eso_reader[0].email
  }

  depends_on = [google_container_node_pool.primary]
}

# Cluster-wide store any namespace can reference. Reference-scoped by
# convention (each ExternalSecret names only the keys it needs) — the
# Cloud-Run "every service sees every env var" leak does not recur. Applied via
# kubectl_manifest (not kubernetes_manifest) to avoid the CRD-must-exist-at-plan
# ordering trap with the helm_release that installs the CRDs.
resource "kubectl_manifest" "cluster_secret_store" {
  count = var.enable_gke ? 1 : 0
  yaml_body = yamlencode({
    apiVersion = "external-secrets.io/v1"
    kind       = "ClusterSecretStore"
    metadata   = { name = "gcp-secret-manager" }
    spec = {
      provider = {
        gcpsm = {
          projectID = local.platform_project
        }
      }
    }
  })
  depends_on = [helm_release.external_secrets]
}

# ── CICD SA → Kubernetes RBAC management ──────────────────────────────────────
# App Helm charts may ship namespaced RBAC (agentops creates worker Jobs, so its
# chart ships a Role + RoleBinding). GKE gates rbac.authorization.k8s.io creation
# behind roles/container.admin in Cloud IAM — but container.admin also grants
# cluster create/delete, far more than a deploy identity whose key lives in
# GitHub should hold. So the SA stays at roles/container.developer (workloads
# only, see platform_roles in main.tf) and we grant JUST k8s RBAC management via
# this ClusterRole/Binding, applied here with the operator's (admin) creds. The
# GKE user identity for the SA is its email (see the forbidden-error subject).
# Deliberately NO bind/escalate verbs: k8s' escalation check passes as long as
# the app Role only grants verbs the SA already holds via container.developer
# (agentops' Role grants jobs+pods — both covered). Omitting escalate keeps the
# CI identity unable to self-elevate. If a future app's chart ships RBAC that
# grants permissions beyond container.developer, add bind/escalate then.
resource "kubectl_manifest" "cicd_rbac_manager" {
  count = var.enable_gke ? 1 : 0
  yaml_body = yamlencode({
    apiVersion = "rbac.authorization.k8s.io/v1"
    kind       = "ClusterRole"
    metadata   = { name = "stackramp-cicd-rbac-manager" }
    rules = [{
      apiGroups = ["rbac.authorization.k8s.io"]
      resources = ["roles", "rolebindings"]
      verbs     = ["create", "get", "list", "watch", "update", "patch", "delete"]
    }]
  })
  depends_on = [google_container_node_pool.primary]
}

resource "kubectl_manifest" "cicd_rbac_manager_binding" {
  count = var.enable_gke ? 1 : 0
  yaml_body = yamlencode({
    apiVersion = "rbac.authorization.k8s.io/v1"
    kind       = "ClusterRoleBinding"
    metadata   = { name = "stackramp-cicd-rbac-manager" }
    roleRef = {
      apiGroup = "rbac.authorization.k8s.io"
      kind     = "ClusterRole"
      name     = "stackramp-cicd-rbac-manager"
    }
    subjects = [{
      kind     = "User"
      name     = google_service_account.platform_cicd.email
      apiGroup = "rbac.authorization.k8s.io"
    }]
  })
  depends_on = [kubectl_manifest.cicd_rbac_manager]
}

# ── CICD SA → native workload RBAC (escalation-check fix) ─────────────────────
# App charts ship namespaced Roles granting their ServiceAccount workload verbs
# (agentops' Role grants pods, pods/log, batch/jobs). k8s' RBAC
# escalation-prevention check only allows creating a Role if the CREATOR already
# holds every permission the Role grants — and, critically, it resolves the
# creator's permissions from NATIVE RBAC ONLY. It does not see the SA's
# roles/container.developer grant (that's a GKE IAM webhook authorizer, invisible
# to the escalation RuleResolver), so Helm's Role creation is refused with
# "attempting to grant RBAC permissions not currently held".
#
# Fix: bind the SA to the built-in `edit` ClusterRole via native RBAC. Now the
# escalation resolver sees it natively holds pods/jobs/etc., so it can create app
# Roles that grant subsets of `edit` — but it still CANNOT escalate beyond `edit`
# (no rbac, no cluster-scoped, no escalate verb). Reusable for any app whose
# chart RBAC stays within `edit`.
resource "kubectl_manifest" "cicd_workload_binding" {
  count = var.enable_gke ? 1 : 0
  yaml_body = yamlencode({
    apiVersion = "rbac.authorization.k8s.io/v1"
    kind       = "ClusterRoleBinding"
    metadata   = { name = "stackramp-cicd-workload" }
    roleRef = {
      apiGroup = "rbac.authorization.k8s.io"
      kind     = "ClusterRole"
      name     = "edit"
    }
    subjects = [{
      kind     = "User"
      name     = google_service_account.platform_cicd.email
      apiGroup = "rbac.authorization.k8s.io"
    }]
  })
  depends_on = [google_container_node_pool.primary]
}
