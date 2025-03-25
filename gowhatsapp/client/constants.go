package main

import (
	"errors"

	"go.mau.fi/whatsmeow/binary/token"
)

const (
	// Origin is the Origin header for all WhatsApp websocket connections
	Origin = "https://web.whatsapp.com"
	// URL is the websocket URL for the new multidevice protocol
	URL = "wss://web.whatsapp.com/ws/chat"
)

const (
	NoiseStartPattern = "Noise_XX_25519_AESGCM_SHA256\x00\x00\x00\x00"

	WAMagicValue = 6
)

var WAConnHeader = []byte{'W', 'A', WAMagicValue, token.DictVersion}

const (
	FrameMaxSize    = 2 << 23
	FrameLengthSize = 3
)

var (
	ErrFrameTooLarge     = errors.New("frame too large")
	ErrSocketClosed      = errors.New("frame socket is closed")
	ErrSocketAlreadyOpen = errors.New("frame socket is already open")
)
