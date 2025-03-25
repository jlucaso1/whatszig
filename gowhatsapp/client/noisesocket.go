package main

import (
	"context"
	"crypto/cipher"
	"encoding/binary"
	"sync"
	"sync/atomic"
)

type NoiseSocket struct {
	fs           *FrameSocket
	onFrame      FrameHandler
	writeKey     cipher.AEAD
	readKey      cipher.AEAD
	writeCounter uint32
	readCounter  uint32
	writeLock    sync.Mutex
	destroyed    atomic.Bool
	stopConsumer chan struct{}
}

type DisconnectHandler func(socket *NoiseSocket, remote bool)
type FrameHandler func([]byte)

func newNoiseSocket(fs *FrameSocket, writeKey, readKey cipher.AEAD, frameHandler FrameHandler, disconnectHandler DisconnectHandler) (*NoiseSocket, error) {
	ns := &NoiseSocket{
		fs:           fs,
		writeKey:     writeKey,
		readKey:      readKey,
		onFrame:      frameHandler,
		stopConsumer: make(chan struct{}),
	}
	go ns.consumeFrames(fs.ctx, fs.Frames)
	return ns, nil
}

func (ns *NoiseSocket) consumeFrames(ctx context.Context, frames <-chan []byte) {
	if ctx == nil {
		// ctx being nil implies the connection already closed somehow
		return
	}
	ctxDone := ctx.Done()
	for {
		select {
		case frame := <-frames:
			ns.receiveEncryptedFrame(frame)
		case <-ctxDone:
			return
		case <-ns.stopConsumer:
			return
		}
	}
}

func generateIV(count uint32) []byte {
	iv := make([]byte, 12)
	binary.BigEndian.PutUint32(iv[8:], count)
	return iv
}

func (ns *NoiseSocket) Context() context.Context {
	return ns.fs.Context()
}

func (ns *NoiseSocket) SendFrame(plaintext []byte) error {
	ns.writeLock.Lock()
	ciphertext := ns.writeKey.Seal(nil, generateIV(ns.writeCounter), plaintext, nil)
	ns.writeCounter++
	_, err := ns.fs.SendFrame(ciphertext)
	ns.writeLock.Unlock()
	return err
}

func (ns *NoiseSocket) receiveEncryptedFrame(ciphertext []byte) {
	count := atomic.AddUint32(&ns.readCounter, 1) - 1
	plaintext, err := ns.readKey.Open(nil, generateIV(count), ciphertext, nil)
	if err != nil {
		return
	}
	ns.onFrame(plaintext)
}
