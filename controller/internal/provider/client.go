package provider

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"regexp"
	"strings"
	"time"

	"github.com/theonemule/docker-waf/controller/internal/model"
)

type State struct {
	OK       bool     `json:"ok"`
	Revision int64    `json:"revision"`
	Digest   string   `json:"digest"`
	Hosts    []string `json:"hosts"`
	Changed  bool     `json:"changed"`
}

// Rejection coordinates refer only to the exact submitted snapshot. The
// appliance emits them for deterministic semantic/ownership errors, never
// authentication, revision, runtime render, or transport failures.
type Rejection struct {
	StreamIndex *int   `json:"stream_index,omitempty"`
	SiteIndex   *int   `json:"site_index"`
	RouteIndex  *int   `json:"route_index,omitempty"`
	Field       string `json:"field,omitempty"`
	Reason      string `json:"reason,omitempty"`
}
type HTTPError struct {
	Status    int
	Method    string
	Rejection *Rejection
}

func (e *HTTPError) Error() string {
	return fmt.Sprintf("provider rejected %s with HTTP %d", e.Method, e.Status)
}

type Client struct {
	endpoint, tokenFile string
	http                *http.Client
}

func New(endpoint, id, tokenFile, caFile string) (*Client, error) {
	u, err := url.Parse(endpoint)
	if err != nil || u.Scheme != "https" || u.Host == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" || (u.Path != "" && u.Path != "/") {
		return nil, fmt.Errorf("provider endpoint must be an HTTPS origin")
	}
	if !regexp.MustCompile("^[a-z0-9][a-z0-9-]{0,62}$").MatchString(id) {
		return nil, fmt.Errorf("invalid provider ID")
	}
	roots, err := x509.SystemCertPool()
	if err != nil || roots == nil {
		roots = x509.NewCertPool()
	}
	if caFile != "" {
		pem, err := os.ReadFile(caFile)
		if err != nil {
			return nil, fmt.Errorf("read CA: %w", err)
		}
		if !roots.AppendCertsFromPEM(pem) {
			return nil, fmt.Errorf("invalid CA PEM")
		}
	}
	tr := http.DefaultTransport.(*http.Transport).Clone()
	tr.TLSClientConfig = &tls.Config{MinVersion: tls.VersionTLS12, RootCAs: roots}
	tr.Proxy = nil
	return &Client{endpoint: strings.TrimRight(endpoint, "/") + "/api/v1/providers/" + id + "/state", tokenFile: tokenFile, http: &http.Client{Transport: tr, Timeout: 3 * time.Minute, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}}, nil
}
func (c *Client) request(ctx context.Context, method string, snapshot *model.Snapshot) (State, error) {
	var s State
	token, err := os.ReadFile(c.tokenFile)
	if err != nil {
		return s, fmt.Errorf("read provider token: %w", err)
	}
	value := strings.TrimSpace(string(token))
	if !regexp.MustCompile("^[A-Za-z0-9_-]{43,256}$").MatchString(value) {
		return s, fmt.Errorf("invalid provider token format")
	}
	var body io.Reader
	if snapshot != nil {
		data, err := json.Marshal(snapshot)
		if err != nil {
			return s, err
		}
		if len(data) > 4*1024*1024 {
			return s, fmt.Errorf("snapshot exceeds provider limit")
		}
		body = bytes.NewReader(data)
	}
	req, err := http.NewRequestWithContext(ctx, method, c.endpoint, body)
	if err != nil {
		return s, err
	}
	req.Header.Set("Authorization", "Bearer "+value)
	req.Header.Set("Content-Type", "application/json")
	resp, err := c.http.Do(req)
	if err != nil {
		return s, fmt.Errorf("provider request failed: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		var body struct {
			Rejection *Rejection `json:"rejection"`
		}
		if resp.StatusCode == 400 || resp.StatusCode == 403 || resp.StatusCode == 409 {
			_ = json.NewDecoder(io.LimitReader(resp.Body, 64<<10)).Decode(&body)
		}
		return s, &HTTPError{Status: resp.StatusCode, Method: method, Rejection: body.Rejection}
	}
	if err = json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&s); err != nil || !s.OK || s.Revision < 0 {
		return State{}, fmt.Errorf("invalid provider response")
	}
	return s, nil
}
func (c *Client) Get(ctx context.Context) (State, error) { return c.request(ctx, http.MethodGet, nil) }
func (c *Client) Apply(ctx context.Context, snapshot model.Snapshot) (State, error) {
	return c.request(ctx, http.MethodPut, &snapshot)
}

// Validate checks a complete snapshot against the current revision and policy
// without writing it. Apply always repeats these checks under the write lock.
func (c *Client) Validate(ctx context.Context, s model.Snapshot) (State, error) {
	return c.request(ctx, http.MethodPost, &s)
}
