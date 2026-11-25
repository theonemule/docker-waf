package provider

import (
	"context"
	"encoding/json"
	"github.com/theonemule/docker-waf/controller/internal/model"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestClient(t *testing.T) {
	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/v1/providers/cluster-a/state" || r.Header.Get("Authorization") != "Bearer "+strings.Repeat("A", 43) {
			t.Error("wrong path or auth")
			w.WriteHeader(401)
			return
		}
		if r.Method == "PUT" {
			var s model.Snapshot
			if json.NewDecoder(r.Body).Decode(&s) != nil || s.Revision != 7 || s.Sites == nil {
				t.Error("bad snapshot")
			}
		}
		w.Write([]byte("{\"ok\":true,\"revision\":7,\"hosts\":[]}"))
	}))
	defer srv.Close()
	token := filepath.Join(t.TempDir(), "token")
	os.WriteFile(token, []byte(strings.Repeat("A", 43)), 0600)
	c, err := New(srv.URL, "cluster-a", token, "")
	if err != nil {
		t.Fatal(err)
	}
	c.http = srv.Client()
	if s, err := c.Get(context.Background()); err != nil || s.Revision != 7 {
		t.Fatalf("%+v %v", s, err)
	}
	if _, err := c.Apply(context.Background(), model.Snapshot{Revision: 7, Sites: []model.Site{}}); err != nil {
		t.Fatal(err)
	}
	if _, err := New("http://example.test", "cluster-a", token, ""); err == nil {
		t.Fatal("plaintext accepted")
	}
}
