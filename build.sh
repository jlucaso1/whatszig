#!/bin/bash
cd gowhatsapp
CGO_ENABLED=1 GOOS=linux GOARCH=amd64 CC="zig cc -target x86_64-linux" CXX="zig c++ -target x86_64-linux" go build -buildmode=c-archive -ldflags="-s -w" -trimpath -o libwhatsapp.a whatsapp.go
cd ..