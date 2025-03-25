const std = @import("std");
const Allocator = std.mem.Allocator;
const Bundle = std.crypto.Certificate.Bundle;

pub fn loadSystemCertificates(allocator: Allocator) !Bundle {
    var b = Bundle{};
    try b.rescan(allocator);

    return b;
}
