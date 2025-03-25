// this file is a go wrapper for the C library. Will export the functions that start the data for initial connection (handshake) and return as a string	to use in the external code.

package main

import "C"

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"sync"
	"time"
	"unsafe"

	"go.mau.fi/whatsmeow/proto/waWa6"
	"google.golang.org/protobuf/proto"
)

var (
	fs          *FrameSocket
	ns          *NoiseSocket
	nh          *NoiseHandshake
	keyPair     *KeyPair
	mutex       sync.Mutex
	initialized bool
	connected   bool
)

// processFrameData handles processing data through the FrameSocket and returns any frames
func processFrameData(data []byte) ([]byte, error) {
	if fs == nil {
		return nil, fmt.Errorf("FrameSocket not initialized")
	}

	// Create a buffered channel to capture frames
	framesChan := make(chan []byte, 10)

	// Save and replace the fs.Frames channel temporarily
	originalFrames := fs.Frames
	fs.Frames = framesChan

	// Process the data and capture any potential panic
	func() {
		defer func() {
			if r := recover(); r != nil {
				fmt.Printf("Recovered from panic in processData: %v\n", r)
			}
		}()
		fs.processData(data)
	}()

	// Restore the original channel
	fs.Frames = originalFrames

	// Try to get a frame from the channel
	var resp []byte
	select {
	case resp = <-framesChan:
		return resp, nil
	case <-time.After(2 * time.Second):
		// If no frames received, try to parse directly
		return processFrameData(data)
	}
}

//export Initialize
func Initialize() *C.char {
	mutex.Lock()
	defer mutex.Unlock()

	if initialized {
		return C.CString("Already initialized")
	}

	fs = NewFrameSocket()
	fs.Header = WAConnHeader
	nh = NewNoiseHandshake()
	keyPair = NewKeyPair()

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

	// Ensure fs is initialized before using it
	if fs == nil {
		fs = NewFrameSocket()
		fs.Header = WAConnHeader
	}

	// Create new handshake instance
	nh.Start(NoiseStartPattern, WAConnHeader)
	nh.Authenticate(keyPair.Pub[:])

	// Create client hello message
	data, err := proto.Marshal(&waWa6.HandshakeMessage{
		ClientHello: &waWa6.HandshakeMessage_ClientHello{
			Ephemeral: keyPair.Pub[:],
		},
	})
	if err != nil {
		return C.CString("Error: failed to marshal handshake message")
	}

	data, err = fs.SendFrame(data)
	if err != nil {
		return C.CString(fmt.Sprintf("Error: failed to send handshake message: %v", err))
	}

	// Create JSON with handshake data
	handshakeData := map[string]string{
		"publicKey": base64.StdEncoding.EncodeToString(keyPair.Pub[:]),
		"header":    base64.StdEncoding.EncodeToString(data),
	}

	jsonData, err := json.Marshal(handshakeData)
	if err != nil {
		return C.CString(fmt.Sprintf("Error creating handshake data: %v", err))
	}

	return C.CString(string(jsonData))
}

//export SendHandshakeResponse
func SendHandshakeResponse(response *C.char, responseLen C.int) *C.char {
	mutex.Lock()
	defer mutex.Unlock()

	if !initialized {
		return C.CString("Error: Must initialize first")
	}

	if fs == nil {
		return C.CString("Error: FrameSocket not initialized")
	}

	// Convert C string to Go byte slice using the provided length
	responseBytes := C.GoBytes(unsafe.Pointer(response), responseLen)
	fmt.Printf("Received %d bytes from Zig\n", len(responseBytes))

	// Process the response data
	resp, err := processFrameData(responseBytes)
	if err != nil || len(resp) == 0 {
		return C.CString("Error: No valid response data received")
	}

	fmt.Printf("Processing frame of %d bytes\n", len(resp))

	// Unmarshal the response
	var handshakeResponse waWa6.HandshakeMessage
	err = proto.Unmarshal(resp, &handshakeResponse)
	if err != nil {
		// Try to find the starting point for a valid protobuf
		for i := 1; i < len(resp) && i < 20; i++ {
			if err = proto.Unmarshal(resp[i:], &handshakeResponse); err == nil {
				fmt.Printf("Successfully unmarshaled by skipping %d bytes\n", i)
				break
			}
		}

		if err != nil {
			return C.CString(fmt.Sprintf("Error: failed to unmarshal handshake response: %v", err))
		}
	}

	// Validate ServerHello
	if handshakeResponse.GetServerHello() == nil {
		return C.CString("Error: missing ServerHello in handshake response")
	}

	serverEphemeral := handshakeResponse.GetServerHello().GetEphemeral()
	serverStaticCiphertext := handshakeResponse.GetServerHello().GetStatic()
	certificateCiphertext := handshakeResponse.GetServerHello().GetPayload()

	if len(serverEphemeral) != 32 || serverStaticCiphertext == nil || certificateCiphertext == nil {
		return C.CString("Error: missing parts of handshake response")
	}

	// Process handshake steps
	serverEphemeralArr := *(*[32]byte)(serverEphemeral)
	nh.Authenticate(serverEphemeral)

	// Mix shared secret
	if err = nh.MixSharedSecretIntoKey(*keyPair.Priv, serverEphemeralArr); err != nil {
		return C.CString(fmt.Sprintf("Error: failed to mix server ephemeral key: %v", err))
	}

	// Decrypt server static
	staticDecrypted, err := nh.Decrypt(serverStaticCiphertext)
	if err != nil {
		return C.CString(fmt.Sprintf("Error: failed to decrypt server static: %v", err))
	}
	if len(staticDecrypted) != 32 {
		return C.CString(fmt.Sprintf("Error: unexpected server static length: %d", len(staticDecrypted)))
	}

	// Mix more shared secrets
	if err = nh.MixSharedSecretIntoKey(*keyPair.Priv, *(*[32]byte)(staticDecrypted)); err != nil {
		return C.CString(fmt.Sprintf("Error: failed to mix server static key: %v", err))
	}

	// Verify certificate
	certDecrypted, err := nh.Decrypt(certificateCiphertext)
	if err != nil {
		return C.CString(fmt.Sprintf("Error: failed to decrypt certificate: %v", err))
	}
	if err = verifyServerCert(certDecrypted, staticDecrypted); err != nil {
		return C.CString(fmt.Sprintf("Error: certificate verification failed: %v", err))
	}

	// Prepare client finish
	encryptedPubkey := nh.Encrypt(keyPair.Pub[:])
	if err = nh.MixSharedSecretIntoKey(*keyPair.Priv, serverEphemeralArr); err != nil {
		return C.CString(fmt.Sprintf("Error: failed to mix private key: %v", err))
	}

	// Generate registration data
	registrationId := generateRegistrationId()
	preKey := NewKeyPair().CreateSignedPreKey(registrationId)
	clientPayload := getRegistrationPayload(registrationId, *preKey, *keyPair)

	// Marshal and encrypt client finish payload
	clientFinishPayloadBytes, err := proto.Marshal(clientPayload)
	if err != nil {
		return C.CString(fmt.Sprintf("Error: failed to marshal client payload: %v", err))
	}

	encryptedClientFinishPayload := nh.Encrypt(clientFinishPayloadBytes)
	fmt.Printf("Client finish payload enc length: %d\n", len(encryptedClientFinishPayload))

	// Create finish message
	data, err := proto.Marshal(&waWa6.HandshakeMessage{
		ClientFinish: &waWa6.HandshakeMessage_ClientFinish{
			Static:  encryptedPubkey,
			Payload: encryptedClientFinishPayload,
		},
	})
	if err != nil {
		return C.CString(fmt.Sprintf("Error: failed to marshal finish message: %v", err))
	}

	// Send final handshake message
	data, err = fs.SendFrame(data)
	if err != nil {
		return C.CString(fmt.Sprintf("Error: failed to send finish message: %v", err))
	}

	fmt.Printf("Sending %d bytes to Zig\n", len(data))
	return C.CString(base64.StdEncoding.EncodeToString(data))
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

	jsonData, err := json.Marshal(info)
	if err != nil {
		return C.CString(fmt.Sprintf("Error creating client info: %v", err))
	}

	return C.CString(string(jsonData))
}

//export processData
func processData(data unsafe.Pointer, length C.int) *C.char {
	goData := C.GoBytes(data, length)

	resp, err := processFrameData(goData)
	if err != nil || len(resp) == 0 {
		return C.CString("Error: No valid response data received")
	}

	return C.CString(base64.StdEncoding.EncodeToString(resp))
}

func main() {
	// Required for building a shared library
}

func randomBytes(n int) []byte {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return b
}

func generateRegistrationId() uint32 {
	return uint32(uint16(randomBytes(2)[0])) & 16383
}
