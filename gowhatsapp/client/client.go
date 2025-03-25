package main

import (
	"context"
	"encoding/hex"
	"fmt"
	"runtime/debug"
	"sync"
	"sync/atomic"
	"time"

	"go.mau.fi/util/random"

	waBinary "go.mau.fi/whatsmeow/binary"
	"go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/proto/waWa6"
	"go.mau.fi/whatsmeow/proto/waWeb"
	"go.mau.fi/whatsmeow/store"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
	waLog "go.mau.fi/whatsmeow/util/log"
)

// EventHandler is a function that can handle events from WhatsApp.
type EventHandler func(evt any)
type nodeHandler func(node *waBinary.Node)

var nextHandlerID uint32

type wrappedEventHandler struct {
	fn EventHandler
	id uint32
}

// Client contains everything necessary to connect to and interact with the WhatsApp web API.
type Client struct {
	Store   *store.Device
	Log     waLog.Logger
	recvLog waLog.Logger
	sendLog waLog.Logger

	// AutoReconnectHook is called when auto-reconnection fails. If the function returns false,
	// the client will not attempt to reconnect. The number of retries can be read from AutoReconnectErrors.
	AutoReconnectHook func(error) bool
	// If SynchronousAck is set, acks for messages will only be sent after all event handlers return.
	SynchronousAck bool

	DisableLoginAutoReconnect bool

	// EmitAppStateEventsOnFullSync can be set to true if you want to get app state events emitted
	// even when re-syncing the whole state.
	EmitAppStateEventsOnFullSync bool

	AutomaticMessageRerequestFromPhone bool
	pendingPhoneRerequests             map[types.MessageID]context.CancelFunc

	historySyncNotifications chan *waE2E.HistorySyncNotification

	responseWaiters map[string]chan<- *waBinary.Node

	nodeHandlers      map[string]nodeHandler
	handlerQueue      chan *waBinary.Node
	eventHandlers     []wrappedEventHandler
	eventHandlersLock sync.RWMutex

	messageRetries map[string]int

	appStateKeyRequests map[string]time.Time

	groupParticipantsCache map[types.JID][]types.JID

	sessionRecreateHistory map[types.JID]time.Time
	// GetMessageForRetry is used to find the source message for handling retry receipts
	// when the message is not found in the recently sent message cache.
	GetMessageForRetry func(requester, to types.JID, id types.MessageID) *waE2E.Message
	// PreRetryCallback is called before a retry receipt is accepted.
	// If it returns false, the accepting will be cancelled and the retry receipt will be ignored.
	PreRetryCallback func(receipt *events.Receipt, id types.MessageID, retryCount int, msg *waE2E.Message) bool

	// PrePairCallback is called before pairing is completed. If it returns false, the pairing will be cancelled and
	// the client will disconnect.
	PrePairCallback func(jid types.JID, platform, businessName string) bool

	// GetClientPayload is called to get the client payload for connecting to the server.
	// This should NOT be used for WhatsApp (to change the OS name, update fields in store.BaseClientPayload directly).
	GetClientPayload func() *waWa6.ClientPayload

	// Should untrusted identity errors be handled automatically? If true, the stored identity and existing signal
	// sessions will be removed on untrusted identity errors, and an events.IdentityChange will be dispatched.
	// If false, decrypting a message from untrusted devices will fail.
	AutoTrustIdentity bool

	// Should SubscribePresence return an error if no privacy token is stored for the user?
	ErrorOnSubscribePresenceWithoutToken bool

	uniqueID string

	// This field changes the client to act like a Messenger client instead of a WhatsApp one.
	//
	// Note that you cannot use a Messenger account just by setting this field, you must use a
	// separate library for all the non-e2ee-related stuff like logging in.
	// The library is currently embedded in mautrix-meta (https://github.com/mautrix/meta), but may be separated later.
	MessengerConfig *MessengerConfig
	RefreshCAT      func() error
}

type MessengerConfig struct {
	UserAgent string
	BaseURL   string
}

// Size of buffer for the channel that all incoming XML nodes go through.
// In general it shouldn't go past a few buffered messages, but the channel is big to be safe.
const handlerQueueSize = 2048

// NewClient initializes a new WhatsApp web client.
//
// The logger can be nil, it will default to a no-op logger.
//
// The device store must be set. A default SQL-backed implementation is available in the store/sqlstore package.
//
//	container, err := sqlstore.New("sqlite3", "file:yoursqlitefile.db?_foreign_keys=on", nil)
//	if err != nil {
//		panic(err)
//	}
//	// If you want multiple sessions, remember their JIDs and use .GetDevice(jid) or .GetAllDevices() instead.
//	deviceStore, err := container.GetFirstDevice()
//	if err != nil {
//		panic(err)
//	}
//	client := whatsmeow.NewClient(deviceStore, nil)
func NewClient() *Client {
	uniqueIDPrefix := random.Bytes(2)
	cli := &Client{
		uniqueID:        fmt.Sprintf("%d.%d-", uniqueIDPrefix[0], uniqueIDPrefix[1]),
		responseWaiters: make(map[string]chan<- *waBinary.Node),
		eventHandlers:   make([]wrappedEventHandler, 0, 1),
		messageRetries:  make(map[string]int),
		handlerQueue:    make(chan *waBinary.Node, handlerQueueSize),

		historySyncNotifications: make(chan *waE2E.HistorySyncNotification, 32),

		groupParticipantsCache: make(map[types.JID][]types.JID),

		sessionRecreateHistory: make(map[types.JID]time.Time),
		GetMessageForRetry:     func(requester, to types.JID, id types.MessageID) *waE2E.Message { return nil },
		appStateKeyRequests:    make(map[string]time.Time),

		pendingPhoneRerequests: make(map[types.MessageID]context.CancelFunc),

		AutoTrustIdentity: true,
	}
	cli.nodeHandlers = map[string]nodeHandler{
		// "message":      cli.handleEncryptedMessage,
		// "appdata":      cli.handleEncryptedMessage,
		// "receipt":      cli.handleReceipt,
		// "call":         cli.handleCallEvent,
		// "chatstate":    cli.handleChatState,
		// "presence":     cli.handlePresence,
		// "notification": cli.handleNotification,
		// "success":      cli.handleConnectSuccess,
		// "failure":      cli.handleConnectFailure,
		// "stream:error": cli.handleStreamError,
		// "iq":           cli.handleIQ,
		// "ib":           cli.handleIB,
		// Apparently there's also an <error> node which can have a code=479 and means "Invalid stanza sent (smax-invalid)"
	}
	return cli
}

func (cli *Client) Connect() error {
	fs := NewFrameSocket()
	cli.doHandshake(fs, *NewKeyPair())

	return nil
}

func (cli *Client) getOwnID() types.JID {
	if cli == nil {
		return types.EmptyJID
	}
	id := cli.Store.ID
	if id == nil {
		return types.EmptyJID
	}
	return *id
}

func (cli *Client) AddEventHandler(handler EventHandler) uint32 {
	nextID := atomic.AddUint32(&nextHandlerID, 1)
	cli.eventHandlersLock.Lock()
	cli.eventHandlers = append(cli.eventHandlers, wrappedEventHandler{handler, nextID})
	cli.eventHandlersLock.Unlock()
	return nextID
}

// RemoveEventHandler removes a previously registered event handler function.
// If the function with the given ID is found, this returns true.
//
// N.B. Do not run this directly from an event handler. That would cause a deadlock because the
// event dispatcher holds a read lock on the event handler list, and this method wants a write lock
// on the same list. Instead run it in a goroutine:
//
//	func (mycli *MyClient) myEventHandler(evt interface{}) {
//		if noLongerWantEvents {
//			go mycli.WAClient.RemoveEventHandler(mycli.eventHandlerID)
//		}
//	}
func (cli *Client) RemoveEventHandler(id uint32) bool {
	cli.eventHandlersLock.Lock()
	defer cli.eventHandlersLock.Unlock()
	for index := range cli.eventHandlers {
		if cli.eventHandlers[index].id == id {
			if index == 0 {
				cli.eventHandlers[0].fn = nil
				cli.eventHandlers = cli.eventHandlers[1:]
				return true
			} else if index < len(cli.eventHandlers)-1 {
				copy(cli.eventHandlers[index:], cli.eventHandlers[index+1:])
			}
			cli.eventHandlers[len(cli.eventHandlers)-1].fn = nil
			cli.eventHandlers = cli.eventHandlers[:len(cli.eventHandlers)-1]
			return true
		}
	}
	return false
}

// RemoveEventHandlers removes all event handlers that have been registered with AddEventHandler
func (cli *Client) RemoveEventHandlers() {
	cli.eventHandlersLock.Lock()
	cli.eventHandlers = make([]wrappedEventHandler, 0, 1)
	cli.eventHandlersLock.Unlock()
}

func (cli *Client) handleFrame(data []byte) {
	decompressed, err := waBinary.Unpack(data)
	if err != nil {
		cli.Log.Warnf("Failed to decompress frame: %v", err)
		cli.Log.Debugf("Errored frame hex: %s", hex.EncodeToString(data))
		return
	}
	node, err := waBinary.Unmarshal(decompressed)
	if err != nil {
		cli.Log.Warnf("Failed to decode node in frame: %v", err)
		cli.Log.Debugf("Errored frame hex: %s", hex.EncodeToString(decompressed))
		return
	}
	cli.recvLog.Debugf("%s", node.XMLString())
	if node.Tag == "xmlstreamend" {

	} else if _, ok := cli.nodeHandlers[node.Tag]; ok {
		select {
		case cli.handlerQueue <- node:
		default:
			cli.Log.Warnf("Handler queue is full, message ordering is no longer guaranteed")
			go func() {
				cli.handlerQueue <- node
			}()
		}
	} else if node.Tag != "ack" {
		cli.Log.Debugf("Didn't handle WhatsApp node %s", node.Tag)
	}
}

func (cli *Client) sendNodeAndGetData(node waBinary.Node) ([]byte, error) {
	if cli == nil {
		return nil, nil
	}

	payload, err := waBinary.Marshal(node)
	if err != nil {
		return nil, fmt.Errorf("failed to marshal node: %w", err)
	}

	cli.sendLog.Debugf("%s", node.XMLString())
	return payload, nil
}

func (cli *Client) sendNode(node waBinary.Node) error {
	_, err := cli.sendNodeAndGetData(node)
	return err
}

func (cli *Client) dispatchEvent(evt any) {
	cli.eventHandlersLock.RLock()
	defer func() {
		cli.eventHandlersLock.RUnlock()
		err := recover()
		if err != nil {
			cli.Log.Errorf("Event handler panicked while handling a %T: %v\n%s", evt, err, debug.Stack())
		}
	}()
	for _, handler := range cli.eventHandlers {
		handler.fn(evt)
	}
}

func (cli *Client) ParseWebMessage(chatJID types.JID, webMsg *waWeb.WebMessageInfo) (*events.Message, error) {
	var err error
	if chatJID.IsEmpty() {
		chatJID, err = types.ParseJID(webMsg.GetKey().GetRemoteJID())
		if err != nil {
			return nil, fmt.Errorf("no chat JID provided and failed to parse remote JID: %w", err)
		}
	}
	info := types.MessageInfo{
		MessageSource: types.MessageSource{
			Chat:     chatJID,
			IsFromMe: webMsg.GetKey().GetFromMe(),
			IsGroup:  chatJID.Server == types.GroupServer,
		},
		ID:        webMsg.GetKey().GetId(),
		PushName:  webMsg.GetPushName(),
		Timestamp: time.Unix(int64(webMsg.GetMessageTimestamp()), 0),
	}
	if info.IsFromMe {
		info.Sender = cli.getOwnID().ToNonAD()
		if info.Sender.IsEmpty() {
			return nil, nil
		}
	} else if chatJID.Server == types.DefaultUserServer || chatJID.Server == types.NewsletterServer {
		info.Sender = chatJID
	} else if webMsg.GetParticipant() != "" {
		info.Sender, err = types.ParseJID(webMsg.GetParticipant())
	} else if webMsg.GetKey().GetParticipant() != "" {
		info.Sender, err = types.ParseJID(webMsg.GetKey().GetParticipant())
	} else {
		return nil, fmt.Errorf("couldn't find sender of message %s", info.ID)
	}
	if err != nil {
		return nil, fmt.Errorf("failed to parse sender of message %s: %v", info.ID, err)
	}
	evt := &events.Message{
		RawMessage:   webMsg.GetMessage(),
		SourceWebMsg: webMsg,
		Info:         info,
	}
	evt.UnwrapRaw()
	if evt.Message.GetProtocolMessage().GetType() == waE2E.ProtocolMessage_MESSAGE_EDIT {
		evt.Info.ID = evt.Message.GetProtocolMessage().GetKey().GetID()
		evt.Message = evt.Message.GetProtocolMessage().GetEditedMessage()
	}
	return evt, nil
}
