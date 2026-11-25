package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func ms(v int) *int           { return &v }
func encoded(c Config) string { b, _ := json.Marshal(c); return base64.StdEncoding.EncodeToString(b) }
func TestConfigValidation(t *testing.T) {
	c := Config{Backends: []Backend{{"http://127.0.0.1:8080", 1}}, Deadlines: &Deadlines{ms(200), ms(100)}}
	if _, err := decode(encoded(c)); err != nil {
		t.Fatal(err)
	}
	for _, target := range []string{"http://127.0.0.1:8080/path", "https://127.0.0.1:8080", "http://name", "http://user@name:8080", "http://name:8080?secret=1"} {
		c.Backends[0].Target = target
		if _, err := decode(encoded(c)); err == nil {
			t.Fatalf("accepted %s", target)
		}
	}
	c.Backends[0].Target = "http://127.0.0.1:8080"
	c.Deadlines.Backend = ms(201)
	if _, err := decode(encoded(c)); err == nil {
		t.Fatal("invalid ordering")
	}
}
func TestTimeoutCancelsAndRetryBackoff(t *testing.T) {
	var count atomic.Int32
	var elapsed atomic.Int64
	start := time.Now()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if count.Add(1) == 1 {
			select {
			case <-r.Context().Done():
			case <-time.After(time.Second):
			}
			return
		}
		elapsed.Store(int64(time.Since(start)))
		w.Header().Set("Content-Length", "2")
		io.WriteString(w, "ok")
	}))
	defer srv.Close()
	c := Config{Backends: []Backend{{srv.URL, 1}}, Deadlines: &Deadlines{ms(1500), ms(100)}, Retry: &Retry{Attempts: 1, Backoff: 100}}
	r := httptest.NewRequest("GET", "http://original.example/test?x=1", nil)
	r.Header.Set(controlHeader, encoded(c))
	w := httptest.NewRecorder()
	handler(make(chan struct{}, 1)).ServeHTTP(w, r)
	if w.Code != 200 || w.Body.String() != "ok" || count.Load() != 2 || time.Duration(elapsed.Load()) < 190*time.Millisecond {
		t.Fatalf("code=%d count=%d elapsed=%s", w.Code, count.Load(), time.Duration(elapsed.Load()))
	}
}
func TestRequestBudgetAndUntrustedHeader(t *testing.T) {
	var calls atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		if r.Header.Get(controlHeader) != "" {
			t.Error("control header leaked")
		}
		w.WriteHeader(503)
	}))
	defer srv.Close()
	c := Config{Backends: []Backend{{srv.URL, 1}}, Deadlines: &Deadlines{ms(100), ms(50)}, Retry: &Retry{Attempts: 2, Codes: []int{503}, Backoff: 500}}
	r := httptest.NewRequest("GET", "http://original.example/test", nil)
	r.Header.Set(controlHeader, encoded(c))
	w := httptest.NewRecorder()
	handler(make(chan struct{}, 1)).ServeHTTP(w, r)
	if w.Code != 504 || calls.Load() != 1 {
		t.Fatalf("code=%d attempts=%d", w.Code, calls.Load())
	}
	r = httptest.NewRequest("POST", "http://original.example/test", strings.NewReader("value=1"))
	r.Header.Set(controlHeader, encoded(c))
	w = httptest.NewRecorder()
	handler(make(chan struct{}, 1)).ServeHTTP(w, r)
	if w.Code != 503 || calls.Load() != 2 {
		t.Fatalf("POST replay: %d %d", w.Code, calls.Load())
	}
	r = httptest.NewRequest("GET", "http://original.example/test", nil)
	r.Header.Add(controlHeader, encoded(c))
	r.Header.Add(controlHeader, encoded(c))
	w = httptest.NewRecorder()
	handler(make(chan struct{}, 1)).ServeHTTP(w, r)
	if w.Code != 502 || calls.Load() != 2 {
		t.Fatal("duplicate control header accepted")
	}
}
func TestCanceledRequest(t *testing.T) {
	c := Config{Backends: []Backend{{"http://127.0.0.1:1", 1}}, Deadlines: &Deadlines{ms(1000), nil}}
	r := httptest.NewRequest("GET", "http://original.example/test", nil)
	r.Header.Set(controlHeader, encoded(c))
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	w := httptest.NewRecorder()
	handler(make(chan struct{}, 1)).ServeHTTP(w, r.WithContext(ctx))
	if w.Code != 502 {
		t.Fatalf("canceled request: %d", w.Code)
	}
}
