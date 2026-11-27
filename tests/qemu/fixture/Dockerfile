FROM golang:1.27.3-bookworm AS build
COPY main.go /src/main.go
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /probe /src/main.go
FROM alpine:3.24
COPY --from=build /probe /probe
USER 10001:10001
ENTRYPOINT ["/probe"]
