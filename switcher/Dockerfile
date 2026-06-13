# Build the static Go binary
FROM golang:1.22-alpine AS build
WORKDIR /src
COPY go.mod ./
COPY main.go ./
RUN CGO_ENABLED=0 go build -ldflags "-s -w" -o /vpn-switcher .

# Runtime: docker CLI + compose plugin so we can recreate the gluetun container.
FROM docker:27-cli
RUN apk add --no-cache docker-cli-compose
COPY --from=build /vpn-switcher /usr/local/bin/vpn-switcher
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/vpn-switcher"]
