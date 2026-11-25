// Appliance-local HTTP deadline proxy. The only listener is a private Unix
// socket; route configuration comes from a renderer-generated header.
package main

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"math/rand/v2"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

const controlHeader = "X-LiteEdge-Deadline-Config"
const backendHeader = "X-LiteEdge-Deadline-Backend"
const attemptsHeader = "X-LiteEdge-Deadline-Attempts"
const maxMS = 3600000

type Backend struct {
	Target string `json:"target"`
	Weight int    `json:"weight"`
}
type Deadlines struct {
	Request *int `json:"request_ms"`
	Backend *int `json:"backend_ms"`
}
type Retry struct {
	Attempts int   `json:"attempts"`
	Codes    []int `json:"codes"`
	Budget   int   `json:"budget_ms"`
	Backoff  int   `json:"backoff_ms"`
}
type Trust struct {
	Hostname string `json:"hostname"`
	CA       string `json:"ca_certificate"`
}
type Config struct {
	Backends  []Backend         `json:"backends"`
	Deadlines *Deadlines        `json:"deadlines"`
	Retry     *Retry            `json:"retry"`
	TLS       *Trust            `json:"backend_tls"`
	Peers     map[string]*Trust `json:"backend_tls_peers"`
}

func duration(v *int) time.Duration {
	if v == nil {
		return 60 * time.Second
	}
	if *v == 0 {
		return time.Duration(maxMS) * time.Millisecond
	}
	return time.Duration(*v) * time.Millisecond
}
func validMS(v *int) bool { return v == nil || *v >= 0 && *v <= maxMS }
func decode(raw string) (Config, error) {
	var c Config
	if len(raw) > 65536 {
		return c, errors.New("configuration too large")
	}
	b, err := base64.StdEncoding.DecodeString(raw)
	if err != nil {
		return c, err
	}
	d := json.NewDecoder(strings.NewReader(string(b)))
	d.DisallowUnknownFields()
	if err = d.Decode(&c); err != nil {
		return c, err
	}
	if d.Decode(new(any)) != io.EOF {
		return c, errors.New("trailing configuration")
	}
	if len(c.Backends) < 1 || len(c.Backends) > 16 {
		return c, errors.New("invalid backend count")
	}
	if c.TLS != nil && len(c.Peers) > 0 {
		return c, errors.New("conflicting TLS settings")
	}
	seen := map[string]bool{}
	for _, b := range c.Backends {
		if b.Weight < 1 || b.Weight > 1000000 || seen[b.Target] {
			return c, errors.New("invalid backend weight or duplicate")
		}
		seen[b.Target] = true
		if b.Target == "invalid" || b.Target == "unavailable" {
			if c.TLS != nil || c.Retry != nil && c.Retry.Attempts > 0 {
				return c, errors.New("invalid local backend combination")
			}
			continue
		}
		u, e := url.Parse(b.Target)
		scheme := "http"
		if c.TLS != nil || c.Peers[b.Target] != nil {
			scheme = "https"
		}
		if e != nil || u.Scheme != scheme || u.Hostname() == "" || u.User != nil || u.Path != "" || u.RawQuery != "" || u.Fragment != "" || u.Opaque != "" || u.ForceQuery {
			return c, errors.New("invalid origin")
		}
		p, e := strconv.Atoi(u.Port())
		if e != nil || p < 1 || p > 65535 {
			return c, errors.New("invalid origin port")
		}
	}
	for target, trust := range c.Peers {
		if !seen[target] || trust == nil || !strings.HasPrefix(target, "https://") {
			return c, errors.New("invalid peer trust")
		}
	}
	if c.Deadlines != nil {
		if !validMS(c.Deadlines.Request) || !validMS(c.Deadlines.Backend) || c.Deadlines.Request == nil && c.Deadlines.Backend == nil {
			return c, errors.New("invalid deadline")
		}
		if c.Deadlines.Request != nil && *c.Deadlines.Request > 0 && c.Deadlines.Backend != nil && *c.Deadlines.Backend > *c.Deadlines.Request {
			return c, errors.New("backend deadline exceeds request")
		}
	}
	if c.Retry != nil {
		r := c.Retry
		if r.Attempts < 0 || r.Attempts > 4 || r.Budget < 0 || r.Budget > 60000 || r.Backoff < 0 || r.Backoff > 60000 || r.Attempts == 0 && (r.Budget != 0 || r.Backoff != 0 || len(r.Codes) > 0) {
			return c, errors.New("invalid retry")
		}
		for _, s := range r.Codes {
			if s != 429 && s != 500 && s != 502 && s != 503 && s != 504 {
				return c, errors.New("invalid retry code")
			}
		}
	}
	return c, nil
}

type cancelBody struct {
	io.ReadCloser
	cancel context.CancelFunc
}

func (b cancelBody) Close() error { defer b.cancel(); return b.ReadCloser.Close() }

type attemptInfo struct {
	target string
	count  int
}

func (i *attemptInfo) headers(h http.Header) {
	h.Del(backendHeader)
	h.Del(attemptsHeader)
	if i.target != "" {
		h.Set(backendHeader, i.target)
	}
	h.Set(attemptsHeader, strconv.Itoa(i.count))
}

type exchange struct {
	cfg       Config
	transport *http.Transport
	info      *attemptInfo
	peers     map[string]*http.Transport
}

func (x exchange) pick(exclude string) Backend {
	total := 0
	for _, b := range x.cfg.Backends {
		if len(x.cfg.Backends) == 1 || b.Target != exclude {
			total += b.Weight
		}
	}
	n := rand.IntN(total)
	for _, b := range x.cfg.Backends {
		if len(x.cfg.Backends) > 1 && b.Target == exclude {
			continue
		}
		if n < b.Weight {
			return b
		}
		n -= b.Weight
	}
	panic("invalid pool")
}
func localResponse(r *http.Request, status int) *http.Response {
	body := http.StatusText(status) + "\n"
	return &http.Response{StatusCode: status, Header: http.Header{"Content-Type": {"text/plain; charset=utf-8"}}, Body: io.NopCloser(strings.NewReader(body)), ContentLength: int64(len(body)), Request: r}
}
func (x exchange) RoundTrip(r *http.Request) (*http.Response, error) {
	attempts := 0
	retry := x.cfg.Retry
	// Never replay a request with a body, or a potentially mutating method.
	if retry != nil && (r.Method == "GET" || r.Method == "HEAD" || r.Method == "OPTIONS") && (r.Body == nil || r.Body == http.NoBody) {
		attempts = retry.Attempts
	}
	begin := time.Now()
	var previous string
	for i := 0; ; i++ {
		if err := r.Context().Err(); err != nil {
			return nil, err
		}
		b := x.pick(previous)
		previous = b.Target
		x.info.count++
		x.info.target = b.Target
		if b.Target == "invalid" {
			return localResponse(r, 500), nil
		}
		if b.Target == "unavailable" {
			return localResponse(r, 503), nil
		}
		u, _ := url.Parse(b.Target)
		x.info.target = u.Host
		backendMS := (*int)(nil)
		if x.cfg.Deadlines != nil {
			backendMS = x.cfg.Deadlines.Backend
		}
		ctx, cancel := context.WithTimeout(r.Context(), duration(backendMS))
		req := r.Clone(ctx)
		req.URL.Scheme = u.Scheme
		req.URL.Host = u.Host
		req.RequestURI = ""
		tr := x.transport
		if peer := x.peers[b.Target]; peer != nil {
			tr = peer
		}
		res, err := tr.RoundTrip(req)
		canRetry := err != nil
		if res != nil && retry != nil {
			for _, code := range retry.Codes {
				if res.StatusCode == code {
					canRetry = true
				}
			}
		}
		// Small responses can be completed before committing client headers.
		// This makes an absolute body deadline return 504 rather than a
		// partially delivered success or a generic upstream failure.
		if res != nil && !canRetry && res.ContentLength >= 0 && res.ContentLength <= 65536 {
			body, readErr := io.ReadAll(io.LimitReader(res.Body, 65537))
			res.Body.Close()
			if readErr != nil {
				err = readErr
				res = nil
				canRetry = true
			} else {
				res.Body = io.NopCloser(bytes.NewReader(body))
			}
		}
		delay := time.Duration(0)
		if retry != nil {
			delay = time.Duration(retry.Backoff) * time.Millisecond
		}
		withinBudget := retry == nil || retry.Budget == 0 || time.Since(begin)+delay < time.Duration(retry.Budget)*time.Millisecond
		if !canRetry || i >= attempts || !withinBudget {
			if err != nil {
				timedOut := errors.Is(ctx.Err(), context.DeadlineExceeded)
				cancel()
				if timedOut {
					return nil, context.DeadlineExceeded
				}
				return nil, err
			}
			if res.StatusCode == 101 {
				res.Body.Close()
				cancel()
				return nil, errors.New("upgrade unsupported")
			}
			res.Body = cancelBody{res.Body, cancel}
			return res, nil
		}
		if res != nil {
			res.Body.Close()
		}
		cancel()
		timer := time.NewTimer(delay)
		select {
		case <-timer.C:
		case <-r.Context().Done():
			timer.Stop()
			return nil, r.Context().Err()
		}
	}
}
func transportFor(trust *Trust) (*http.Transport, error) {
	tr := &http.Transport{Proxy: nil, DialContext: (&net.Dialer{}).DialContext, DisableKeepAlives: true, DisableCompression: true, MaxResponseHeaderBytes: 1 << 20}
	if trust != nil {
		roots := x509.NewCertPool()
		if trust.Hostname == "" || !roots.AppendCertsFromPEM([]byte(trust.CA)) {
			return nil, errors.New("invalid trust")
		}
		tr.TLSClientConfig = &tls.Config{RootCAs: roots, ServerName: trust.Hostname, MinVersion: tls.VersionTLS12}
	}
	return tr, nil
}
func handler(slots chan struct{}) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		select {
		case slots <- struct{}{}:
			defer func() { <-slots }()
		default:
			http.Error(w, "Gateway busy", 503)
			return
		}
		if r.Header.Get("Upgrade") != "" || r.Method == "CONNECT" {
			http.Error(w, "Upgrade unsupported on deadline route", 400)
			return
		}
		if len(r.Header.Values(controlHeader)) != 1 {
			http.Error(w, "Invalid gateway configuration", 502)
			return
		}
		c, err := decode(r.Header.Get(controlHeader))
		if err != nil {
			http.Error(w, "Invalid gateway configuration", 502)
			return
		}
		r.Header.Del(controlHeader)
		r.Header.Del(backendHeader)
		r.Header.Del(attemptsHeader)
		requestMS := (*int)(nil)
		if c.Deadlines != nil {
			requestMS = c.Deadlines.Request
		}
		ctx, cancel := context.WithTimeout(r.Context(), duration(requestMS))
		defer cancel()
		tr, err := transportFor(c.TLS)
		if err != nil {
			http.Error(w, "Invalid gateway trust", 502)
			return
		}
		defer tr.CloseIdleConnections()
		peers := map[string]*http.Transport{}
		for target, trust := range c.Peers {
			peer, err := transportFor(trust)
			if err != nil {
				http.Error(w, "Invalid gateway trust", 502)
				return
			}
			peers[target] = peer
			defer peer.CloseIdleConnections()
		}

		info := &attemptInfo{}
		p := httputil.ReverseProxy{FlushInterval: -1, ErrorLog: log.New(io.Discard, "", 0), Transport: exchange{cfg: c, transport: tr, info: info, peers: peers}, ModifyResponse: func(res *http.Response) error { info.headers(res.Header); return nil }, Rewrite: func(p *httputil.ProxyRequest) {
			// NGINX has already applied Host rewrite and trusted forwarding headers.
			p.Out.URL.Scheme = "http"
			p.Out.URL.Host = "deadline.invalid"
			p.Out.Host = p.In.Host
			p.Out.URL.RawQuery = p.In.URL.RawQuery
			for _, h := range []string{"X-Forwarded-For", "X-Forwarded-Host", "X-Forwarded-Proto"} {
				if v := p.In.Header.Values(h); len(v) > 0 {
					p.Out.Header[h] = append([]string(nil), v...)
				}
			}
		}, ErrorHandler: func(w http.ResponseWriter, r *http.Request, e error) {
			info.headers(w.Header())
			if errors.Is(e, context.DeadlineExceeded) || errors.Is(r.Context().Err(), context.DeadlineExceeded) {
				http.Error(w, "Gateway Timeout", 504)
			} else {
				http.Error(w, "Bad Gateway", 502)
			}
		}}
		p.ServeHTTP(w, r.WithContext(ctx))
	})
}

// Linux /proc start time disambiguates a recycled PID. A zombie is dead.
func processIdentity(pid int) string {
	raw, err := os.ReadFile(fmt.Sprintf("/proc/%d/stat", pid))
	if err != nil {
		return ""
	}
	i := strings.LastIndexByte(string(raw), ')')
	if i < 0 {
		return ""
	}
	fields := strings.Fields(string(raw)[i+1:])
	if len(fields) < 20 || fields[0] == "Z" {
		return ""
	}
	return fields[19]
}
func main() {
	if len(os.Args) != 3 {
		log.Fatal("usage: deadline-proxy SOCKET PARENT_PID")
	}
	path := os.Args[1]
	parent, err := strconv.Atoi(os.Args[2])
	if err != nil || parent < 1 {
		log.Fatal("invalid parent")
	}
	parentIdentity := processIdentity(parent)
	if parentIdentity == "" {
		log.Fatal("parent unavailable")
	}
	dir := filepath.Dir(path)
	info, err := os.Stat(dir)
	if err != nil || !info.IsDir() || info.Mode().Perm()&0077 != 0 {
		log.Fatal("private socket directory required")
	}
	if info, err := os.Lstat(path); err == nil {
		if info.Mode()&os.ModeSocket == 0 {
			log.Fatal("refusing to replace non-socket")
		}
		if e := os.Remove(path); e != nil {
			log.Fatal(e)
		}
	} else if !os.IsNotExist(err) {
		log.Fatal(err)
	}
	l, err := net.Listen("unix", path)
	if err != nil {
		log.Fatal(err)
	}
	l.(*net.UnixListener).SetUnlinkOnClose(false)
	defer l.Close()
	if err = os.Chmod(path, 0600); err != nil {
		log.Fatal(err)
	}
	srv := http.Server{Handler: handler(make(chan struct{}, 256)), ReadHeaderTimeout: 10 * time.Second, IdleTimeout: 15 * time.Second, MaxHeaderBytes: 128 << 10, ErrorLog: log.New(io.Discard, "", 0)}
	go func() {
		ticker := time.NewTicker(time.Second)
		defer ticker.Stop()
		for range ticker.C {
			if processIdentity(parent) != parentIdentity {
				srv.Close()
				return
			}
		}
	}()
	fmt.Println("deadline proxy ready")
	if err := srv.Serve(l); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
}
