// Multi-protocol test fixture, not a production server. Unary gRPC uses
// standard protobuf StringValue wire encoding and the five-byte envelope.
package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"strings"
	"time"
)

type result struct {
	Message  string `json:"message"`
	Pod      string `json:"pod"`
	Node     string `json:"node"`
	Protocol string `json:"protocol"`
	Nonce    string `json:"nonce,omitempty"`
	Metadata string `json:"metadata,omitempty"`
}

func response(proto, nonce, metadata string) []byte {
	b, err := json.Marshal(result{"Hello World", os.Getenv("POD_NAME"), os.Getenv("NODE_NAME"), proto, nonce, metadata})
	if err != nil {
		panic(err)
	}
	return b
}
func frame(b []byte) []byte {
	// Protobuf StringValue: field 1 (length-delimited).
	p := binary.AppendUvarint([]byte{10}, uint64(len(b)))
	p = append(p, b...)
	h := make([]byte, 5)
	binary.BigEndian.PutUint32(h[1:], uint32(len(p)))
	return append(h, p...)
}
func unframe(b []byte) ([]byte, error) {
	if len(b) < 7 || b[0] != 0 || int(binary.BigEndian.Uint32(b[1:5])) != len(b)-5 || b[5] != 10 {
		return nil, fmt.Errorf("invalid gRPC frame")
	}
	n, k := binary.Uvarint(b[6:])
	if k <= 0 || uint64(len(b)-6-k) != n {
		return nil, fmt.Errorf("invalid protobuf string")
	}
	return b[6+k:], nil
}
func handler(proto string) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Write(response(proto, r.URL.Query().Get("nonce"), r.Header.Get("X-Route")))
	})
}
func grpc(w http.ResponseWriter, r *http.Request) {
	if r.ProtoMajor != 2 || r.Method != "POST" || r.URL.Path != "/example.Echo/Call" || !strings.HasPrefix(r.Header.Get("Content-Type"), "application/grpc") {
		http.Error(w, "bad RPC", 400)
		return
	}
	b, e := io.ReadAll(io.LimitReader(r.Body, 4096))
	if e != nil {
		http.Error(w, "bad body", 400)
		return
	}
	nonce, e := unframe(b)
	if e != nil {
		http.Error(w, "bad protobuf", 400)
		return
	}
	w.Header().Set("Content-Type", "application/grpc")
	w.Header().Set("Trailer", "Grpc-Status")
	w.Write(frame(response("grpc", string(nonce), r.Header.Get("X-Route"))))
	w.Header().Set("Grpc-Status", "0")
}
func tcp(l net.Listener, proto string) {
	for {
		c, e := l.Accept()
		if e != nil {
			log.Fatal(e)
		}
		go func() {
			defer c.Close()
			c.SetDeadline(time.Now().Add(20 * time.Second))
			line, e := bufio.NewReader(io.LimitReader(c, 4096)).ReadString('\n')
			if e == nil {
				c.Write(append(response(proto, strings.TrimSuffix(line, "\n"), ""), '\n'))
			}
		}()
	}
}
func serve() {
	cert, e := tls.LoadX509KeyPair("/cert/tls.crt", "/cert/tls.key")
	if e != nil {
		log.Fatal(e)
	}
	l, e := net.Listen("tcp", ":12001")
	if e != nil {
		log.Fatal(e)
	}
	go tcp(l, "tcp")
	tl, e := tls.Listen("tcp", ":12003", &tls.Config{Certificates: []tls.Certificate{cert}, MinVersion: tls.VersionTLS12})
	if e != nil {
		log.Fatal(e)
	}
	go tcp(tl, "tls")
	u, e := net.ListenPacket("udp", ":12002")
	if e != nil {
		log.Fatal(e)
	}
	go func() {
		b := make([]byte, 4096)
		for {
			n, a, e := u.ReadFrom(b)
			if e != nil {
				log.Fatal(e)
			}
			u.WriteTo(response("udp", string(b[:n]), ""), a)
		}
	}()
	go func() { log.Fatal(http.ListenAndServe(":8080", handler("http"))) }()
	go func() { log.Fatal(http.ListenAndServeTLS(":8443", "/cert/tls.crt", "/cert/tls.key", handler("https"))) }()
	p := new(http.Protocols)
	p.SetUnencryptedHTTP2(true)
	log.Fatal((&http.Server{Addr: ":12005", Protocols: p, Handler: http.HandlerFunc(grpc)}).ListenAndServe())
}

func probe(args []string) error {
	f := flag.NewFlagSet("probe", flag.ContinueOnError)
	proto := f.String("protocol", "http", "http https grpc grpcs tcp udp tls")
	addr := f.String("addr", "", "destination socket")
	host := f.String("host", "", "HTTP Host / TLS SNI")
	ca := f.String("ca", "", "trusted CA file")
	fingerprint := f.String("fingerprint", "", "expected peer certificate SHA256 (hex)")
	count := f.Int("count", 1, "fresh connections")
	deadline := f.Duration("deadline", 15*time.Second, "per-request absolute deadline")
	expected := f.String("backend", "", "expected backend protocol")
	metadata := f.String("metadata", "", "expected request metadata")
	if e := f.Parse(args); e != nil {
		return e
	}
	if *addr == "" || *count < 1 || *deadline <= 0 || *deadline > time.Minute {
		return fmt.Errorf("bad arguments")
	}
	tc := &tls.Config{ServerName: *host, MinVersion: tls.VersionTLS12}
	if *ca != "" {
		b, e := os.ReadFile(*ca)
		if e != nil {
			return e
		}
		tc.RootCAs = x509.NewCertPool()
		if !tc.RootCAs.AppendCertsFromPEM(b) {
			return fmt.Errorf("bad CA")
		}
	}
	if *fingerprint != "" {
		tc.VerifyConnection = func(s tls.ConnectionState) error {
			h := sha256.Sum256(s.PeerCertificates[0].Raw)
			if hex.EncodeToString(h[:]) != *fingerprint {
				return fmt.Errorf("wrong leaf fingerprint")
			}
			return nil
		}
	}
	for i := 0; i < *count; i++ {
		started := time.Now()
		nonce := fmt.Sprintf("%d-%d", started.UnixNano(), i)
		var b []byte
		var e error
		switch *proto {
		case "tcp", "udp", "tls":
			d := net.Dialer{Deadline: started.Add(*deadline)}
			var c net.Conn
			if *proto == "tls" {
				c, e = tls.DialWithDialer(&d, "tcp", *addr, tc)
			} else {
				c, e = d.Dial(*proto, *addr)
			}
			if e != nil {
				return fmt.Errorf("%s request %d dial/handshake %s elapsed %s: %w", *proto, i+1, *addr, time.Since(started), e)
			}
			c.SetDeadline(started.Add(*deadline))
			msg := nonce
			if *proto != "udp" {
				msg += "\n"
			}
			_, e = c.Write([]byte(msg))
			if e == nil {
				if *proto == "udp" {
					buf := make([]byte, 4096)
					var n int
					n, e = c.Read(buf)
					b = buf[:n]
				} else {
					b, e = bufio.NewReader(io.LimitReader(c, 4096)).ReadBytes('\n')
				}
			}
			c.Close()
		case "http", "https", "grpc", "grpcs":
			p := new(http.Protocols)
			scheme := "http"
			method := "GET"
			path := "/?nonce=" + nonce
			var body io.Reader
			if *proto == "https" || *proto == "grpcs" {
				scheme = "https"
			}
			if *proto == "grpc" {
				p.SetUnencryptedHTTP2(true)
			} else if *proto == "grpcs" {
				p.SetHTTP2(true)
			} else {
				p.SetHTTP1(true)
			}
			if *proto == "grpc" || *proto == "grpcs" {
				method = "POST"
				path = "/example.Echo/Call"
				body = bytes.NewReader(frame([]byte(nonce)))
			}
			tr := &http.Transport{TLSClientConfig: tc, Protocols: p, DisableKeepAlives: true, DialContext: (&net.Dialer{Deadline: started.Add(*deadline)}).DialContext}
			ctx, cancel := context.WithDeadline(context.Background(), started.Add(*deadline))
			req, err := http.NewRequestWithContext(ctx, method, scheme+"://"+*addr+path, body)
			if err != nil {
				cancel()
				return err
			}
			req.Host = *host
			if method == "POST" {
				req.Header.Set("Content-Type", "application/grpc")
				req.Header.Set("TE", "trailers")
			}
			resp, err := tr.RoundTrip(req)
			if err != nil {
				cancel()
				return fmt.Errorf("%s request %d HTTP exchange %s elapsed %s: %w", *proto, i+1, *addr, time.Since(started), err)
			}
			b, e = io.ReadAll(io.LimitReader(resp.Body, 16384))
			resp.Body.Close()
			cancel()
			tr.CloseIdleConnections()
			if e == nil && resp.StatusCode != 200 {
				e = fmt.Errorf("HTTP status %d: %s", resp.StatusCode, string(b))
			}
			if e == nil && method == "POST" {
				if resp.ProtoMajor != 2 || resp.Trailer.Get("Grpc-Status") != "0" {
					e = fmt.Errorf("gRPC status %q protocol %s", resp.Trailer.Get("Grpc-Status"), resp.Proto)
				} else {
					b, e = unframe(b)
				}
			}
		default:
			return fmt.Errorf("unknown protocol %s", *proto)
		}
		if e != nil {
			return fmt.Errorf("%s request %d response %s elapsed %s: %w", *proto, i+1, *addr, time.Since(started), e)
		}
		var res result
		if e = json.Unmarshal(b, &res); e != nil {
			return fmt.Errorf("invalid result: %w", e)
		}
		if res.Message != "Hello World" || res.Pod == "" || res.Node == "" || res.Nonce != nonce || (*expected != "" && res.Protocol != *expected) || (*metadata != "" && res.Metadata != *metadata) {
			return fmt.Errorf("unexpected response: %s", b)
		}
		out := struct {
			result
			LatencyMS float64 `json:"latency_ms"`
		}{res, float64(time.Since(started).Microseconds()) / 1000}
		encoded, err := json.Marshal(out)
		if err != nil {
			return err
		}
		fmt.Println(string(encoded))
	}
	return nil
}
func main() {
	if len(os.Args) == 1 {
		serve()
		return
	}
	if os.Args[1] != "probe" {
		log.Fatal("usage: probe probe [flags]")
	}
	if err := probe(os.Args[2:]); err != nil {
		log.Fatal(err)
	}
}
