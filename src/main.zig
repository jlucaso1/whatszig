const std = @import("std");

const whatsapp = @import("whatsapp.zig");

pub fn main() !void {
    // Setup crash handler
    std.debug.print("Starting WhatsApp client test\n", .{});

    // Use a simpler allocator for now
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    std.debug.print("Creating client...\n", .{});
    const client = whatsapp.createWhatsAppClient(allocator) catch |err| {
        std.debug.print("Failed to create WhatsApp client: {}\n", .{err});
        return;
    };
    std.debug.print("Initializing client...\n", .{});
    try client.initialize();
    defer client.deinit();

    std.debug.print("Connecting to WhatsApp...\n", .{});
    try client.connect();

    std.debug.print("Checking connection...\n", .{});
    const isConnected = client.isConnected();
    std.debug.print("Is connected? {}\n", .{isConnected});
}
