const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn decodeBase64(allocator: Allocator, input: []const u8) ![]u8 {
    // Calculate max size needed (4 base64 chars → 3 bytes)
    const max_len = input.len * 3 / 4 + 3;
    var buffer = try allocator.alloc(u8, max_len);
    errdefer allocator.free(buffer);

    // Clean input if needed and add proper padding
    const clean_input = try ensureValidBase64(allocator, input);
    defer allocator.free(clean_input);

    // Decode base64
    const decoded_len = try std.base64.standard.Decoder.calcSizeForSlice(clean_input);
    try std.base64.standard.Decoder.decode(buffer[0..decoded_len], clean_input);

    // Resize to actual content length
    return allocator.realloc(buffer, decoded_len);
}

pub fn ensureValidBase64(allocator: Allocator, input: []const u8) ![]const u8 {
    // First clean the input of any invalid characters
    var clean_buffer = try allocator.alloc(u8, input.len);
    errdefer allocator.free(clean_buffer);

    var clean_len: usize = 0;
    for (input) |char| {
        // Only keep valid base64 characters
        if ((char >= 'A' and char <= 'Z') or
            (char >= 'a' and char <= 'z') or
            (char >= '0' and char <= '9') or
            char == '+' or char == '/' or char == '=')
        {
            clean_buffer[clean_len] = char;
            clean_len += 1;
        }
    }

    // Use realloc instead of shrink to resize the buffer
    const clean_input = try allocator.realloc(clean_buffer, clean_len);

    // Now add padding if needed
    if (clean_len % 4 == 0) return clean_input;

    const padding_needed = 4 - (clean_len % 4);
    var padded = try allocator.alloc(u8, clean_len + padding_needed);
    @memcpy(padded[0..clean_len], clean_input);

    // Free the clean input since we've copied it
    allocator.free(clean_input);

    // Add padding characters
    for (0..padding_needed) |i| {
        padded[clean_len + i] = '=';
    }

    return padded;
}
