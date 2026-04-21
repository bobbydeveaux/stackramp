// Lightweight reverse proxy for Cloud Run SSO frontends.
// Serves static files and proxies /api/* to the backend with an identity token.
package main

import (
	"fmt"
	"io"
	"log"
	"net/http"
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

	// /api/* proxy to backend with service-to-service identity token.
	// IMPORTANT: We build a fresh HTTP request instead of using httputil.ReverseProxy
	// because the original browser request carries IAP headers (X-Goog-Iap-Jwt-Assertion)
	// from the frontend. If forwarded, Cloud Run's auth layer on the backend picks up the
	// IAP JWT (issued for the frontend) instead of our Authorization header and returns 401.
	if backendURL != "" {
		mux.HandleFunc("/api/", func(w http.ResponseWriter, r *http.Request) {
			targetURL := backendURL + r.URL.Path
			if r.URL.RawQuery != "" {
				targetURL += "?" + r.URL.RawQuery
			}

			token, err := fetchIdentityToken(backendURL)
			if err != nil {
				log.Printf("ERROR: identity token: %v", err)
				http.Error(w, "proxy auth error", 502)
				return
			}

			proxyReq, err := http.NewRequest(r.Method, targetURL, r.Body)
			if err != nil {
				http.Error(w, "proxy error", 502)
				return
			}
			proxyReq.Header.Set("Authorization", "Bearer "+token)
			if ct := r.Header.Get("Content-Type"); ct != "" {
				proxyReq.Header.Set("Content-Type", ct)
			}

			resp, err := http.DefaultClient.Do(proxyReq)
			if err != nil {
				log.Printf("ERROR: backend request: %v", err)
				http.Error(w, "backend unreachable", 502)
				return
			}
			defer resp.Body.Close()

			// Forward response headers and body
			for k, v := range resp.Header {
				for _, vv := range v {
					w.Header().Add(k, vv)
				}
			}
			w.WriteHeader(resp.StatusCode)
			io.Copy(w, resp.Body)
		})
	}

	// SPA catch-all: serve index.html for all non-file routes
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		path := "/app/dist" + r.URL.Path
		if _, err := os.Stat(path); err == nil && !strings.HasSuffix(r.URL.Path, "/") {
			fs.ServeHTTP(w, r)
			return
		}
		http.ServeFile(w, r, "/app/dist/index.html")
	})

	log.Printf("Listening on :%s (backend: %s)", port, backendURL)
	log.Fatal(http.ListenAndServe(":"+port, mux))
}

// fetchIdentityToken gets an identity token from the GCE metadata server.
func fetchIdentityToken(audience string) (string, error) {
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
