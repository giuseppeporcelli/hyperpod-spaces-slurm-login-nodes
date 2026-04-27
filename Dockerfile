FROM golang:1.25 AS builder
WORKDIR /app
ENV GOPROXY=direct
COPY go.mod go.sum ./
RUN go mod download
COPY main.go .
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o hyperpod-spaces-user-webhook .

FROM gcr.io/distroless/static:nonroot
COPY --from=builder /app/hyperpod-spaces-user-webhook /hyperpod-spaces-user-webhook
ENTRYPOINT ["/hyperpod-spaces-user-webhook"]
