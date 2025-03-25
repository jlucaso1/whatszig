const std = @import("std");
const net = std.net;
const mem = std.mem;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const tls = std.crypto.tls;
const cert_loader = @import("cert_loader.zig");

pub const OpCode = enum(u4) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xA,
};

pub const WebSocketClient = struct {
    stream: net.Stream,
    buffer: ArrayList(u8),
    read_buffer: [4096]u8,
    mask_key: [4]u8,
    allocator: Allocator,
    random: std.Random,
    is_connected: bool,
    secure: bool,
    tls_client: ?tls.Client,

    pub fn init(allocator: Allocator, random: std.Random) WebSocketClient {
        return .{
            .stream = undefined,
            .buffer = ArrayList(u8).init(allocator),
            .read_buffer = undefined,
            .mask_key = undefined,
            .allocator = allocator,
            .random = random,
            .is_connected = false,
            .secure = false,
            .tls_client = null,
        };
    }

    pub fn deinit(self: *WebSocketClient) !void {
        if (self.is_connected) {
            if (self.tls_client) |*client| {
                const bytes: []const u8 = "close";
                _ = try client.writeEnd(self.stream, bytes, true);
                self.tls_client = null;
            }
            self.stream.close();
            self.is_connected = false;
        }
        self.buffer.deinit();
    }

    fn writeToStream(self: *WebSocketClient, data: []const u8) !usize {
        if (self.secure) {
            if (self.tls_client) |*client| {
                return try client.write(self.stream, data);
            }
            return error.NoTlsClient;
        } else {
            return try self.stream.write(data);
        }
    }

    fn readFromStream(self: *WebSocketClient, buffer: []u8) !usize {
        if (self.secure) {
            if (self.tls_client) |*client| {
                return try client.read(self.stream, buffer);
            }
            return error.NoTlsClient;
        } else {
            return try self.stream.read(buffer);
        }
    }

    pub fn connect(self: *WebSocketClient, host: []const u8, port: u16, path: []const u8) !void {
        // Close any existing connection
        if (self.is_connected) {
            if (self.tls_client) |*client| {
                const bytes: []const u8 = "close";
                _ = try client.writeEnd(self.stream, bytes, true);
                self.tls_client = null;
            }
            self.stream.close();
            self.is_connected = false;
        }

        // Connect to the server
        self.stream = try net.tcpConnectToHost(self.allocator, host, port);
        self.is_connected = true;

        // Determine if we need a secure connection (WSS)
        self.secure = (port == 443);

        // If using WSS (port 443), establish TLS connection
        if (self.secure) {
            // Load system certificates
            const bundle = try cert_loader.loadSystemCertificates(self.allocator);

            const client = try tls.Client.init(self.stream, .{
                .host = .{ .explicit = host },
                .ca = .{ .bundle = bundle },
            });
            self.tls_client = client;
        }

        // Create WebSocket handshake request
        var nonce_bytes: [16]u8 = undefined;
        self.random.bytes(&nonce_bytes);

        var nonce_b64: [24]u8 = undefined;
        const nonce_b64_slice = std.base64.standard.Encoder.encode(&nonce_b64, &nonce_bytes);

        try self.buffer.resize(0);
        try self.buffer.appendSlice("GET ");
        try self.buffer.appendSlice(path);
        try self.buffer.appendSlice(" HTTP/1.1\r\n");
        try self.buffer.appendSlice("Host: ");
        try self.buffer.appendSlice(host);
        if (port != 80 and port != 443) {
            try self.buffer.appendSlice(":");
            try self.buffer.appendSlice(try std.fmt.allocPrint(self.allocator, "{d}", .{port}));
        }
        try self.buffer.appendSlice("\r\n");
        try self.buffer.appendSlice("Upgrade: websocket\r\n");
        try self.buffer.appendSlice("Connection: Upgrade\r\n");
        try self.buffer.appendSlice("Sec-WebSocket-Key: ");
        try self.buffer.appendSlice(nonce_b64_slice);
        try self.buffer.appendSlice("\r\n");
        try self.buffer.appendSlice("Sec-WebSocket-Version: 13\r\n");
        try self.buffer.appendSlice("Origin: http://");
        try self.buffer.appendSlice(host);
        try self.buffer.appendSlice("\r\n");
        try self.buffer.appendSlice("\r\n");

        // Send the handshake
        _ = try self.writeToStream(self.buffer.items);

        // Read handshake response
        const read_amount = try self.readFromStream(&self.read_buffer);
        const response = self.read_buffer[0..read_amount];

        // print response
        std.debug.print("Response: {s}\n", .{response});

        // Validate response (basic check for HTTP 101 Switching Protocols)
        if (!mem.startsWith(u8, response, "HTTP/1.1 101")) {
            if (self.tls_client) |*client| {
                const bytes: []const u8 = "close";
                _ = try client.writeEnd(self.stream, bytes, true);
                self.tls_client = null;
            }
            self.stream.close();
            self.is_connected = false;
            return error.HandshakeFailed;
        }
    }

    pub fn sendMessage(self: *WebSocketClient, message: []const u8, op_code: OpCode) !void {
        if (!self.is_connected) {
            return error.NotConnected;
        }

        // Generate random mask key
        self.random.bytes(&self.mask_key);

        // Create frame header
        try self.buffer.resize(0);

        // First byte: FIN bit (1) + RSV bits (000) + opcode (4 bits)
        const first_byte: u8 = 0b10000000 | @as(u8, @intFromEnum(op_code));
        try self.buffer.append(first_byte);

        // Second byte: MASK bit (1) + payload length
        const payload_len = message.len;
        if (payload_len < 126) {
            try self.buffer.append(@as(u8, @intCast(payload_len)) | 0x80);
        } else if (payload_len <= 65535) {
            try self.buffer.append(126 | 0x80);
            try self.buffer.append(@as(u8, @intCast((payload_len >> 8) & 0xFF)));
            try self.buffer.append(@as(u8, @intCast(payload_len & 0xFF)));
        } else {
            try self.buffer.append(127 | 0x80);
            var i: usize = 8;
            while (i > 0) {
                i -= 1;
                try self.buffer.append(@as(u8, @intCast((payload_len >> (@as(u6, @intCast(i)) * 8)) & 0xFF)));
            }
        }

        // Add masking key
        try self.buffer.appendSlice(&self.mask_key);

        // Add masked payload
        const start_pos = self.buffer.items.len;
        try self.buffer.appendSlice(message);

        // Apply mask
        var i: usize = 0;
        while (i < message.len) : (i += 1) {
            self.buffer.items[start_pos + i] ^= self.mask_key[i % 4];
        }

        // Send the frame
        _ = try self.writeToStream(self.buffer.items);
    }

    pub fn receiveMessage(self: *WebSocketClient) ![]u8 {
        if (!self.is_connected) {
            return error.NotConnected;
        }

        try self.buffer.resize(0);

        // Read frame header (at least 2 bytes)
        const header_read = try self.readFromStream(self.read_buffer[0..2]);
        if (header_read < 2) return error.ConnectionClosed;

        const first_byte = self.read_buffer[0];
        const second_byte = self.read_buffer[1];

        const fin = (first_byte & 0x80) != 0;
        const op_code = @as(OpCode, @enumFromInt(first_byte & 0x0F));
        const masked = (second_byte & 0x80) != 0;
        var payload_len: usize = second_byte & 0x7F;

        var header_size: usize = 2;

        // Handle extended payload length
        if (payload_len == 126) {
            const len_read = try self.readFromStream(self.read_buffer[2..4]);
            if (len_read < 2) return error.ConnectionClosed;
            payload_len = (@as(usize, self.read_buffer[2]) << 8) | @as(usize, self.read_buffer[3]);
            header_size = 4;
        } else if (payload_len == 127) {
            const len_read = try self.readFromStream(self.read_buffer[2..10]);
            if (len_read < 8) return error.ConnectionClosed;

            payload_len = 0;
            var i: usize = 0;
            while (i < 8) : (i += 1) {
                payload_len = (payload_len << 8) | self.read_buffer[2 + i];
            }
            header_size = 10;
        }

        // Get masking key if frame is masked
        var mask_key = [_]u8{0} ** 4;
        if (masked) {
            const mask_read = try self.readFromStream(self.read_buffer[header_size .. header_size + 4]);
            if (mask_read < 4) return error.ConnectionClosed;
            @memcpy(&mask_key, self.read_buffer[header_size .. header_size + 4]);
            header_size += 4;
        }

        // Read payload data
        var total_read: usize = 0;
        try self.buffer.resize(payload_len);

        while (total_read < payload_len) {
            const to_read = @min(payload_len - total_read, self.read_buffer.len);
            const read_amount = try self.readFromStream(self.read_buffer[0..to_read]);
            if (read_amount == 0) break;

            // Copy and unmask data
            var i: usize = 0;
            while (i < read_amount) : (i += 1) {
                const data = self.read_buffer[i];
                const unmasked = if (masked) data ^ mask_key[(total_read + i) % 4] else data;
                self.buffer.items[total_read + i] = unmasked;
            }

            total_read += read_amount;
        }

        // Handle control frames
        switch (op_code) {
            .close => {
                self.stream.close();
                self.is_connected = false;
                return error.ConnectionClosed;
            },
            .ping => {
                // Respond with a pong
                try self.sendMessage(self.buffer.items, .pong);
                // Return next message
                return self.receiveMessage();
            },
            .pong => {
                // Ignore pong responses and get next message
                return self.receiveMessage();
            },
            else => {},
        }

        // For non-control frames, handle fragmentation
        if (!fin) {
            // This is a fragmented message, we need to get the continuation frames
            const initial_payload = try self.allocator.dupe(u8, self.buffer.items);
            defer self.allocator.free(initial_payload);

            try self.buffer.resize(0);
            try self.buffer.appendSlice(initial_payload);

            // Keep reading continuations until we hit a FIN frame
            while (true) {
                const next_message = try self.receiveFragment();
                try self.buffer.appendSlice(next_message);
                self.allocator.free(next_message);

                if (self.read_buffer[0] & 0x80 != 0) {
                    // FIN bit is set, we're done
                    break;
                }
            }
        }

        std.debug.print("Received message: {d}\n", .{self.buffer.items.len});

        return self.buffer.toOwnedSlice();
    }

    fn receiveFragment(self: *WebSocketClient) ![]u8 {
        // Similar to receiveMessage but only handles a single frame
        // Returns a slice that the caller must free
        // This is simplified and should be expanded for a complete implementation
        const header_read = try self.readFromStream(self.read_buffer[0..2]);
        if (header_read < 2) return error.ConnectionClosed;

        // Process header and read payload...
        // (Similar logic to receiveMessage, but simplified for brevity)

        // Return the payload
        return self.allocator.dupe(u8, self.read_buffer[0..10]);
    }

    pub fn sendText(self: *WebSocketClient, text: []const u8) !void {
        return self.sendMessage(text, .text);
    }

    pub fn sendBinary(self: *WebSocketClient, data: []const u8) !void {
        return self.sendMessage(data, .binary);
    }

    pub fn close(self: *WebSocketClient) !void {
        if (!self.is_connected) {
            return;
        }

        try self.sendMessage("", .close);
        self.stream.close();
        self.is_connected = false;
    }
};
