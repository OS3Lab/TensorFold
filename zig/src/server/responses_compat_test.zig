//! Responses tool inventory, choice and replay preserve the caller's identities.
const std = @import("std");
const json = @import("json.zig");
const errors = @import("errors.zig");
const compat = @import("responses_compat.zig");
const translate = @import("responses_translate.zig");
const expect = std.testing.expect;
const eq = std.testing.expectEqualStrings;

fn parse(a: std.mem.Allocator, text: []const u8) !json.Value {
    return (try json.parse(a, text)).ok;
}

test "same function in two namespaces stays distinct through choice and historical calls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cx: errors.Cx = .{ .a = a };
    const body = try parse(a,
        \\{"tools":[{"type":"namespace","name":"a","tools":[{"type":"function","name":"lookup"}]},{"type":"namespace","name":"b","tools":[{"type":"function","name":"lookup"}]}],"tool_choice":{"type":"function","namespace":"b","name":"lookup"},"input":[{"type":"function_call","namespace":"a","name":"lookup","call_id":"c1","arguments":"{}"}]}
    );
    const p = try compat.prepare(&cx, body);
    try eq("a__lookup", p.body.get("tools").?.array[0].strField("name").?);
    try eq("b__lookup", p.body.get("tool_choice").?.strField("name").?);
    const binding = p.find("b__lookup").?;
    try eq("lookup", binding.name);
    try eq("b", binding.namespace.?);
    const history = try translate.messages(&cx, p.body.get("input").?.array);
    const function = history[0].get("tool_calls").?.array[0].get("function").?;
    try eq("a__lookup", function.strField("name").?);
    try eq("lookup", body.get("input").?.array[0].strField("name").?);
}

test "custom freeform inputs preserve escaped text through history and the function wrapper" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cx: errors.Cx = .{ .a = a };
    const body = try parse(a,
        \\{"tools":[{"type":"namespace","name":"functions","tools":[{"type":"custom","name":"apply_patch","format":{"type":"grammar","syntax":"lark","definition":"start: /.+/"}}]}],"input":[{"type":"custom_tool_call","namespace":"functions","name":"apply_patch","call_id":"c","input":"line 1\n\"quoted\"\\end"},{"type":"custom_tool_call_output","call_id":"c","output":"ok"}]}
    );
    const p = try compat.prepare(&cx, body);
    try expect(p.find("functions__apply_patch").?.custom);
    const tool = p.body.get("tools").?.array[0];
    try expect(tool.typeIs("function"));
    try expect(tool.get("parameters").?.get("properties").?.get("input").?.typeIs("string"));
    const history = try translate.messages(&cx, p.body.get("input").?.array);
    const function = history[0].get("tool_calls").?.array[0].get("function").?;
    try eq("functions__apply_patch", function.strField("name").?);
    try eq("line 1\n\"quoted\"\\end", try compat.customInput(&cx, function.strField("arguments").?));
    try eq("tool", history[1].strField("role").?);
    try eq("ok", history[1].strField("content").?);
}

test "ambiguous flattened names and malformed inventories fail before generation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cx: errors.Cx = .{ .a = a };
    for ([_][]const u8{
        \\{"tools":[{"type":"function","name":"a__b"},{"type":"namespace","name":"a","tools":[{"type":"function","name":"b"}]}]}
        ,
        \\{"tools":[{"type":"namespace","name":"a","tools":[]}]}
        ,
        \\{"tools":[{"type":"namespace","name":"a","tools":[{"type":"web_search"}]}]}
        ,
        \\{"tools":[{"type":"namespace","name":"a"}]}
    }) |text| try std.testing.expectError(error.Refused, compat.prepare(&cx, try parse(a, text)));
}

test "allowed_tools namespace selects every member and leaves the original choice unchanged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cx: errors.Cx = .{ .a = a };
    const body = try parse(a,
        \\{"tools":[{"type":"namespace","name":"a","tools":[{"type":"function","name":"one"},{"type":"custom","name":"two"}]}],"tool_choice":{"type":"allowed_tools","mode":"required","tools":[{"type":"namespace","name":"a"}]}}
    );
    const p = try compat.prepare(&cx, body);
    const tools = p.body.get("tool_choice").?.get("tools").?.array;
    try std.testing.expectEqual(@as(usize, 2), tools.len);
    try eq("a__one", tools[0].strField("name").?);
    try eq("a__two", tools[1].strField("name").?);
    try expect(body.get("tool_choice").?.get("tools").?.array[0].typeIs("namespace"));
}

test "include accepts known optional outputs but not unknown values or malformed lists" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cx: errors.Cx = .{ .a = a };
    try translate.include(&cx, try parse(a, "[\"reasoning.encrypted_content\"]"));
    try std.testing.expectError(error.Refused, translate.include(&cx, try parse(a, "[\"reasoning.invalid\"]")));
    try std.testing.expectError(error.Refused, translate.include(&cx, try parse(a, "\"reasoning.encrypted_content\"")));
    try std.testing.expectError(error.Refused, compat.customInput(&cx, "{\"input\":12}"));
    try std.testing.expectError(error.Refused, compat.customInput(&cx, "{\"input\":\"unterminated"));
}
