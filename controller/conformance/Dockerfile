# Build the unmodified official Gateway API test binary, pinned to v1.4.0.
FROM golang:1.26.10-bookworm AS builder
WORKDIR /src
ENV CGO_ENABLED=0
RUN go mod download -json sigs.k8s.io/gateway-api@v1.4.0 >/tmp/module.json && \
    cp -R "$(go env GOMODCACHE)/sigs.k8s.io/gateway-api@v1.4.0/." /src && \
    chmod -R u+w /src
RUN go test -p 4 -mod=readonly -c -o /gateway-conformance.test ./conformance
FROM alpine:3.24
COPY --from=builder /gateway-conformance.test /gateway-conformance.test
ENTRYPOINT ["/gateway-conformance.test"]
