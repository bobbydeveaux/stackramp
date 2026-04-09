package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strings"
	"time"

	run "cloud.google.com/go/run/apiv2"
	runpb "cloud.google.com/go/run/apiv2/runpb"
	"google.golang.org/api/dns/v1"
	"google.golang.org/api/iterator"
)

// ServiceInfo is the JSON shape returned by GET /api/services.
type ServiceInfo struct {
	Name         string `json:"name"`
	Service      string `json:"service"`
	Environment  string `json:"environment"`
	Status       string `json:"status"`
	Revision     string `json:"revision"`
	LastDeployed string `json:"lastDeployed"`
	URL          string `json:"url"`
	CustomDomain string `json:"customDomain,omitempty"`
	Region       string `json:"region"`
}

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/api/health", handleHealth)
	mux.HandleFunc("/api/services", handleServices)

	log.Printf("dashboard backend listening on :%s", port)
	if err := http.ListenAndServe(":"+port, mux); err != nil {
		log.Fatalf("server error: %v", err)
	}
}

// handleHealth returns a simple health-check response.
func handleHealth(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]string{"status": "ok"})
}

// handleServices lists all Cloud Run services in the project, enriched with custom domain info.
func handleServices(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()

	projectID, err := resolveProjectID(ctx)
	if err != nil {
		http.Error(w, fmt.Sprintf("failed to resolve project ID: %v", err), http.StatusInternalServerError)
		return
	}

	services, err := listServices(ctx, projectID)
	if err != nil {
		http.Error(w, fmt.Sprintf("failed to list services: %v", err), http.StatusInternalServerError)
		return
	}

	// Look up custom domains from Cloud DNS (best-effort — don't fail if DNS lookup errors)
	dnsZone := os.Getenv("DNS_ZONE")
	if dnsZone == "" {
		dnsZone = os.Getenv("STACKRAMP_DNS_ZONE")
	}
	if dnsZone != "" {
		domainMap, err := buildDomainMap(ctx, projectID, dnsZone)
		if err != nil {
			log.Printf("warning: could not look up DNS records: %v", err)
		} else {
			enrichWithDomains(services, domainMap)
		}
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(services)
}

// resolveProjectID reads the GCP project ID from the metadata server,
// falling back to the GOOGLE_CLOUD_PROJECT environment variable.
func resolveProjectID(ctx context.Context) (string, error) {
	// Try metadata server first (works on Cloud Run / GCE).
	client := &http.Client{Timeout: 2 * time.Second}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet,
		"http://metadata.google.internal/computeMetadata/v1/project/project-id", nil)
	if err == nil {
		req.Header.Set("Metadata-Flavor", "Google")
		resp, err := client.Do(req)
		if err == nil {
			defer resp.Body.Close()
			if resp.StatusCode == http.StatusOK {
				body, err := io.ReadAll(resp.Body)
				if err == nil && len(body) > 0 {
					return strings.TrimSpace(string(body)), nil
				}
			}
		}
	}

	// Fallback to environment variable.
	if id := os.Getenv("GOOGLE_CLOUD_PROJECT"); id != "" {
		return id, nil
	}

	return "", fmt.Errorf("could not determine project ID from metadata server or GOOGLE_CLOUD_PROJECT")
}

// listServices calls the Cloud Run Admin API v2 and returns parsed ServiceInfo items.
func listServices(ctx context.Context, projectID string) ([]ServiceInfo, error) {
	client, err := run.NewServicesClient(ctx)
	if err != nil {
		return nil, fmt.Errorf("creating Cloud Run client: %w", err)
	}
	defer client.Close()

	// Use locations/- to list across all regions.
	parent := fmt.Sprintf("projects/%s/locations/-", projectID)

	var services []ServiceInfo
	it := client.ListServices(ctx, &runpb.ListServicesRequest{
		Parent: parent,
	})

	for {
		svc, err := it.Next()
		if err == iterator.Done {
			break
		}
		if err != nil {
			return nil, fmt.Errorf("iterating services: %w", err)
		}

		info := parseService(svc)
		services = append(services, info)
	}

	return services, nil
}

// parseService converts a Cloud Run Service proto into our ServiceInfo shape.
func parseService(svc *runpb.Service) ServiceInfo {
	// svc.Name is like "projects/PROJECT/locations/REGION/services/SERVICE_NAME"
	fullName := svc.Name
	serviceName := lastSegment(fullName)
	region := extractSegment(fullName, "locations")

	appName, env := splitServiceName(serviceName)

	status := "Unknown"
	if cond := findCondition(svc, "Ready"); cond != nil {
		if cond.State == runpb.Condition_CONDITION_SUCCEEDED {
			status = "Ready"
		} else if cond.State == runpb.Condition_CONDITION_FAILED {
			status = "Failed"
		} else {
			status = "Pending"
		}
	}

	revision := ""
	if svc.LatestReadyRevision != "" {
		revision = lastSegment(svc.LatestReadyRevision)
	}

	lastDeployed := ""
	if svc.UpdateTime != nil {
		lastDeployed = svc.UpdateTime.AsTime().UTC().Format(time.RFC3339)
	}

	url := svc.Uri

	return ServiceInfo{
		Name:         appName,
		Service:      serviceName,
		Environment:  env,
		Status:       status,
		Revision:     revision,
		LastDeployed: lastDeployed,
		URL:          url,
		Region:       region,
	}
}

// splitServiceName parses "{app}-{env}" or "{app}-fe-{env}" patterns.
func splitServiceName(name string) (appName, environment string) {
	knownEnvs := []string{"dev", "prod", "preview"}

	for _, env := range knownEnvs {
		suffix := "-" + env
		if strings.HasSuffix(name, suffix) {
			base := strings.TrimSuffix(name, suffix)
			// Detect frontend SSO pattern: {app}-fe-{env}
			if strings.HasSuffix(base, "-fe") {
				return strings.TrimSuffix(base, "-fe") + "-fe", env
			}
			return base, env
		}
	}

	// Fallback: split on last hyphen.
	if idx := strings.LastIndex(name, "-"); idx > 0 {
		return name[:idx], name[idx+1:]
	}

	return name, "unknown"
}

// findCondition returns the first terminal condition matching the given type.
func findCondition(svc *runpb.Service, condType string) *runpb.Condition {
	if svc.TerminalCondition != nil && svc.TerminalCondition.Type == condType {
		return svc.TerminalCondition
	}
	for _, c := range svc.Conditions {
		if c.Type == condType {
			return c
		}
	}
	return nil
}

// lastSegment returns the portion after the last "/" in a resource name.
func lastSegment(resource string) string {
	if idx := strings.LastIndex(resource, "/"); idx >= 0 {
		return resource[idx+1:]
	}
	return resource
}

// extractSegment extracts the value after a given segment key in a resource path.
// e.g. extractSegment("projects/P/locations/us-central1/services/foo", "locations") => "us-central1"
func extractSegment(resource, key string) string {
	parts := strings.Split(resource, "/")
	for i, p := range parts {
		if p == key && i+1 < len(parts) {
			return parts[i+1]
		}
	}
	return ""
}

// buildDomainMap queries Cloud DNS and returns a map of domain → domain (all A/CNAME records in the zone).
func buildDomainMap(ctx context.Context, projectID, zoneName string) (map[string]string, error) {
	svc, err := dns.NewService(ctx)
	if err != nil {
		return nil, fmt.Errorf("creating DNS client: %w", err)
	}

	result := make(map[string]string)
	err = svc.ResourceRecordSets.List(projectID, zoneName).Pages(ctx, func(page *dns.ResourceRecordSetsListResponse) error {
		for _, rrs := range page.Rrsets {
			if rrs.Type == "A" || rrs.Type == "CNAME" {
				// Strip trailing dot from DNS name
				domain := strings.TrimSuffix(rrs.Name, ".")
				result[domain] = domain
			}
		}
		return nil
	})
	if err != nil {
		return nil, fmt.Errorf("listing DNS records: %w", err)
	}

	return result, nil
}

// enrichWithDomains matches services to custom domains from the DNS zone.
// Convention: {app}.{base} for prod, {app}.dev.{base} for dev
func enrichWithDomains(services []ServiceInfo, domainMap map[string]string) {
	for i := range services {
		svc := &services[i]
		// Try to match domain patterns from the DNS records
		for domain := range domainMap {
			parts := strings.SplitN(domain, ".", 2)
			if len(parts) < 2 {
				continue
			}
			// Strip the -fe suffix from app name for domain matching
			appName := strings.TrimSuffix(svc.Name, "-fe")

			// Match: {app}.dev.{base} for dev, {app}.{base} for prod
			if svc.Environment == "dev" && strings.HasPrefix(domain, appName+".dev.") {
				svc.CustomDomain = domain
				break
			}
			if svc.Environment == "prod" && parts[0] == appName && !strings.HasPrefix(parts[1], "dev.") {
				svc.CustomDomain = domain
				break
			}
		}
	}
}
