package main

import (
	"bufio"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// roundTripFunc lets a test stand in for an http.RoundTripper without binding
// a real network port (httptest.NewServer is unavailable in the sandbox).
type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

// withProxyClient swaps proxyClient for the duration of a test.
func withProxyClient(t *testing.T, rt roundTripFunc) {
	t.Helper()
	prev := proxyClient
	proxyClient = &http.Client{Transport: rt}
	t.Cleanup(func() { proxyClient = prev })
}

// stubResponse builds a minimal *http.Response for the round-trip stub.
func stubResponse(status int, body string) *http.Response {
	return &http.Response{
		StatusCode: status,
		Header:     make(http.Header),
		Body:       io.NopCloser(strings.NewReader(body)),
	}
}

func staticTokenFn(tok string, err error) tokenFunc {
	return func(audience string) (string, error) { return tok, err }
}

func TestProxyHandler_ForwardsAndRekeysHeaders(t *testing.T) {
	var got *http.Request
	var gotBody []byte
	withProxyClient(t, func(r *http.Request) (*http.Response, error) {
		got = r
		if r.Body != nil {
			gotBody, _ = io.ReadAll(r.Body)
		}
		return stubResponse(http.StatusOK, "upstream-ok"), nil
	})

	h := newProxyHandler("http://backend.internal", staticTokenFn("tok-123", nil))
	req := httptest.NewRequest(http.MethodPost, "/api/things?q=1&n=2", strings.NewReader("payload"))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Goog-Authenticated-User-Email", "accounts.google.com:user@example.com")
	req.Header.Set("X-Goog-Authenticated-User-Id", "accounts.google.com:42")
	rec := httptest.NewRecorder()

	h(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", rec.Code, http.StatusOK)
	}
	if rec.Body.String() != "upstream-ok" {
		t.Errorf("body = %q, want upstream-ok", rec.Body.String())
	}
	if got == nil {
		t.Fatal("no outbound request captured")
	}
	if string(gotBody) != "payload" {
		t.Errorf("outbound body = %q, want payload", string(gotBody))
	}
	if got.URL.String() != "http://backend.internal/api/things?q=1&n=2" {
		t.Errorf("target URL = %q", got.URL.String())
	}
	if h := got.Header.Get("Authorization"); h != "Bearer tok-123" {
		t.Errorf("Authorization = %q, want Bearer tok-123", h)
	}
	if h := got.Header.Get("X-Stackramp-User-Email"); h != "user@example.com" {
		t.Errorf("X-Stackramp-User-Email = %q", h)
	}
	if h := got.Header.Get("X-Stackramp-User-Id"); h != "42" {
		t.Errorf("X-Stackramp-User-Id = %q, want 42", h)
	}
	if got.Header.Get("X-Goog-Authenticated-User-Email") != "" {
		t.Errorf("original IAP email header must not be forwarded")
	}
}

func TestProxyHandler_ForwardsNon2xx(t *testing.T) {
	withProxyClient(t, func(r *http.Request) (*http.Response, error) {
		return stubResponse(http.StatusNotFound, "not found"), nil
	})

	h := newProxyHandler("http://backend.internal", staticTokenFn("tok", nil))
	req := httptest.NewRequest(http.MethodGet, "/api/missing", nil)
	rec := httptest.NewRecorder()
	h(rec, req)

	if rec.Code != http.StatusNotFound {
		t.Fatalf("status = %d, want %d", rec.Code, http.StatusNotFound)
	}
	if rec.Body.String() != "not found" {
		t.Errorf("body = %q, want not found", rec.Body.String())
	}
}

func TestProxyHandler_TokenError(t *testing.T) {
	called := false
	withProxyClient(t, func(r *http.Request) (*http.Response, error) {
		called = true
		return stubResponse(http.StatusOK, ""), nil
	})

	h := newProxyHandler("http://backend.internal", staticTokenFn("", errors.New("no token")))
	req := httptest.NewRequest(http.MethodGet, "/api/x", nil)
	rec := httptest.NewRecorder()
	h(rec, req)

	if rec.Code != http.StatusBadGateway {
		t.Fatalf("status = %d, want %d", rec.Code, http.StatusBadGateway)
	}
	if called {
		t.Error("backend must not be called when token fetch fails")
	}
}

func TestProxyHandler_BackendUnreachable(t *testing.T) {
	withProxyClient(t, func(r *http.Request) (*http.Response, error) {
		return nil, errors.New("dial failed")
	})

	h := newProxyHandler("http://backend.internal", staticTokenFn("tok", nil))
	req := httptest.NewRequest(http.MethodGet, "/api/x", nil)
	rec := httptest.NewRecorder()
	h(rec, req)

	if rec.Code != http.StatusBadGateway {
		t.Fatalf("status = %d, want %d", rec.Code, http.StatusBadGateway)
	}
}

func TestSPAHandler_ServesIndexFallback(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, filepath.Join(dir, "index.html"), "<!doctype html><title>app</title>")

	h := newSPAHandler(dir)
	req := httptest.NewRequest(http.MethodGet, "/some/spa/route", nil)
	rec := httptest.NewRecorder()
	h(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", rec.Code, http.StatusOK)
	}
	if !strings.Contains(rec.Body.String(), "<!doctype html><title>app</title>") {
		t.Errorf("body = %q, want index.html contents", rec.Body.String())
	}
}

func TestSPAHandler_ServesStaticFile(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, filepath.Join(dir, "index.html"), "index")
	writeFile(t, filepath.Join(dir, "app.js"), "console.log(1)")

	h := newSPAHandler(dir)
	req := httptest.NewRequest(http.MethodGet, "/app.js", nil)
	rec := httptest.NewRecorder()
	h(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", rec.Code, http.StatusOK)
	}
	if rec.Body.String() != "console.log(1)" {
		t.Errorf("body = %q, want static file contents", rec.Body.String())
	}
}

func writeFile(t *testing.T, path, content string) {
	t.Helper()
	f, err := os.Create(path)
	if err != nil {
		t.Fatalf("create %s: %v", path, err)
	}
	defer f.Close()
	w := bufio.NewWriter(f)
	if _, err := w.WriteString(content); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
	if err := w.Flush(); err != nil {
		t.Fatalf("flush %s: %v", path, err)
	}
}

func TestCachedIdentityToken_ReturnsCachedWhileValid(t *testing.T) {
	// Seed a live cache entry; the function must return it without contacting
	// the metadata server (which is unreachable here anyway).
	tokenCache.Lock()
	tokenCache.token = "cached-token"
	tokenCache.expires = time.Now().Add(10 * time.Minute)
	tokenCache.Unlock()
	t.Cleanup(func() {
		tokenCache.Lock()
		tokenCache.token = ""
		tokenCache.expires = time.Time{}
		tokenCache.Unlock()
	})

	got, err := cachedIdentityToken("https://backend.internal")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got != "cached-token" {
		t.Errorf("token = %q, want cached-token", got)
	}
}

func TestFetchIdentityToken_Success(t *testing.T) {
	var gotURL, gotFlavor string
	withProxyClient(t, func(r *http.Request) (*http.Response, error) {
		gotURL = r.URL.String()
		gotFlavor = r.Header.Get("Metadata-Flavor")
		return stubResponse(http.StatusOK, "  signed-jwt-token\n"), nil
	})

	tok, err := fetchIdentityToken("https://backend.internal")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if tok != "signed-jwt-token" {
		t.Errorf("token = %q, want trimmed signed-jwt-token", tok)
	}
	if gotFlavor != "Google" {
		t.Errorf("Metadata-Flavor = %q, want Google", gotFlavor)
	}
	if !strings.Contains(gotURL, "audience=https://backend.internal") {
		t.Errorf("metadata URL = %q, missing audience", gotURL)
	}
}

func TestFetchIdentityToken_Non200(t *testing.T) {
	withProxyClient(t, func(r *http.Request) (*http.Response, error) {
		return stubResponse(http.StatusForbidden, "denied"), nil
	})

	_, err := fetchIdentityToken("https://backend.internal")
	if err == nil {
		t.Fatal("expected error on non-200 metadata response")
	}
	if !strings.Contains(err.Error(), "403") {
		t.Errorf("error = %v, want it to mention 403", err)
	}
}

func TestCachedIdentityToken_FetchesOnMiss(t *testing.T) {
	tokenCache.Lock()
	tokenCache.token = ""
	tokenCache.expires = time.Time{}
	tokenCache.Unlock()
	t.Cleanup(func() {
		tokenCache.Lock()
		tokenCache.token = ""
		tokenCache.expires = time.Time{}
		tokenCache.Unlock()
	})

	calls := 0
	withProxyClient(t, func(r *http.Request) (*http.Response, error) {
		calls++
		return stubResponse(http.StatusOK, "fresh-token"), nil
	})

	tok, err := cachedIdentityToken("https://backend.internal")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if tok != "fresh-token" {
		t.Errorf("token = %q, want fresh-token", tok)
	}

	// Second call must hit the cache, not the metadata client again.
	if _, err := cachedIdentityToken("https://backend.internal"); err != nil {
		t.Fatalf("unexpected error on cached call: %v", err)
	}
	if calls != 1 {
		t.Errorf("metadata client calls = %d, want 1 (second call should be cached)", calls)
	}
}
