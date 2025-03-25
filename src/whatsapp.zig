const std = @import("std");
const ws = @import("./websocket.zig");
const json = std.json;
const mem = std.mem;
const Allocator = mem.Allocator;
const tls = @import("tls");
const base64_utils = @import("./utils/base64.zig");
const json_utils = @import("./utils/json.zig");

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
    JsonParseError,
};

pub const WhatsAppClient = struct {
    allocator: Allocator,
    websocket: ?*ws.WebSocketClient,
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
        if (self.websocket) |socket| {
            socket.close() catch {};
            self.allocator.destroy(socket);
            self.websocket = null;
        }
        self.connected = false;
        self.initialized = false;
    }

    pub fn initialize(self: *Self) !void {
        // Call the Go initialization function
        const result_ptr = c.Initialize();
        if (result_ptr == null) {
            return WhatsAppError.InitializationFailed;
        }
        defer std.c.free(result_ptr);

        const result_str = std.mem.span(result_ptr);
        std.debug.print("Initialize result: {s}\n", .{result_str});

        if (!mem.eql(u8, result_str, "Initialized successfully")) {
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

        // Initialize websocket connection
        try self.initWebSocket();

        // Get and process handshake data
        try self.initHandshake();

        // Mark as connected
        const connect_result = c.Connect();
        defer std.c.free(connect_result);

        const connect_str = std.mem.span(connect_result);
        if (!mem.eql(u8, connect_str, "Connected successfully")) {
            try self.cleanupWebSocket();
            return WhatsAppError.ConnectionFailed;
        }

        self.connected = true;
    }

    fn initWebSocket(self: *Self) !void {
        // Create secure random source for WebSocket
        var prng = std.Random.DefaultPrng.init(blk: {
            var seed: u64 = undefined;
            try std.posix.getrandom(std.mem.asBytes(&seed));
            break :blk seed;
        });
        const rand = prng.random();

        // Create a WebSocketClient on the heap
        var client = try self.allocator.create(ws.WebSocketClient);
        errdefer self.allocator.destroy(client);

        client.* = ws.WebSocketClient.init(self.allocator, rand);
        errdefer client.deinit() catch {};

        try client.connect("web.whatsapp.com", 443, "/ws/chat");

        self.websocket = client;
        std.debug.print("WebSocket connection established\n", .{});
    }

    fn cleanupWebSocket(self: *Self) !void {
        if (self.websocket) |socket| {
            socket.close() catch {};
            self.allocator.destroy(socket);
            self.websocket = null;
        }
    }

    fn initHandshake(self: *Self) !void {
        // Get handshake data from Go library
        const handshake_data = c.GetHandshakeData();
        if (handshake_data == null) {
            return WhatsAppError.HandshakeError;
        }
        defer std.c.free(handshake_data);

        const handshake_str = std.mem.span(handshake_data);

        // Parse JSON handshake data
        var parsed = json.parseFromSlice(
            std.json.Value,
            self.allocator,
            handshake_str,
            .{},
        ) catch {
            return WhatsAppError.JsonParseError;
        };
        defer parsed.deinit();

        // Perform the handshake with server
        try self.performHandshake(parsed.value);
    }

    fn performHandshake(self: *Self, handshake_data: json.Value) !void {
        if (self.websocket == null) {
            return WhatsAppError.WebSocketError;
        }

        // Extract header from handshake data
        const header_b64 = try json_utils.extractString(handshake_data, "header");

        // Decode header from base64
        const header = try base64_utils.decodeBase64(self.allocator, header_b64);
        defer self.allocator.free(header);

        // Send initial header (43 bytes is the correct length)
        if (header.len < 43) {
            return WhatsAppError.InvalidResponse;
        }
        try self.sendMessage(header[0..43]);

        // Receive the server's response
        const response = try self.receiveWebSocketMessage();
        if (response.len == 0) {
            return WhatsAppError.InvalidResponse;
        }

        // Send response to Go for processing
        try self.processHandshakeResponse(response);

        // Start socket listener for further communication
        try self.startSocketListener();
    }

    fn receiveWebSocketMessage(self: *Self) ![]u8 {
        if (self.websocket == null) {
            return WhatsAppError.NotConnected;
        }

        return self.websocket.?.receiveMessage();
    }

    fn processHandshakeResponse(self: *Self, response: []const u8) !void {
        if (response.len == 0) {
            return WhatsAppError.InvalidResponse;
        }

        const responseLen: c_int = @intCast(response.len);
        const result = c.SendHandshakeResponse(@constCast(response.ptr), responseLen);
        if (result == null) {
            return WhatsAppError.HandshakeError;
        }
        defer std.c.free(result);

        const result_str = std.mem.span(result);

        // Check for errors in result
        if (std.mem.indexOf(u8, result_str, "Error") != null) {
            std.debug.print("Handshake error: {s}\n", .{result_str});
            return WhatsAppError.HandshakeError;
        }

        // Decode and send final handshake message
        const decoded_data = try base64_utils.decodeBase64(self.allocator, result_str);
        defer self.allocator.free(decoded_data);

        try self.sendMessage(decoded_data);

        // Receive and process server confirmation
        const server_response = try self.receiveWebSocketMessage();
        if (server_response.len == 0) {
            return WhatsAppError.InvalidResponse;
        }

        // Process the response data
        const process_result = c.processData(@ptrCast(server_response.ptr), @intCast(server_response.len));
        if (process_result == null) {
            return WhatsAppError.InvalidResponse;
        }
        defer std.c.free(process_result);

        const process_str = std.mem.span(process_result);
        std.debug.print("Process response: {d} bytes\n", .{process_str.len});
    }

    fn startSocketListener(self: *Self) !void {
        if (self.websocket == null) {
            return WhatsAppError.NotConnected;
        }

        // In a production app, you would start a separate thread here
        // For this example, we just receive one more message
        const message = try self.receiveWebSocketMessage();
        if (message.len > 0) {
            std.debug.print("Received message: {d} bytes\n", .{message.len});

            // Process the received message with Go
            const result = c.processData(@ptrCast(message.ptr), @intCast(message.len));
            if (result != null) {
                defer std.c.free(result);
                const result_str = std.mem.span(result);
                std.debug.print("Processed message: {d} bytes\n", .{result_str.len});
            }
        }
    }

    pub fn isConnected(self: *const Self) bool {
        return self.initialized and self.connected;
    }

    pub fn disconnect(self: *Self) !void {
        if (!self.initialized) {
            return WhatsAppError.NotInitialized;
        }

        if (!self.connected) {
            return;
        }

        try self.cleanupWebSocket();

        const result = c.Disconnect();
        defer std.c.free(result);

        self.connected = false;
    }

    pub fn getClientInfo(self: *Self) ![]const u8 {
        if (!self.initialized) {
            return WhatsAppError.NotInitialized;
        }

        const info = c.GetClientInfo();
        if (info == null) {
            return WhatsAppError.InvalidResponse;
        }
        defer std.c.free(info);

        const info_str = std.mem.span(info);
        return self.allocator.dupe(u8, info_str);
    }

    pub fn sendMessage(self: *Self, data: []u8) !void {
        if (!self.initialized) {
            return WhatsAppError.NotInitialized;
        }

        if (self.websocket == null) {
            return WhatsAppError.NotConnected;
        }

        try self.websocket.?.sendBinary(data);
        std.debug.print("Sent message: {d} bytes\n", .{data.len});
    }
};

// Helper function to create a WhatsApp client
pub fn createWhatsAppClient(allocator: std.mem.Allocator) !*WhatsAppClient {
    const client = try allocator.create(WhatsAppClient);
    client.* = WhatsAppClient.init(allocator);
    return client;
}
