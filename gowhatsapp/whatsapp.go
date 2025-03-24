package main

import "C"
import (
	"context"
	"encoding/json"
	"fmt"
	"sync"

	"go.mau.fi/whatsmeow"
	waProto "go.mau.fi/whatsmeow/binary/proto"
	"go.mau.fi/whatsmeow/store/sqlstore"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
	waLog "go.mau.fi/whatsmeow/util/log"
	"google.golang.org/protobuf/proto"

	// Add SQLite driver import - this is needed even if not directly used
	_ "modernc.org/sqlite"
)

var (
	client       *whatsmeow.Client
	eventHandler *waEventHandler
	mutex        sync.Mutex
	initialized  bool
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

	dbLog := waLog.Stdout("Database", "DEBUG", true)
	container, err := sqlstore.New("sqlite", "file:whatsmeow.db?_pragma=foreign_keys(1)", dbLog)
	if err != nil {
		return C.CString(fmt.Sprintf("Error connecting to database: %v", err))
	}

	deviceStore, err := container.GetFirstDevice()
	if err != nil {
		return C.CString(fmt.Sprintf("Error getting device: %v", err))
	}

	clientLog := waLog.Stdout("Client", "DEBUG", true)
	client = whatsmeow.NewClient(deviceStore, clientLog)
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

	err := client.Connect()
	if err != nil {
		return C.CString(fmt.Sprintf("Error connecting: %v", err))
	}

	return C.CString("Connected successfully")
}

//export IsLoggedIn
func IsLoggedIn() bool {
	if !initialized {
		return false
	}
	return client.IsLoggedIn()
}

//export GetQRCode
func GetQRCode() *C.char {
	if !initialized {
		return C.CString("Error: Must initialize first")
	}

	if client.IsLoggedIn() {
		return C.CString("Already logged in")
	}

	qrChan, _ := client.GetQRChannel(context.Background())
	qr := <-qrChan

	// Convert QR code to ASCII art for terminal display
	qrArt := fmt.Sprintf("QR Code (scan with WhatsApp):\n\n%s", qr.Code)

	return C.CString(qrArt)
}

//export SendMessage
func SendMessage(recipientC *C.char, messageC *C.char) *C.char {
	if !initialized || !client.IsLoggedIn() {
		return C.CString("Error: Not logged in")
	}

	recipient := C.GoString(recipientC)
	message := C.GoString(messageC)

	jid, err := types.ParseJID(recipient)
	if err != nil {
		return C.CString(fmt.Sprintf("Invalid JID: %v", err))
	}

	msg := &waProto.Message{
		Conversation: proto.String(message),
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
