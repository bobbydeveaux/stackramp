# ── Shared L7 Gateway (GKE Gateway API) + Certificate Manager ─────────────────
# The modern replacement for per-app GCE Ingress. ONE global external
# Application Load Balancer per cluster: the platform owns the Gateway (LB +
# static IP + wildcard certs); each app just ships a small HTTPRoute for its
# host (see the platform terraform + the app chart). Benefits over Ingress:
#   - one LB + one IP for every app (no per-app LB/IP sprawl),
#   - Certificate Manager DNS-authorised wildcard certs that provision
#     independently of the LB serving traffic (no Ingress chicken-and-egg),
#   - clean platform/app split (Gateway = infra, HTTPRoute = routing).
# One shared cluster hosts BOTH dev and prod app environments (segregated by
# namespace/host), so the Gateway serves *.dev.<base> AND *.<base>.
# Gated on enable_gke + a base_domain (no domain => no public ingress at all).

locals {
  gateway_enabled   = var.enable_gke && var.base_domain != ""
  gateway_namespace = "stackramp-gateway"
  gateway_name      = "stackramp"
  # Managed zone name mirrors the platform zone (created or pre-existing) —
  # replace(base_domain, ".", "-"), matching STACKRAMP_DNS_ZONE.
  gateway_dns_zone = replace(var.base_domain, ".", "-")
  # Wildcards the one cluster serves: dev-app subdomain and prod (bare) subdomain.
  wildcard_dev  = "*.dev.${var.base_domain}"
  wildcard_root = "*.${var.base_domain}"
}

# Reserved GLOBAL external IP the Gateway binds to (referenced by name via the
# Gateway's spec.addresses NamedAddress). Stable across Gateway recreates, and
# the value every app's DNS A-record points at.
resource "google_compute_global_address" "gateway" {
  count        = local.gateway_enabled ? 1 : 0
  name         = "stackramp-gateway-${var.environment}"
  project      = local.platform_project
  address_type = "EXTERNAL"
}

# ── Certificate Manager: DNS-authorised wildcard managed certs ────────────────
# DNS authorization proves domain control via a CNAME (added below), letting the
# managed cert issue + auto-renew independently of the LB — no waiting for the
# Gateway to serve traffic first. One authorization per parent domain.
resource "google_certificate_manager_dns_authorization" "dev" {
  count    = local.gateway_enabled ? 1 : 0
  name     = "stackramp-dns-auth-dev"
  project  = local.platform_project
  domain   = "dev.${var.base_domain}"
  location = "global"
}

resource "google_certificate_manager_dns_authorization" "root" {
  count    = local.gateway_enabled ? 1 : 0
  name     = "stackramp-dns-auth-root"
  project  = local.platform_project
  domain   = var.base_domain
  location = "global"
}

# The CNAME each authorization asks for, written into the platform DNS zone.
resource "google_dns_record_set" "dns_auth_dev" {
  count        = local.gateway_enabled ? 1 : 0
  name         = google_certificate_manager_dns_authorization.dev[0].dns_resource_record[0].name
  type         = google_certificate_manager_dns_authorization.dev[0].dns_resource_record[0].type
  ttl          = 300
  managed_zone = local.gateway_dns_zone
  project      = local.platform_project
  rrdatas      = [google_certificate_manager_dns_authorization.dev[0].dns_resource_record[0].data]
}

resource "google_dns_record_set" "dns_auth_root" {
  count        = local.gateway_enabled ? 1 : 0
  name         = google_certificate_manager_dns_authorization.root[0].dns_resource_record[0].name
  type         = google_certificate_manager_dns_authorization.root[0].dns_resource_record[0].type
  ttl          = 300
  managed_zone = local.gateway_dns_zone
  project      = local.platform_project
  rrdatas      = [google_certificate_manager_dns_authorization.root[0].dns_resource_record[0].data]
}

# Wildcard managed certs (one per environment tier the cluster serves).
resource "google_certificate_manager_certificate" "wildcard_dev" {
  count    = local.gateway_enabled ? 1 : 0
  name     = "stackramp-wildcard-dev"
  project  = local.platform_project
  location = "global"
  managed {
    domains            = [local.wildcard_dev]
    dns_authorizations = [google_certificate_manager_dns_authorization.dev[0].id]
  }
}

resource "google_certificate_manager_certificate" "wildcard_root" {
  count    = local.gateway_enabled ? 1 : 0
  name     = "stackramp-wildcard-root"
  project  = local.platform_project
  location = "global"
  managed {
    domains            = [local.wildcard_root]
    dns_authorizations = [google_certificate_manager_dns_authorization.root[0].id]
  }
}

# Cert map the Gateway references (via the networking.gke.io/certmap annotation);
# entries pick the wildcard cert by SNI hostname.
resource "google_certificate_manager_certificate_map" "gateway" {
  count   = local.gateway_enabled ? 1 : 0
  name    = "stackramp-gateway"
  project = local.platform_project
}

resource "google_certificate_manager_certificate_map_entry" "dev" {
  count        = local.gateway_enabled ? 1 : 0
  name         = "stackramp-wildcard-dev"
  project      = local.platform_project
  map          = google_certificate_manager_certificate_map.gateway[0].name
  certificates = [google_certificate_manager_certificate.wildcard_dev[0].id]
  hostname     = local.wildcard_dev
}

resource "google_certificate_manager_certificate_map_entry" "root" {
  count        = local.gateway_enabled ? 1 : 0
  name         = "stackramp-wildcard-root"
  project      = local.platform_project
  map          = google_certificate_manager_certificate_map.gateway[0].name
  certificates = [google_certificate_manager_certificate.wildcard_root[0].id]
  hostname     = local.wildcard_root
}

# ── The shared Gateway + HTTP→HTTPS redirect ──────────────────────────────────
# Applied with the operator's creds (helm/kubectl providers in gke.tf). The
# GatewayClass gke-l7-global-external-managed exists because the cluster has
# gateway_api_config enabled (gke.tf).
resource "kubectl_manifest" "gateway_namespace" {
  count = local.gateway_enabled ? 1 : 0
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Namespace"
    metadata   = { name = local.gateway_namespace }
  })
  depends_on = [google_container_node_pool.primary]
}

resource "kubectl_manifest" "gateway" {
  count = local.gateway_enabled ? 1 : 0
  yaml_body = yamlencode({
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "Gateway"
    metadata = {
      name      = local.gateway_name
      namespace = local.gateway_namespace
      annotations = {
        # Google-managed certs for HTTPS listeners come from this Certificate
        # Manager map, not per-listener certificateRefs.
        "networking.gke.io/certmap" = google_certificate_manager_certificate_map.gateway[0].name
      }
    }
    spec = {
      gatewayClassName = "gke-l7-global-external-managed"
      # Bind the reserved global IP by name.
      addresses = [{
        type  = "NamedAddress"
        value = google_compute_global_address.gateway[0].name
      }]
      listeners = [
        {
          name     = "https"
          protocol = "HTTPS"
          port     = 443
          # Certs supplied by the certmap annotation; any app namespace may
          # attach an HTTPRoute for a host under the wildcard certs.
          allowedRoutes = { namespaces = { from = "All" } }
        },
        {
          name          = "http"
          protocol      = "HTTP"
          port          = 80
          allowedRoutes = { namespaces = { from = "All" } }
        },
      ]
    }
  })
  depends_on = [
    kubectl_manifest.gateway_namespace,
    google_certificate_manager_certificate_map_entry.dev,
    google_certificate_manager_certificate_map_entry.root,
    google_compute_global_address.gateway,
  ]
}

# Platform-owned route: 301 every HTTP request to HTTPS. App routes attach to
# the https listener; this one owns the http listener.
resource "kubectl_manifest" "gateway_https_redirect" {
  count = local.gateway_enabled ? 1 : 0
  yaml_body = yamlencode({
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata   = { name = "https-redirect", namespace = local.gateway_namespace }
    spec = {
      parentRefs = [{
        name        = local.gateway_name
        namespace   = local.gateway_namespace
        sectionName = "http"
      }]
      rules = [{
        filters = [{
          type = "RequestRedirect"
          requestRedirect = {
            scheme     = "https"
            statusCode = 301
          }
        }]
      }]
    }
  })
  depends_on = [kubectl_manifest.gateway]
}
