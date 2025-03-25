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

	data, err := proto.Marshal(&waWa6.HandshakeMessage{
		ClientHello: &waWa6.HandshakeMessage_ClientHello{
			Ephemeral: keyPair.Pub[:],
		},
	})

	if err != nil {
		return C.CString("Error: failed to marshal handshake message")
	}

	// Add nil check before calling SendFrame
	if fs == nil {
		return C.CString("Error: FrameSocket not initialized")
	}

	data, err = fs.SendFrame(data)

	if err != nil {
		return C.CString(fmt.Sprintf("Error: failed to send handshake message: %v", err))
	}

	// Convert public key to base64 for export
	pubKeyBase64 := base64.StdEncoding.EncodeToString(keyPair.Pub[:])

	// Create JSON with handshake data
	handshakeData := map[string]string{
		"publicKey": pubKeyBase64,
		"header":    base64.StdEncoding.EncodeToString(data),
	}

	jsonData, err := json.Marshal(handshakeData)
	if err != nil {
		return C.CString(fmt.Sprintf("Error creating handshake data: %v", err))
	}

	return C.CString(string(jsonData))
}

// always receive a responseLen of 350 and return a base64 encoded string with the response of 328 bytes

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

	// Create a buffered channel in case processData sends multiple frames
	framesChan := make(chan []byte, 10)

	// Replace the fs.Frames channel temporarily
	originalFrames := fs.Frames
	fs.Frames = framesChan

	// Process the data and capture any potential panic
	func() {
		defer func() {
			if r := recover(); r != nil {
				fmt.Printf("Recovered from panic in processData: %v\n", r)
			}
		}()
		fs.processData(responseBytes)
	}()

	// Restore the original channel
	fs.Frames = originalFrames

	var resp []byte
	select {
	case resp = <-framesChan:
		fmt.Printf("Successfully received frame of length: %d bytes\n", len(resp))
	case <-time.After(2 * time.Second): // Much shorter timeout for debugging
		fmt.Printf("No frames received from processData, attempting direct parsing\n")

		// Try to parse the response directly if framing fails
		// For WebSocket frames, skip the header bytes
		if len(responseBytes) > 0 {
			// Handle WebSocket frames directly - try to extract protobuf data
			skipBytes := 0
			if responseBytes[0] == 0x81 || responseBytes[0] == 0x82 {
				if len(responseBytes) > 2 {
					payloadLen := int(responseBytes[1] & 0x7F)
					if payloadLen <= 125 {
						skipBytes = 2 // Simple frame header
					} else if payloadLen == 126 && len(responseBytes) >= 4 {
						skipBytes = 4 // Extended 16-bit length
					} else if payloadLen == 127 && len(responseBytes) >= 10 {
						skipBytes = 10 // Extended 64-bit length
					}

					// If there's a mask, add 4 more bytes to skip
					if responseBytes[1]&0x80 != 0 {
						skipBytes += 4
					}
				}
				fmt.Printf("Detected WebSocket frame, skipping %d header bytes\n", skipBytes)
			}

			// Skip WebSocket frame header if detected
			if skipBytes > 0 && len(responseBytes) > skipBytes {
				resp = responseBytes[skipBytes:]
			} else {
				resp = responseBytes
			}
		}
	}

	if len(resp) == 0 {
		return C.CString("Error: No valid response data received")
	}

	fmt.Printf("Processing frame of %d bytes\n", len(resp))

	// Unmarshal the response
	var handshakeResponse waWa6.HandshakeMessage
	err := proto.Unmarshal(resp, &handshakeResponse)
	if err != nil {
		// If standard unmarshal fails, try some recovery approaches
		fmt.Printf("Unmarshal error: %v\n", err)

		// Check for leading bytes that might be a header but not part of the protobuf
		for i := 0; i < len(resp) && i < 20; i++ {
			if i > 0 {
				err = proto.Unmarshal(resp[i:], &handshakeResponse)
				if err == nil {
					fmt.Printf("Successfully unmarshaled by skipping %d bytes\n", i)
					break
				}
			}
		}

		if err != nil {
			return C.CString(fmt.Sprintf("Error: failed to unmarshal handshake response: %v", err))
		}
	}

	// Now proceed with the ServerHello processing
	if handshakeResponse.GetServerHello() == nil {
		return C.CString("Error: missing ServerHello in handshake response")
	}

	serverEphemeral := handshakeResponse.GetServerHello().GetEphemeral()
	serverStaticCiphertext := handshakeResponse.GetServerHello().GetStatic()
	certificateCiphertext := handshakeResponse.GetServerHello().GetPayload()

	if len(serverEphemeral) != 32 || serverStaticCiphertext == nil || certificateCiphertext == nil {
		return C.CString("Error: missing parts of handshake response")
	}

	serverEphemeralArr := *(*[32]byte)(serverEphemeral)

	nh.Authenticate(serverEphemeral)

	err = nh.MixSharedSecretIntoKey(*keyPair.Priv, serverEphemeralArr)

	if err != nil {
		return C.CString(fmt.Sprintf("Error: failed to mix server ephemeral key in: %v", err))
	}

	staticDecrypted, err := nh.Decrypt(serverStaticCiphertext)

	if err != nil {
		return C.CString(fmt.Sprintf("Error: failed to decrypt server static ciphertext: %v", err))
	} else if len(staticDecrypted) != 32 {
		return C.CString(fmt.Sprintf("Error: unexpected length of server static plaintext %d (expected 32)", len(staticDecrypted)))
	}

	err = nh.MixSharedSecretIntoKey(*keyPair.Priv, *(*[32]byte)(staticDecrypted))

	if err != nil {
		return C.CString(fmt.Sprintf("Error: failed to mix server static key in: %v", err))
	}

	certDecrypted, err := nh.Decrypt(certificateCiphertext)
	if err != nil {
		return C.CString(fmt.Sprintf("Error: failed to decrypt noise certificate ciphertext: %v", err))
	} else if err = verifyServerCert(certDecrypted, staticDecrypted); err != nil {
		return C.CString(fmt.Sprintf("Error: failed to verify server cert: %v", err))
	}

	encryptedPubkey := nh.Encrypt(keyPair.Pub[:])
	err = nh.MixSharedSecretIntoKey(*keyPair.Priv, serverEphemeralArr)
	if err != nil {
		return C.CString(fmt.Sprintf("Error: failed to mix noise private key in: %v", err))
	}
	registrationId := generateRegistrationId()
	preKey := NewKeyPair().CreateSignedPreKey(registrationId)

	var clientPayload = getRegistrationPayload(registrationId, *preKey, *keyPair)

	clientFinishPayloadBytes, err := proto.Marshal(clientPayload)
	// print the length of the client finish payload
	if err != nil {
		return C.CString(fmt.Sprintf("Error: failed to marshal client finish payload: %v", err))
	}
	encryptedClientFinishPayload := nh.Encrypt(clientFinishPayloadBytes)
	fmt.Printf("Client finish payload enc length: %d\n", len(encryptedClientFinishPayload))
	data, err := proto.Marshal(&waWa6.HandshakeMessage{
		ClientFinish: &waWa6.HandshakeMessage_ClientFinish{
			Static:  encryptedPubkey,
			Payload: encryptedClientFinishPayload,
		},
	})
	if err != nil {
		return C.CString(fmt.Sprintf("Error: failed to marshal handshake finish message: %v", err))
	}
	data, err = fs.SendFrame(data)
	if err != nil {
		return C.CString(fmt.Sprintf("Error: failed to send handshake finish message: %v", err))
	}

	// print the length of the data
	fmt.Printf("Sending %d bytes to Zig\n", len(data))

	// return res as a base64 encoded string
	resBase64 := base64.StdEncoding.EncodeToString(data)
	return C.CString(resBase64)
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

	jsonData, err := json.Marshal(info)
	if err != nil {
		return C.CString(fmt.Sprintf("Error creating client info: %v", err))
	}

	return C.CString(string(jsonData))
}

func main() {
	// Required for building a shared library
}

// export const generateRegistrationId = (): number => {
// 	return Uint16Array.from(randomBytes(2))[0] & 16383
// }

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
