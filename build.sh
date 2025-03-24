#!/bin/bash
cd gowhatsapp
go build -buildmode=c-archive -ldflags="-s -w" -trimpath -o libwhatsapp.a whatsapp.go
cd ..