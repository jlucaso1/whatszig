const std = @import("std");
const json = std.json;

pub const JsonError = error{
    JsonParseError,
};

pub fn extractString(data: json.Value, key: []const u8) ![]const u8 {
    if (data != .object) {
        return JsonError.JsonParseError;
    }

    return if (data.object.get(key)) |value|
        if (value == .string) value.string else return JsonError.JsonParseError
    else
        return JsonError.JsonParseError;
}
