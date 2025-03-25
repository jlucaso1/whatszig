const std = @import("std");
// const c = @cImport({
//     @cInclude("libwhatsapp.h");
// });

// pub fn main() !void {
//     // Parse command line arguments
//     var args_iterator = try std.process.argsWithAllocator(std.heap.page_allocator);
//     defer args_iterator.deinit();

//     // Skip the program name
//     _ = args_iterator.skip();

//     // Get recipient and message from args if available
//     var recipient_from_args: ?[]const u8 = null;
//     var message_from_args: ?[]const u8 = null;

//     if (args_iterator.next()) |arg1| {
//         recipient_from_args = try std.heap.page_allocator.dupe(u8, arg1);
//         if (args_iterator.next()) |arg2| {
//             message_from_args = try std.heap.page_allocator.dupe(u8, arg2);
//         }
//     }
//     defer if (recipient_from_args) |ptr| std.heap.page_allocator.free(ptr);
//     defer if (message_from_args) |ptr| std.heap.page_allocator.free(ptr);

//     // Initialize WhatsApp client
//     var init_success = false;
//     {
//         const result = c.Initialize();
//         defer std.c.free(result);
//         std.debug.print("Initialization result: {s}\n", .{result});

//         // Check if initialization was successful
//         if (std.mem.indexOf(u8, std.mem.span(result), "Error") == null) {
//             init_success = true;
//         } else {
//             std.debug.print("Initialization failed. Make sure SQLite driver is available.\n", .{});
//             std.debug.print("You may need to install SQLite and ensure it's properly configured.\n", .{});
//             return;
//         }
//     }

//     // Only proceed if initialization was successful
//     if (init_success) {
//         // Check if we're logged in before trying to connect
//         var is_logged_in = c.IsLoggedIn() != 0;
//         std.debug.print("Logged in (before connect): {}\n", .{is_logged_in});

//         // Connect to WhatsApp - this will determine our path
//         var need_qr_code = false;
//         {
//             const result = c.Connect();
//             defer std.c.free(result);
//             std.debug.print("Connection result: {s}\n", .{result});

//             if (std.mem.indexOf(u8, std.mem.span(result), "Not logged in") != null) {
//                 // We need a fresh QR code - no existing session
//                 need_qr_code = true;
//             } else if (std.mem.indexOf(u8, std.mem.span(result), "Error") != null) {
//                 std.debug.print("Connection failed: {s}\n", .{result});
//                 return;
//             } else {
//                 // Connected successfully or with existing session
//                 is_logged_in = c.IsConnected() != 0;
//                 if (is_logged_in) {
//                     std.debug.print("Connected to WhatsApp successfully!\n", .{});
//                 } else {
//                     std.debug.print("Connected but not logged in. Unexpected state.\n", .{});
//                     return;
//                 }
//             }
//         }

//         // Handle QR code login if needed
//         if (need_qr_code) {
//             std.debug.print("Getting QR code for new login...\n", .{});
//             const qr_code = c.GetQRCode();
//             defer std.c.free(qr_code);

//             const qr_result = std.mem.span(qr_code);
//             std.debug.print("QR Code result: {s}\n", .{qr_result});

//             if (std.mem.indexOf(u8, qr_result, "Error") != null) {
//                 std.debug.print("Failed to get QR code: {s}\n", .{qr_result});
//                 return;
//             }

//             // Poll for QR code status until it's ready
//             var qr_ready = false;
//             var attempts: usize = 0;
//             const max_attempts = 30;

//             std.debug.print("Waiting for QR code...\n", .{});
//             while (!qr_ready and attempts < max_attempts) {
//                 std.time.sleep(500 * std.time.ns_per_ms);

//                 const status = c.GetQRStatus();
//                 defer std.c.free(status);

//                 const status_str = std.mem.span(status);
//                 if (std.mem.indexOf(u8, status_str, "QR Code (scan with WhatsApp)") != null) {
//                     std.debug.print("\n{s}\n", .{status_str});
//                     qr_ready = true;
//                 } else {
//                     std.debug.print(".", .{});
//                     attempts += 1;
//                 }
//             }

//             if (!qr_ready) {
//                 std.debug.print("\nQR code not received in time. Please try again.\n", .{});
//                 return;
//             }

//             std.debug.print("\nPlease scan the QR code with your WhatsApp mobile app\n", .{});
//             std.debug.print("Press Enter after scanning QR code...\n", .{});
//             _ = try std.io.getStdIn().reader().readByte();

//             // Check if login was successful after scanning
//             is_logged_in = c.IsConnected() != 0;
//             if (is_logged_in) {
//                 std.debug.print("Successfully logged in!\n", .{});
//             } else {
//                 std.debug.print("Login unsuccessful. Please try again.\n", .{});
//                 return;
//             }
//         }

//         std.debug.print("Ensuring connection is stable...\n", .{});
//         while (c.IsLoggedIn() != 1) {
//             std.Thread.sleep(50 * std.time.ns_per_ms);
//         }

//         // Final login check before proceeding
//         is_logged_in = c.IsLoggedIn() != 0;
//         std.debug.print("Logged in (final check): {}\n", .{is_logged_in});

//         if (!is_logged_in) {
//             std.debug.print("Not logged in. Exiting.\n", .{});
//             return;
//         }

//         // Send message example
//         std.debug.print("\n--- WhatsApp Messaging ---\n", .{});

//         // Get phone number from args or prompt
//         var phone_buf: [20]u8 = undefined;
//         var phone: []const u8 = undefined;

//         if (recipient_from_args) |recipient| {
//             phone = recipient;
//             std.debug.print("Using recipient from arguments: {s}\n", .{phone});
//         } else {
//             std.debug.print("Enter recipient phone number (numbers only, e.g., 1234567890): ", .{});
//             phone = try std.io.getStdIn().reader().readUntilDelimiter(&phone_buf, '\n');
//         }

//         // Format the JID correctly with null termination
//         var recipient_buf: [50]u8 = undefined;
//         const recipient = try std.fmt.bufPrintZ(&recipient_buf, "{s}@s.whatsapp.net", .{phone});

//         // Get message from args or prompt
//         var message_buf: [1000]u8 = undefined;
//         var message_input: []const u8 = undefined;

//         if (message_from_args) |message| {
//             message_input = message;
//             std.debug.print("Using message from arguments: {s}\n", .{message_input});
//         } else {
//             std.debug.print("Enter message: ", .{});
//             message_input = try std.io.getStdIn().reader().readUntilDelimiter(&message_buf, '\n');
//         }

//         // Create a null-terminated copy of the message
//         var message_with_null: [1001]u8 = undefined;
//         @memcpy(message_with_null[0..message_input.len], message_input);
//         message_with_null[message_input.len] = 0; // Add null terminator

//         std.debug.print("Sending message to {s}...\n", .{recipient});
//         const send_result = c.SendMessage(@ptrCast(recipient.ptr), @ptrCast(&message_with_null[0]));
//         defer std.c.free(send_result);
//         std.debug.print("Message result: {s}\n", .{send_result});

//         // Disconnect when done
//         {
//             const result = c.Disconnect();
//             defer std.c.free(result);
//             std.debug.print("Disconnect result: {s}\n", .{result});
//         }
//     }
// }

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
    //  catch |err| {
    //     std.debug.print("Failed to connect: {}\n", .{err});
    //     return;
    // };

    std.debug.print("Checking connection...\n", .{});
    const isConnected = client.isConnected();
    std.debug.print("Is connected? {}\n", .{isConnected});
}
