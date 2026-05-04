# syntax=docker/dockerfile:1
FROM golang:1.23-alpine AS build
WORKDIR /src
COPY main.go .
RUN go mod init qa-receiver \
 && CGO_ENABLED=0 GOOS=linux go build -o /out/qa-receiver main.go

FROM gcr.io/distroless/static:nonroot
COPY --from=build /out/qa-receiver /qa-receiver
EXPOSE 8080
USER nonroot:nonroot
ENTRYPOINT ["/qa-receiver"]
