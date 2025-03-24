#!/bin/bash
cd gowhatsapp
go build -buildmode=c-shared -ldflags="-s -w" -trimpath -o ./libwhatsapp.so ./whatsapp.go
cd ..