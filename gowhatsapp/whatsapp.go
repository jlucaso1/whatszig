package main

import "C"
import (
	"context"
	"encoding/json"
	"fmt"
	"sync"

	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/store/sqlstore"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
	"google.golang.org/protobuf/proto"

	// Add SQLite driver import - this is needed even if not directly used
	_ "modernc.org/sqlite"
)

var (
	client       *whatsmeow.Client
	eventHandler *waEventHandler
	mutex        sync.Mutex
	initialized  bool

	// QR code related variables
	qrChannel <-chan whatsmeow.QRChannelItem
	currentQR string
	qrStatus  string
)

type waEventHandler struct {
	messageCallback func(string)
}

func (h *waEventHandler) HandleEvent(evt interface{}) {
	switch v := evt.(type) {
	case *events.Message:
		if h.messageCallback != nil {
			sender := v.Info.Sender.String()
			content, _ := json.Marshal(v.Message)
			message := fmt.Sprintf("Message from %s: %s", sender, content)
			h.messageCallback(message)
		}
	}
}

//export Initialize
func Initialize() *C.char {
	mutex.Lock()
	defer mutex.Unlock()

	if initialized {
		return C.CString("Already initialized")
	}

	container, err := sqlstore.New("sqlite", "file:whatsmeow.db?_pragma=foreign_keys(1)", nil)
	if err != nil {
		return C.CString(fmt.Sprintf("Error connecting to database: %v", err))
	}

	deviceStore, err := container.GetFirstDevice()
	if err != nil {
		return C.CString(fmt.Sprintf("Error getting device: %v", err))
	}

	client = whatsmeow.NewClient(deviceStore, nil)
	eventHandler = &waEventHandler{}
	client.AddEventHandler(eventHandler.HandleEvent)

	initialized = true
	return C.CString("Initialized successfully")
}

//export Connect
func Connect() *C.char {
	if !initialized {
		return C.CString("Must initialize first")
	}

	if client.IsConnected() {
		return C.CString("Already connected")
	}

	// First, check if we have a session in the store
	deviceStore := client.Store
	if deviceStore.ID != nil {
		// We have a device ID, so we've logged in before

		// Just connect - no need for QR code since we already have credentials
		err := client.Connect()
		if err != nil {
			return C.CString(fmt.Sprintf("Error connecting with existing session: %v", err))
		}

		// Verify connection
		if client.IsConnected() {
			return C.CString("Connected successfully with existing session")
		} else {
			return C.CString("Connected but session verification failed")
		}
	}

	// If we don't have credentials yet, tell client to get QR code
	return C.CString("Not logged in. Call GetQRCode first to start login process.")
}

//export IsLoggedIn
func IsLoggedIn() bool {
	if !initialized {
		return false
	}

	// Check both if we have credentials and if we're properly connected
	deviceStore := client.Store
	hasCredentials := deviceStore != nil && deviceStore.ID != nil

	// Only consider us logged in if we're also connected
	return hasCredentials && client.IsConnected()
}

//export GetQRCode
func GetQRCode() *C.char {
	if !initialized {
		return C.CString("Error: Must initialize first")
	}

	// Check if we already have credentials
	deviceStore := client.Store
	if deviceStore.ID != nil {
		// We have a device ID, so we've logged in before
		// We should not try to get a QR code in this case
		return C.CString("Error: Already have credentials. Call Connect() instead of GetQRCode().")
	}

	if client.IsLoggedIn() {
		return C.CString("Already logged in")
	}

	// Reset QR status
	mutex.Lock()
	currentQR = ""
	qrStatus = "pending"
	mutex.Unlock()

	// Get a new QR channel (must be done BEFORE connecting)
	var err error
	qrChannel, err = client.GetQRChannel(context.Background())
	if err != nil {
		return C.CString(fmt.Sprintf("Error getting QR channel: %v", err))
	}

	// Now we can connect
	err = client.Connect()
	if err != nil {
		return C.CString(fmt.Sprintf("Error connecting: %v", err))
	}

	// Start a goroutine to handle QR codes
	go func() {
		for qr := range qrChannel {
			mutex.Lock()
			switch qr.Event {
			case "code":
				currentQR = qr.Code
				qrStatus = "ready"
			case "success":
				qrStatus = "success"
			case "timeout":
				qrStatus = "timeout"
			case "error":
				qrStatus = fmt.Sprintf("error: %v", qr.Error)
			default:
				qrStatus = qr.Event
			}
			mutex.Unlock()
		}
	}()

	return C.CString("QR code generation started. Call GetQRStatus() to get the code.")
}

//export GetQRStatus
func GetQRStatus() *C.char {
	mutex.Lock()
	defer mutex.Unlock()

	if qrStatus == "ready" && currentQR != "" {
		return C.CString(fmt.Sprintf("QR Code (scan with WhatsApp):\n\n%s", currentQR))
	} else {
		return C.CString(fmt.Sprintf("QR Status: %s", qrStatus))
	}
}

//export SendMessage
func SendMessage(recipientC *C.char, messageC *C.char) *C.char {
	if !initialized || !client.IsLoggedIn() {
		return C.CString("Error: Not logged in")
	}

	recipient := C.GoString(recipientC)
	message := C.GoString(messageC)

	// Validate that we have actual content
	if len(message) == 0 {
		return C.CString("Error: Empty message")
	}

	jid, err := types.ParseJID(recipient)

	if err != nil {
		return C.CString(fmt.Sprintf("Invalid JID: %v", err))
	}

	// Create a properly isolated message string
	messageStr := string([]byte(message))

	msg := &waE2E.Message{
		Conversation: proto.String(messageStr),
	}

	_, err = client.SendMessage(context.Background(), jid, msg)
	if err != nil {
		return C.CString(fmt.Sprintf("Error sending message: %v", err))
	}

	return C.CString("Message sent successfully")
}

//export Disconnect
func Disconnect() *C.char {
	if !initialized {
		return C.CString("Not initialized")
	}

	client.Disconnect()
	return C.CString("Disconnected")
}

func main() {
	// Required for building a shared library
}
