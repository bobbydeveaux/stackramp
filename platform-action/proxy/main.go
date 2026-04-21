// Lightweight reverse proxy for Cloud Run SSO frontends.
// Serves static files and proxies /api/* to the backend with an identity token.
package main

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"strings"
)

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}
	backendURL := os.Getenv("BACKEND_URL")

	mux := http.NewServeMux()

	// Serve static files from /app/dist
	fs := http.FileServer(http.Dir("/app/dist"))

	// /api/* proxy to backend
	if backendURL != "" {
		target, err := url.Parse(backendURL)
		if err != nil {
			log.Fatalf("invalid BACKEND_URL: %v", err)
		}

		proxy := &httputil.ReverseProxy{
			Director: func(req *http.Request) {
				req.URL.Scheme = target.Scheme
				req.URL.Host = target.Host
				req.Host = target.Host

				// Fetch identity token from metadata server for service-to-service auth
				token, err := fetchIdentityToken(target.String())
				if err != nil {
					log.Printf("WARNING: failed to fetch identity token: %v", err)
				} else if token != "" {
					// Decode JWT claims for debugging
					logJWTClaims(token)
					req.Header.Set("Authorization", "Bearer "+token)
				} else {
					log.Printf("WARNING: empty identity token returned")
				}
			},
			ModifyResponse: func(resp *http.Response) error {
				if resp.StatusCode >= 400 {
					log.Printf("Backend responded %d for %s %s", resp.StatusCode, resp.Request.Method, resp.Request.URL.Path)
					if resp.StatusCode == 401 || resp.StatusCode == 403 {
						body, _ := io.ReadAll(resp.Body)
						resp.Body.Close()
						log.Printf("Backend %d body: %.500s", resp.StatusCode, string(body))
						resp.Body = io.NopCloser(strings.NewReader(string(body)))
						resp.ContentLength = int64(len(body))
					}
				}
				return nil
			},
		}

		mux.Handle("/api/", proxy)
	}

	// SPA catch-all: serve index.html for all non-file routes
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		// Try serving the file directly
		path := "/app/dist" + r.URL.Path
		if _, err := os.Stat(path); err == nil && !strings.HasSuffix(r.URL.Path, "/") {
			fs.ServeHTTP(w, r)
			return
		}
		// Fall back to index.html for SPA routing
		http.ServeFile(w, r, "/app/dist/index.html")
	})

	log.Printf("Listening on :%s (backend: %s)", port, backendURL)
	log.Fatal(http.ListenAndServe(":"+port, mux))
}

// logJWTClaims decodes and logs key claims from a JWT token (for debugging).
func logJWTClaims(token string) {
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		log.Printf("WARNING: token is not a valid JWT (parts=%d)", len(parts))
		return
	}
	// Decode the payload (second part)
	payload, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		log.Printf("WARNING: failed to decode JWT payload: %v", err)
		return
	}
	var claims map[string]interface{}
	if err := json.Unmarshal(payload, &claims); err != nil {
		log.Printf("WARNING: failed to parse JWT claims: %v", err)
		return
	}
	log.Printf("JWT claims: iss=%v aud=%v email=%v sub=%v", claims["iss"], claims["aud"], claims["email"], claims["sub"])
}

// fetchIdentityToken gets an identity token from the GCE metadata server.
// Only works on Cloud Run / GCE / GKE.
func fetchIdentityToken(audience string) (string, error) {
	// NOTE: Do NOT url.QueryEscape the audience — the metadata server expects
	// the raw URL and will set the aud claim to exactly what is passed.
	metaURL := fmt.Sprintf(
		"http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/identity?audience=%s",
		audience,
	)
	req, err := http.NewRequest("GET", metaURL, nil)
	if err != nil {
		return "", err
	}
	req.Header.Set("Metadata-Flavor", "Google")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", err
	}

	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("metadata server returned %d: %s", resp.StatusCode, strings.TrimSpace(string(body)))
	}

	return strings.TrimSpace(string(body)), nil
}
