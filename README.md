# WhatsZig

A WhatsApp messaging client written in Zig, powered by the Go WhatsApp library.

[![GitHub](https://img.shields.io/badge/GitHub-WhatsZig-blue?logo=github)](https://github.com/jlucaso1/whatszig)

## Description

WhatsZig is a simple WhatsApp messaging application that connects to the WhatsApp network using Zig as the primary language with Go bindings. It allows you to authenticate via QR code and send messages to WhatsApp contacts.

## Requirements

- Zig (0.14.0 or later)
- Go (1.20 or later)
- A WhatsApp account

## Installation

1. Clone the repository:
   ```
   git clone https://github.com/jlucaso1/whatszig.git
   cd whatszig
   ```

2. Build the project:
   ```
   zig build
   ```

## Usage

### Running the Application

Execute the following command:

```
zig build run
```

### Authentication Process

1. On first run, the application will display a QR code in the terminal (in base64 format).
2. Copy the QR code data and convert it to an image using an online tool or local converter.
3. Scan the QR code with your WhatsApp mobile app:
   - Open WhatsApp on your phone
   - Go to Settings > Linked Devices
   - Tap on "Link a Device"
   - Scan the QR code

4. After successful authentication, you'll be prompted to enter a phone number to send a message.

### Sending Messages

1. Enter the recipient's phone number when prompted (e.g., 559999999999).
2. Enter the message you want to send.
3. The message will be sent, and the program will display the result before exiting.

### Persistent Authentication

After the first authentication, the application creates a local database file (`whatsmeow.db`) that stores your session. This means you won't need to scan the QR code again on subsequent runs, unless you log out or your session expires.

## How It Works

WhatsZig uses:
- Zig for the main application logic and user interface
- Go's WhatsApp library (whatsmeow) for WhatsApp protocol implementation
- CGO to connect Zig and Go components

## Credits

This project would not be possible without:

- [tulir/whatsmeow](https://github.com/tulir/whatsmeow) - The excellent Go WhatsApp library that powers the core functionality
- [WhiskeySockets/Baileys](https://github.com/WhiskeySockets/Baileys) - For inspiration on WhatsApp API implementation

## License

[MIT License](LICENSE)
