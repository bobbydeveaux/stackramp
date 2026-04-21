// Lightweight reverse proxy for Cloud Run SSO frontends.
// Serves static files and proxies /api/* to the backend with an identity token.
package main

import (
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
				if err == nil && token != "" {
					req.Header.Set("Authorization", "Bearer "+token)
				}
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

// fetchIdentityToken gets an identity token from the GCE metadata server.
// Only works on Cloud Run / GCE / GKE.
func fetchIdentityToken(audience string) (string, error) {
	url := fmt.Sprintf(
		"http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/identity?audience=%s",
		audience,
	)
	req, err := http.NewRequest("GET", url, nil)
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
	return strings.TrimSpace(string(body)), nil
}
