package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	runpb "cloud.google.com/go/run/apiv2/runpb"
	"google.golang.org/protobuf/types/known/timestamppb"
)

func TestHandleHealth(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/api/health", nil)
	rec := httptest.NewRecorder()

	handleHealth(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", rec.Code, http.StatusOK)
	}
	if ct := rec.Header().Get("Content-Type"); ct != "application/json" {
		t.Errorf("Content-Type = %q, want application/json", ct)
	}

	var body map[string]string
	if err := json.NewDecoder(rec.Body).Decode(&body); err != nil {
		t.Fatalf("decoding body: %v", err)
	}
	if body["status"] != "ok" {
		t.Errorf("status field = %q, want ok", body["status"])
	}
}

func TestResolveProjectID(t *testing.T) {
	// The metadata server lookup hits the hardcoded metadata.google.internal
	// host, which is unreachable off-GCE and fails within the 2s client
	// timeout, so these cases exercise the env-var fallback branch.
	t.Run("env fallback", func(t *testing.T) {
		t.Setenv("GOOGLE_CLOUD_PROJECT", "my-project-123")
		id, err := resolveProjectID(t.Context())
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if id != "my-project-123" {
			t.Errorf("project ID = %q, want my-project-123", id)
		}
	})

	t.Run("not found", func(t *testing.T) {
		t.Setenv("GOOGLE_CLOUD_PROJECT", "")
		_, err := resolveProjectID(t.Context())
		if err == nil {
			t.Fatal("expected error when project ID cannot be resolved, got nil")
		}
	})
}

func TestSplitServiceName(t *testing.T) {
	tests := []struct {
		name    string
		input   string
		wantApp string
		wantEnv string
	}{
		{"prod suffix", "mealfit-prod", "mealfit", "prod"},
		{"dev suffix", "mealfit-dev", "mealfit", "dev"},
		{"frontend prod", "mealfit-fe-prod", "mealfit-fe", "prod"},
		{"frontend dev", "mealfit-fe-dev", "mealfit-fe", "dev"},
		{"pr preview", "mealfit-pr-42", "mealfit", "pr-42"},
		{"frontend pr preview", "mealfit-fe-pr-42", "mealfit-fe", "pr-42"},
		{"unknown env fallback splits last hyphen", "some-thing", "some", "thing"},
		{"no hyphen", "single", "single", "unknown"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			gotApp, gotEnv := splitServiceName(tt.input)
			if gotApp != tt.wantApp || gotEnv != tt.wantEnv {
				t.Errorf("splitServiceName(%q) = (%q, %q), want (%q, %q)",
					tt.input, gotApp, gotEnv, tt.wantApp, tt.wantEnv)
			}
		})
	}
}

func TestSplitSiteID(t *testing.T) {
	tests := []struct {
		name    string
		input   string
		wantApp string
		wantEnv string
	}{
		{"prod with random suffix", "mealfit-a1b2-prod", "mealfit", "prod"},
		{"dev with random suffix", "mealfit-a1b2-dev", "mealfit", "dev"},
		{"prod without random suffix", "mealfit-prod", "mealfit", "prod"},
		{"unrecognised env", "mealfit-staging", "", ""},
		{"no env suffix", "mealfit", "", ""},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			gotApp, gotEnv := splitSiteID(tt.input)
			if gotApp != tt.wantApp || gotEnv != tt.wantEnv {
				t.Errorf("splitSiteID(%q) = (%q, %q), want (%q, %q)",
					tt.input, gotApp, gotEnv, tt.wantApp, tt.wantEnv)
			}
		})
	}
}

func TestLastSegment(t *testing.T) {
	tests := []struct {
		input string
		want  string
	}{
		{"projects/p/locations/r/services/foo", "foo"},
		{"foo", "foo"},
		{"", ""},
		{"trailing/", ""},
	}
	for _, tt := range tests {
		if got := lastSegment(tt.input); got != tt.want {
			t.Errorf("lastSegment(%q) = %q, want %q", tt.input, got, tt.want)
		}
	}
}

func TestExtractSegment(t *testing.T) {
	tests := []struct {
		name     string
		resource string
		key      string
		want     string
	}{
		{"locations present", "projects/P/locations/us-central1/services/foo", "locations", "us-central1"},
		{"projects present", "projects/P/locations/r/services/foo", "projects", "P"},
		{"key missing", "projects/P/locations/r/services/foo", "regions", ""},
		{"key is last with no value", "projects/P/locations", "locations", ""},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := extractSegment(tt.resource, tt.key); got != tt.want {
				t.Errorf("extractSegment(%q, %q) = %q, want %q", tt.resource, tt.key, got, tt.want)
			}
		})
	}
}

func TestFindCondition(t *testing.T) {
	terminal := &runpb.Condition{Type: "Ready", State: runpb.Condition_CONDITION_SUCCEEDED}
	other := &runpb.Condition{Type: "RoutesReady", State: runpb.Condition_CONDITION_PENDING}

	t.Run("terminal condition match", func(t *testing.T) {
		svc := &runpb.Service{TerminalCondition: terminal}
		got := findCondition(svc, "Ready")
		if got != terminal {
			t.Errorf("expected terminal condition, got %+v", got)
		}
	})

	t.Run("from conditions slice", func(t *testing.T) {
		svc := &runpb.Service{Conditions: []*runpb.Condition{other, terminal}}
		got := findCondition(svc, "Ready")
		if got != terminal {
			t.Errorf("expected Ready condition from slice, got %+v", got)
		}
	})

	t.Run("no match", func(t *testing.T) {
		svc := &runpb.Service{Conditions: []*runpb.Condition{other}}
		if got := findCondition(svc, "Ready"); got != nil {
			t.Errorf("expected nil, got %+v", got)
		}
	})
}

func TestParseService(t *testing.T) {
	updated := time.Date(2026, 6, 20, 10, 30, 0, 0, time.UTC)

	tests := []struct {
		name         string
		svc          *runpb.Service
		wantName     string
		wantService  string
		wantEnv      string
		wantStatus   string
		wantRevision string
		wantRegion   string
		wantURL      string
		wantDeployed string
	}{
		{
			name: "ready prod service",
			svc: &runpb.Service{
				Name:                "projects/P/locations/us-central1/services/mealfit-prod",
				TerminalCondition:   &runpb.Condition{Type: "Ready", State: runpb.Condition_CONDITION_SUCCEEDED},
				LatestReadyRevision: "projects/P/locations/us-central1/services/mealfit-prod/revisions/mealfit-prod-00007",
				UpdateTime:          timestamppb.New(updated),
				Uri:                 "https://mealfit-prod-abc.a.run.app",
			},
			wantName:     "mealfit",
			wantService:  "mealfit-prod",
			wantEnv:      "prod",
			wantStatus:   "Ready",
			wantRevision: "mealfit-prod-00007",
			wantRegion:   "us-central1",
			wantURL:      "https://mealfit-prod-abc.a.run.app",
			wantDeployed: "2026-06-20T10:30:00Z",
		},
		{
			name: "failed dev service",
			svc: &runpb.Service{
				Name:              "projects/P/locations/europe-west2/services/cerebra-dev",
				TerminalCondition: &runpb.Condition{Type: "Ready", State: runpb.Condition_CONDITION_FAILED},
			},
			wantName:    "cerebra",
			wantService: "cerebra-dev",
			wantEnv:     "dev",
			wantStatus:  "Failed",
			wantRegion:  "europe-west2",
		},
		{
			name: "pending service with no terminal Ready condition",
			svc: &runpb.Service{
				Name:              "projects/P/locations/europe-west2/services/guardian-dev",
				TerminalCondition: &runpb.Condition{Type: "Ready", State: runpb.Condition_CONDITION_PENDING},
			},
			wantName:    "guardian",
			wantService: "guardian-dev",
			wantEnv:     "dev",
			wantStatus:  "Pending",
			wantRegion:  "europe-west2",
		},
		{
			name: "unknown status when no Ready condition",
			svc: &runpb.Service{
				Name: "projects/P/locations/europe-west2/services/pulse-dev",
			},
			wantName:    "pulse",
			wantService: "pulse-dev",
			wantEnv:     "dev",
			wantStatus:  "Unknown",
			wantRegion:  "europe-west2",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := parseService(tt.svc)
			if got.Name != tt.wantName {
				t.Errorf("Name = %q, want %q", got.Name, tt.wantName)
			}
			if got.Service != tt.wantService {
				t.Errorf("Service = %q, want %q", got.Service, tt.wantService)
			}
			if got.Environment != tt.wantEnv {
				t.Errorf("Environment = %q, want %q", got.Environment, tt.wantEnv)
			}
			if got.Status != tt.wantStatus {
				t.Errorf("Status = %q, want %q", got.Status, tt.wantStatus)
			}
			if got.Revision != tt.wantRevision {
				t.Errorf("Revision = %q, want %q", got.Revision, tt.wantRevision)
			}
			if got.Region != tt.wantRegion {
				t.Errorf("Region = %q, want %q", got.Region, tt.wantRegion)
			}
			if got.URL != tt.wantURL {
				t.Errorf("URL = %q, want %q", got.URL, tt.wantURL)
			}
			if got.LastDeployed != tt.wantDeployed {
				t.Errorf("LastDeployed = %q, want %q", got.LastDeployed, tt.wantDeployed)
			}
		})
	}
}

func TestEnrichWithDomains(t *testing.T) {
	t.Run("matches prod and dev domains", func(t *testing.T) {
		services := []ServiceInfo{
			{Name: "mealfit", Environment: "prod"},
			{Name: "mealfit", Environment: "dev"},
		}
		domainMap := map[string]string{
			"mealfit.example.com":     "mealfit.example.com",
			"mealfit.dev.example.com": "mealfit.dev.example.com",
		}
		enrichWithDomains(services, domainMap)

		if services[0].CustomDomain != "mealfit.example.com" {
			t.Errorf("prod CustomDomain = %q, want mealfit.example.com", services[0].CustomDomain)
		}
		if services[1].CustomDomain != "mealfit.dev.example.com" {
			t.Errorf("dev CustomDomain = %q, want mealfit.dev.example.com", services[1].CustomDomain)
		}
	})

	t.Run("strips -fe suffix before matching", func(t *testing.T) {
		services := []ServiceInfo{{Name: "mealfit-fe", Environment: "prod"}}
		domainMap := map[string]string{"mealfit.example.com": "mealfit.example.com"}
		enrichWithDomains(services, domainMap)

		if services[0].CustomDomain != "mealfit.example.com" {
			t.Errorf("CustomDomain = %q, want mealfit.example.com", services[0].CustomDomain)
		}
	})

	t.Run("prod does not match a dev domain", func(t *testing.T) {
		services := []ServiceInfo{{Name: "mealfit", Environment: "prod"}}
		domainMap := map[string]string{"mealfit.dev.example.com": "mealfit.dev.example.com"}
		enrichWithDomains(services, domainMap)

		if services[0].CustomDomain != "" {
			t.Errorf("CustomDomain = %q, want empty (prod should not match dev domain)", services[0].CustomDomain)
		}
	})

	t.Run("no match leaves CustomDomain empty", func(t *testing.T) {
		services := []ServiceInfo{{Name: "other", Environment: "prod"}}
		domainMap := map[string]string{"mealfit.example.com": "mealfit.example.com"}
		enrichWithDomains(services, domainMap)

		if services[0].CustomDomain != "" {
			t.Errorf("CustomDomain = %q, want empty", services[0].CustomDomain)
		}
	})
}
