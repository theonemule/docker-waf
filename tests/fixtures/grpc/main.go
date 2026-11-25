package main

import (
	"fmt"
	"io"
	"net/http"
	"os"
)

func main() {
	p := new(http.Protocols)
	p.SetUnencryptedHTTP2(true)
	h := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.ProtoMajor != 2 || r.Method != "POST" {
			http.Error(w, "invalid protocol", 400)
			return
		}
		io.Copy(io.Discard, r.Body)
		w.Header().Set("Content-Type", "application/grpc")
		w.Header().Set("X-Echo-Path", r.URL.Path)
		w.Header().Set("X-Echo-Route", r.Header.Get("X-Route"))
		w.Header().Set("X-Echo-Port", os.Args[1])
		w.Header().Set("Trailer", "Grpc-Status")
		w.Write([]byte{0, 0, 0, 0, 0})
		w.Header().Set("Grpc-Status", "0")
	})
	s := http.Server{Addr: ":" + os.Args[1], Handler: h, Protocols: p}
	panic(fmt.Sprint(s.ListenAndServe()))
}
