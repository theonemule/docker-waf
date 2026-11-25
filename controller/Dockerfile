FROM golang:1.26.10-bookworm AS builder
WORKDIR /src
ENV CGO_ENABLED=0
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN go test -mod=readonly ./... && go vet -mod=readonly ./... && go build -mod=readonly -trimpath -ldflags="-s -w" -o /lightedge-controller ./cmd/lightedge-controller
FROM alpine:3.24
ARG CONTROLLER_VERSION=1.0.0
LABEL org.opencontainers.image.version=$CONTROLLER_VERSION
RUN apk add --no-cache ca-certificates
COPY --from=builder /lightedge-controller /usr/local/bin/lightedge-controller
USER 65532:65532
EXPOSE 8081
ENTRYPOINT ["/usr/local/bin/lightedge-controller"]
