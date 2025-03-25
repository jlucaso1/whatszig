const std = @import("std");
const ws = @import("./websocket.zig");
const json = std.json;
const mem = std.mem;
const Allocator = mem.Allocator;
const tls = @import("tls");

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
    websocket: ?*ws.WebSocketClient, // Change to pointer type
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
            socket.close() catch {}; // Use direct pointer
            self.allocator.destroy(socket);
            self.websocket = null;
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

        var prng = std.Random.DefaultPrng.init(blk: {
            var seed: u64 = undefined;
            try std.posix.getrandom(std.mem.asBytes(&seed));
            break :blk seed;
        });
        const rand = prng.random();

        // Create a WebSocketClient on the heap
        var client = try self.allocator.create(ws.WebSocketClient);
        client.* = ws.WebSocketClient.init(self.allocator, rand);
        errdefer {
            client.deinit() catch {};
            self.allocator.destroy(client);
        }

        try client.connect("web.whatsapp.com", 443, "/ws/chat");

        self.websocket = client;
        std.debug.print("WebSocket connection established\n", .{});

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

        // Send initial handshake
        try self.performHandshake(parsed.value);

        // Mark as connected both in Go and Zig
        const connect_result = c.Connect();
        defer std.c.free(connect_result);

        const connect_str = std.mem.span(connect_result);
        if (!mem.eql(u8, connect_str, "Connected successfully")) {
            if (self.websocket) |socket| {
                socket.close() catch {}; // Use direct pointer
                self.allocator.destroy(socket);
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

        _ = pubkey_b64;
        // Decode from base64
        var header_buffer: [128]u8 = undefined;
        try std.base64.standard.Decoder.decode(
            &header_buffer,
            header_b64,
        );

        // Create a mutable copy of the header data since write requires []u8 not []const u8
        const header = try self.allocator.dupe(u8, &header_buffer);
        defer self.allocator.free(header);

        // Send initial header. This has an error because is sending a 128 length message, but need to send exact 43.
        try self.sendMessage(header[0..43]);

        // Receive the server's response instead of starting an infinite listener
        if (self.websocket == null) {
            return WhatsAppError.NotConnected;
        }

        var socket_ptr = self.websocket.?;

        // Receive the server's response to our handshake
        const response = try socket_ptr.receiveMessage();

        if (response.len == 0 or response.len != 350) {
            return WhatsAppError.InvalidResponse;
        }

        const responseLen: c_int = @intCast(response.len);

        // Pass both the pointer and length to Go function
        const result = c.SendHandshakeResponse(response.ptr, responseLen);
        defer std.c.free(result);

        const result_str = std.mem.span(result);

        // verify if result_str contains error
        if (std.mem.indexOf(u8, result_str, "Error") != null) {
            std.debug.print("Handshake error: {s}\n", .{result_str});
            return WhatsAppError.HandshakeError;
        }

        // Clean the base64 string
        const cleaned_result = try cleanBase64(self.allocator, result_str);
        defer self.allocator.free(cleaned_result);

        // Add proper padding to base64 string if needed
        const padded_result = try ensureBase64Padding(self.allocator, cleaned_result);
        defer self.allocator.free(padded_result);

        // Use a safe function to decode the base64 string
        const decoded_data = try safeBase64Decode(self.allocator, padded_result);
        defer self.allocator.free(decoded_data);

        // Send the decoded data
        try self.sendMessage(decoded_data);

        // receive server message again
        const server_response = try socket_ptr.receiveMessage();
        if (server_response.len == 0) {
            return WhatsAppError.InvalidResponse;
        }

        // Call processData with proper parameters and handle the result
        const result_ptr = c.processData(server_response.ptr, @intCast(server_response.len));
        defer std.c.free(result_ptr);

        // Check if the result is not null and free it when done
        if (result_ptr != null) {
            const result_str2 = std.mem.span(result_ptr);
            std.debug.print("Process data input: {d}\n", .{server_response.len});
            std.debug.print("Process data result: {d}\n", .{result_str2.len});
        }

        // Now we can start the continuous listener if needed
        try self.startSocketListener();
    }

    // Function to clean a base64 string, removing invalid characters
    fn cleanBase64(allocator: Allocator, input: []const u8) ![]const u8 {
        var buffer = try allocator.alloc(u8, input.len);
        errdefer allocator.free(buffer);

        var len: usize = 0;
        for (input) |char| {
            // Only keep valid base64 characters
            if ((char >= 'A' and char <= 'Z') or
                (char >= 'a' and char <= 'z') or
                (char >= '0' and char <= '9') or
                char == '+' or char == '/' or char == '=')
            {
                buffer[len] = char;
                len += 1;
            }
        }

        return allocator.realloc(buffer, len);
    }

    // Function to safely decode base64 with better error handling
    fn safeBase64Decode(allocator: Allocator, input: []const u8) ![]u8 {
        // Calculate max size needed (4 base64 chars → 3 bytes)
        const max_len = input.len * 3 / 4 + 1;
        const buffer = try allocator.alloc(u8, max_len);
        errdefer allocator.free(buffer);

        // Try to decode, and handle any errors
        var actual_len: usize = 0;
        std.base64.standard.Decoder.decode(buffer, input) catch |err| {
            std.debug.print("Base64 decode error: {}\n", .{err});
            // On error, at least return what we have - could be partial decode
            // For a more robust solution, we could implement our own base64 decoder
            return allocator.realloc(buffer, 0);
        };

        actual_len = buffer.len;
        return allocator.realloc(buffer, actual_len);
    }

    // Helper function to ensure base64 string has proper padding
    fn ensureBase64Padding(allocator: Allocator, input: []const u8) ![]const u8 {
        // If already a multiple of 4, no padding needed
        if (input.len % 4 == 0) return allocator.dupe(u8, input);

        // Calculate padding needed
        const padding_needed = 4 - (input.len % 4);

        // Allocate a new buffer with space for padding
        var result = try allocator.alloc(u8, input.len + padding_needed);

        // Copy the original string - fix by specifying the destination slice length
        @memcpy(result[0..input.len], input);

        // Add padding characters
        for (0..padding_needed) |i| {
            result[input.len + i] = '=';
        }

        return result;
    }

    fn startSocketListener(self: *Self) !void {
        if (self.websocket == null) {
            return WhatsAppError.NotConnected;
        }

        // Start a separate thread to listen for WebSocket messages
        var socket_ptr = self.websocket.?;

        // Listen for messages
        while (true) {
            const message = try socket_ptr.receiveMessage();

            std.debug.print("Received message: {d}\n", .{message.len});
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

        if (self.websocket) |socket| {
            socket.close() catch {}; // Use direct pointer
            self.allocator.destroy(socket);
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

    pub fn sendMessage(self: *Self, data: []u8) !void {
        if (!self.initialized) {
            return WhatsAppError.NotInitialized;
        }

        try self.websocket.?.sendBinary(data);

        std.debug.print("Sent message: {d}\n", .{data.len});
    }
};

// Helper function to create a WhatsApp client
pub fn createWhatsAppClient(allocator: std.mem.Allocator) !*WhatsAppClient {
    const client = try allocator.create(WhatsAppClient);
    client.* = WhatsAppClient.init(allocator);
    return client;
}
