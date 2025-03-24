const std = @import("std");
const c = @cImport({
    @cInclude("libwhatsapp.h");
});

pub fn main() !void {
    // Initialize WhatsApp client
    var init_success = false;
    {
        const result = c.Initialize();
        defer std.c.free(result);
        std.debug.print("Initialization result: {s}\n", .{result});

        // Check if initialization was successful
        if (std.mem.indexOf(u8, std.mem.span(result), "Error") == null) {
            init_success = true;
        } else {
            std.debug.print("Initialization failed. Make sure SQLite driver is available.\n", .{});
            std.debug.print("You may need to install SQLite and ensure it's properly configured.\n", .{});
            return;
        }
    }

    // Only proceed if initialization was successful
    if (init_success) {
        // Connect to WhatsApp
        {
            const result = c.Connect();
            defer std.c.free(result);
            std.debug.print("Connection result: {s}\n", .{result});

            // Check if connection was successful
            if (std.mem.indexOf(u8, std.mem.span(result), "Error") != null) {
                std.debug.print("Connection failed.\n", .{});
                return;
            }
        }

        // Check if we're logged in
        const logged_in = c.IsLoggedIn();
        const is_logged_in = logged_in != 0; // Convert u8 to bool
        std.debug.print("Logged in: {}\n", .{is_logged_in});

        if (!is_logged_in) {
            // Get QR code for login
            const qr_code = c.GetQRCode();
            defer std.c.free(qr_code);

            if (std.mem.indexOf(u8, std.mem.span(qr_code), "Error") == null) {
                std.debug.print("\n\n{s}\n\n", .{qr_code});

                // Wait for user to scan QR code
                std.debug.print("Press Enter after scanning QR code...\n", .{});
                _ = try std.io.getStdIn().reader().readByte();

                // Check if login was successful after scanning
                const logged_in_after_scan = c.IsLoggedIn();
                if (logged_in_after_scan != 0) {
                    std.debug.print("Successfully logged in!\n", .{});
                } else {
                    std.debug.print("Login unsuccessful. Please try again.\n", .{});
                    return;
                }
            } else {
                std.debug.print("Failed to get QR code: {s}\n", .{qr_code});
                return;
            }
        }

        // Send message example (if logged in)
        if (is_logged_in) {
            std.debug.print("Enter recipient (format: 1234567890@s.whatsapp.net): ", .{});
            var recipient_buf: [100]u8 = undefined;
            const recipient = try std.io.getStdIn().reader().readUntilDelimiter(&recipient_buf, '\n');

            std.debug.print("Enter message: ", .{});
            var message_buf: [1000]u8 = undefined;
            const message = try std.io.getStdIn().reader().readUntilDelimiter(&message_buf, '\n');

            const send_result = c.SendMessage(@ptrCast(recipient.ptr), @ptrCast(message.ptr));
            defer std.c.free(send_result);
            std.debug.print("Message result: {s}\n", .{send_result});
        }

        // Disconnect when done
        {
            const result = c.Disconnect();
            defer std.c.free(result);
            std.debug.print("Disconnect result: {s}\n", .{result});
        }
    }
}
