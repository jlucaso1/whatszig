const std = @import("std");
const ws = @import("websocket");
const json = std.json;
const mem = std.mem;
const Allocator = mem.Allocator;

// Import Go functions
const c = @cImport({
    @cInclude("libwhatsapp.h");
});

pub const WhatsAppError = error{
    InitializationFailed,
    ConnectionFailed,
    NotInitialized,
    NotConnected,
    WebSocketError,
    HandshakeError,
    InvalidResponse,
    OutOfMemory,
};

pub const WhatsAppClient = struct {
    allocator: Allocator,
    websocket: ?ws.Client,
    initialized: bool,
    connected: bool,

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        return Self{
            .allocator = allocator,
            .websocket = null,
            .initialized = false,
            .connected = false,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.websocket) |*socket| {
            socket.close(.{}) catch {};
        }

        // Avoid calling the C function directly
        self.connected = false;
        self.initialized = false;
    }

    pub fn initialize(self: *Self) !void {
        // Add a safety check for null result
        const result_ptr = c.Initialize();
        if (result_ptr == null) {
            std.debug.print("Initialization returned null\n", .{});
            return WhatsAppError.InitializationFailed;
        }

        defer std.c.free(result_ptr);
        const result_str = std.mem.span(result_ptr);

        std.debug.print("Initialize result: {s}\n", .{result_str});

        if (!mem.eql(u8, result_str, "Initialized successfully")) {
            std.debug.print("Initialization failed: {s}\n", .{result_str});
            return WhatsAppError.InitializationFailed;
        }

        self.initialized = true;
    }

    pub fn connect(self: *Self) !void {
        if (!self.initialized) {
            return WhatsAppError.NotInitialized;
        }

        if (self.connected) {
            return;
        }

        // Get handshake data from Go library
        const handshake_data = c.GetHandshakeData();
        defer std.c.free(handshake_data);

        const handshake_str = std.mem.span(handshake_data);
        var parsed = try json.parseFromSlice(
            std.json.Value,
            self.allocator,
            handshake_str,
            .{},
        );
        defer parsed.deinit();

        // Connect WebSocket with proper TLS setup and browser-like headers
        var client = try ws.Client.init(self.allocator, .{ .host = "web.whatsapp.com", .port = 443, .tls = true });

        const request_path = "/ws/chat";

        const headers = "Origin: https://web.whatsapp.com";

        try client.handshake(request_path, .{
            .headers = headers,
            .timeout_ms = 30000, // Longer timeout for connection
        });

        self.websocket = client;
        std.debug.print("WebSocket connection established\n", .{});

        // Send initial handshake
        try self.performHandshake(parsed.value);

        // Mark as connected both in Go and Zig
        const connect_result = c.Connect();
        defer std.c.free(connect_result);

        const connect_str = std.mem.span(connect_result);
        if (!mem.eql(u8, connect_str, "Connected successfully")) {
            if (self.websocket) |*socket| {
                try socket.close(.{});
                self.websocket = null;
            }
            std.debug.print("Connection failed: {s}\n", .{connect_str});
            return WhatsAppError.ConnectionFailed;
        }

        self.connected = true;
    }

    fn performHandshake(self: *Self, handshake_data: json.Value) !void {
        if (self.websocket == null) {
            return WhatsAppError.WebSocketError;
        }

        // Extract header and public key from handshake data
        if (handshake_data != .object) {
            return WhatsAppError.HandshakeError;
        }

        const header_b64 = if (handshake_data.object.get("header")) |value|
            if (value == .string) value.string else return WhatsAppError.HandshakeError
        else
            return WhatsAppError.HandshakeError;

        const pubkey_b64 = if (handshake_data.object.get("publicKey")) |value|
            if (value == .string) value.string else return WhatsAppError.HandshakeError
        else
            return WhatsAppError.HandshakeError;

        // Decode from base64
        var header_buffer: [128]u8 = undefined;
        try std.base64.standard.Decoder.decode(
            &header_buffer,
            header_b64,
        );

        // Create a mutable copy of the header data since write requires []u8 not []const u8
        const header = try self.allocator.dupe(u8, &header_buffer);
        defer self.allocator.free(header);

        // Send initial header
        try self.websocket.?.write(header);

        // Create client hello message
        // Note: In a real implementation, you would create a proper ClientHello
        // protobuf message using the public key from handshake_data
        const client_hello_buffer: [256]u8 = undefined;
        _ = client_hello_buffer;
        _ = pubkey_b64; // Use this in the actual ClientHello message

        // Now we'll start a listener for the WebSocket
        try self.startSocketListener();
    }

    fn startSocketListener(self: *Self) !void {
        if (self.websocket == null) {
            return WhatsAppError.NotConnected;
        }

        // Start a separate thread to listen for WebSocket messages
        var socket = self.websocket.?;

        // Listen for messages
        while (true) {
            const message = (try socket.read()) orelse {
                std.time.sleep(100 * std.time.ns_per_ms);
                continue;
            };

            defer socket.done(message);

            switch (message.type) {
                .text => {
                    std.debug.print("Received text: {s}\n", .{message.data});
                },
                .binary => {
                    std.debug.print("Received binary data: {} bytes\n", .{message.data.len});
                },
                .ping => try socket.writePong(message.data),
                .pong => {},
                .close => {
                    try socket.close(.{});
                    break;
                },
            }
        }
    }

    pub fn isConnected(self: *const Self) bool {
        // Only rely on our internal state tracking and don't call the C function
        // that's causing the integer overflow
        return self.initialized and self.connected;
    }

    pub fn disconnect(self: *Self) !void {
        if (!self.initialized) {
            return WhatsAppError.NotInitialized;
        }

        if (!self.connected) {
            return;
        }

        if (self.websocket) |*socket| {
            socket.close() catch {};
            self.websocket = null;
        }

        const result = c.Disconnect();
        defer std.c.free(result);

        self.connected = false;
    }

    pub fn getClientInfo(self: *Self) ![]const u8 {
        if (!self.initialized) {
            return WhatsAppError.NotInitialized;
        }

        const info = c.GetClientInfo();
        defer std.c.free(info);

        const info_str = std.mem.span(info);
        return try self.allocator.dupe(u8, info_str);
    }
};

// Helper function to create a WhatsApp client
pub fn createWhatsAppClient(allocator: Allocator) !*WhatsAppClient {
    const client = try allocator.create(WhatsAppClient);
    client.* = WhatsAppClient.init(allocator);
    return client;
}
