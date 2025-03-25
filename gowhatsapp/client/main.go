// this file is a go wrapper for the C library. Will export the functions that start the data for initial connection (handshake) and return as a string	to use in the external code.

package main

import "C"
import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"sync"
)

var (
	client      *Client
	fs          *FrameSocket
	ns          *NoiseSocket
	mutex       sync.Mutex
	initialized bool
	connected   bool
)

//export Initialize
func Initialize() *C.char {
	mutex.Lock()
	defer mutex.Unlock()

	if initialized {
		return C.CString("Already initialized")
	}

	client = NewClient()
	initialized = true
	return C.CString("Initialized successfully")
}

//export Connect
func Connect() *C.char {
	mutex.Lock()
	defer mutex.Unlock()

	if !initialized {
		return C.CString("Must initialize first")
	}

	if connected {
		return C.CString("Already connected")
	}

	fs = NewFrameSocket()
	fs.Header = WAConnHeader

	err := client.Connect()
	if err != nil {
		return C.CString(fmt.Sprintf("Error connecting: %v", err))
	}

	connected = true
	return C.CString("Connected successfully")
}

//export IsConnected
func IsConnected() bool {
	mutex.Lock()
	defer mutex.Unlock()
	return initialized && connected
}

//export GetHandshakeData
func GetHandshakeData() *C.char {
	mutex.Lock()
	defer mutex.Unlock()

	if !initialized {
		return C.CString("Error: Must initialize first")
	}

	// Create key pair for handshake
	keyPair := NewKeyPair()

	// Create new handshake instance
	nh := NewNoiseHandshake()
	nh.Start(NoiseStartPattern, WAConnHeader)
	nh.Authenticate(keyPair.Pub[:])

	// Convert public key to base64 for export
	pubKeyBase64 := base64.StdEncoding.EncodeToString(keyPair.Pub[:])

	// Create JSON with handshake data
	handshakeData := map[string]string{
		"publicKey": pubKeyBase64,
		"header":    base64.StdEncoding.EncodeToString(WAConnHeader),
	}

	jsonData, err := json.Marshal(handshakeData)
	if err != nil {
		return C.CString(fmt.Sprintf("Error creating handshake data: %v", err))
	}

	return C.CString(string(jsonData))
}

//export Disconnect
func Disconnect() *C.char {
	mutex.Lock()
	defer mutex.Unlock()

	if !initialized {
		return C.CString("Not initialized")
	}

	if !connected {
		return C.CString("Not connected")
	}

	// Reset connection state
	fs = nil
	ns = nil
	connected = false

	return C.CString("Disconnected")
}

//export GetClientInfo
func GetClientInfo() *C.char {
	mutex.Lock()
	defer mutex.Unlock()

	if !initialized {
		return C.CString("Not initialized")
	}

	info := map[string]interface{}{
		"initialized": initialized,
		"connected":   connected,
	}

	if client != nil && client.Store != nil && client.Store.ID != nil {
		info["jid"] = client.Store.ID.String()
	}

	jsonData, err := json.Marshal(info)
	if err != nil {
		return C.CString(fmt.Sprintf("Error creating client info: %v", err))
	}

	return C.CString(string(jsonData))
}

func main() {
	// Required for building a shared library
}
