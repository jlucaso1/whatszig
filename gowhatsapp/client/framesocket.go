package main

import (
	"context"
	"fmt"
	"sync"
	"time"
)

type FrameSocket struct {
	ctx    context.Context
	cancel func()
	lock   sync.Mutex

	Frames       chan []byte
	Header       []byte
	OnDisconnect func(remote bool)
	WriteTimeout time.Duration

	incomingLength int
	receivedLength int
	incoming       []byte
	partialHeader  []byte
}

func NewFrameSocket() *FrameSocket {
	return &FrameSocket{
		Frames: make(chan []byte),
	}
}

func (fs *FrameSocket) Context() context.Context {
	return fs.ctx
}

func (fs *FrameSocket) SendFrame(data []byte) error {

	dataLength := len(data)
	if dataLength >= FrameMaxSize {
		return fmt.Errorf("%w (got %d bytes, max %d bytes)", ErrFrameTooLarge, len(data), FrameMaxSize)
	}

	headerLength := len(fs.Header)
	// Whole frame is header + 3 bytes for length + data
	wholeFrame := make([]byte, headerLength+FrameLengthSize+dataLength)

	// Copy the header if it's there
	if fs.Header != nil {
		copy(wholeFrame[:headerLength], fs.Header)
		// We only want to send the header once
		fs.Header = nil
	}

	// Encode length of frame
	wholeFrame[headerLength] = byte(dataLength >> 16)
	wholeFrame[headerLength+1] = byte(dataLength >> 8)
	wholeFrame[headerLength+2] = byte(dataLength)

	// Copy actual frame data
	copy(wholeFrame[headerLength+FrameLengthSize:], data)

	// if fs.WriteTimeout > 0 {
	// 	err := conn.SetWriteDeadline(time.Now().Add(fs.WriteTimeout))
	// 	if err != nil {
	// 		fs.log.Warnf("Failed to set write deadline: %v", err)
	// 	}
	// }
	// return conn.WriteMessage(websocket.BinaryMessage, wholeFrame)

	return nil
}

func (fs *FrameSocket) frameComplete() {
	data := fs.incoming
	fs.incoming = nil
	fs.partialHeader = nil
	fs.incomingLength = 0
	fs.receivedLength = 0
	fs.Frames <- data
}

func (fs *FrameSocket) processData(msg []byte) {
	for len(msg) > 0 {
		// This probably doesn't happen a lot (if at all), so the code is unoptimized
		if fs.partialHeader != nil {
			msg = append(fs.partialHeader, msg...)
			fs.partialHeader = nil
		}
		if fs.incoming == nil {
			if len(msg) >= FrameLengthSize {
				length := (int(msg[0]) << 16) + (int(msg[1]) << 8) + int(msg[2])
				fs.incomingLength = length
				fs.receivedLength = len(msg)
				msg = msg[FrameLengthSize:]
				if len(msg) >= length {
					fs.incoming = msg[:length]
					msg = msg[length:]
					fs.frameComplete()
				} else {
					fs.incoming = make([]byte, length)
					copy(fs.incoming, msg)
					msg = nil
				}
			} else {
				fs.partialHeader = msg
				msg = nil
			}
		} else {
			if fs.receivedLength+len(msg) >= fs.incomingLength {
				copy(fs.incoming[fs.receivedLength:], msg[:fs.incomingLength-fs.receivedLength])
				msg = msg[fs.incomingLength-fs.receivedLength:]
				fs.frameComplete()
			} else {
				copy(fs.incoming[fs.receivedLength:], msg)
				fs.receivedLength += len(msg)
				msg = nil
			}
		}
	}
}
