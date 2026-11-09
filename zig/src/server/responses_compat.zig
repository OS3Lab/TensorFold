//! Responses tool groups and custom inputs translated to the engine's ordinary function tools.
const std = @import("std");
const json = @import("json.zig");
const errors = @import("errors.zig");
const Value = json.Value;
const Cx = errors.Cx;

pub const Binding = struct {
    internal: []const u8,
    name: []const u8,
    namespace: ?[]const u8,
    custom: bool,
};

pub const Prepared = struct {
    body: Value,
    bindings: []Binding,

    pub fn find(p: Prepared, name: []const u8) ?Binding {
        for (p.bindings) |b| if (std.mem.eql(u8, b.internal, name)) return b;
        return null;
    }
};

fn named(cx: *Cx, value: Value, key: []const u8) errors.Refused![]const u8 {
    const name = value.strField(key) orelse return cx.fail(.request, "a tool's {s} must be a non-empty string", .{key});
    if (name.len == 0) return cx.fail(.request, "a tool's {s} must be a non-empty string", .{key});
    return name;
}

fn namespaceOf(cx: *Cx, value: Value) errors.Refused!?[]const u8 {
    const n = value.get("namespace") orelse return null;
    if (n == .null) return null;
    if (n != .string or n.string.len == 0) return cx.refuse("namespace must be a non-empty string");
    return n.string;
}

fn qualified(cx: *Cx, namespace: ?[]const u8, name: []const u8) errors.Refused![]const u8 {
    return if (namespace) |n| try std.mem.concat(cx.a, u8, &.{ n, "__", name }) else name;
}

fn addTool(cx: *Cx, tool: Value, namespace: ?[]const u8, group_description: ?[]const u8, flat: *std.ArrayList(Value), bindings: *std.ArrayList(Binding)) errors.Refused!void {
    const kind = tool.strField("type") orelse return cx.refuse("each tool needs a type");
    const custom = std.mem.eql(u8, kind, "custom");
    if (!custom and !std.mem.eql(u8, kind, "function"))
        return cx.fail(.request, "tools of type '{s}' are not supported: use function, custom or namespace tools", .{kind});
    const name = try named(cx, tool, "name");
    const internal = try qualified(cx, namespace, name);
    for (bindings.items) |b| if (std.mem.eql(u8, b.internal, internal))
        return cx.fail(.request, "tool name collision after namespace expansion: '{s}'", .{internal});
    const t = try json.copyObject(cx.a, tool.object);
    try t.put(cx.a, "name", .{ .string = internal });
    try t.put(cx.a, "type", .{ .string = "function" });
    if (group_description) |description| if (description.len > 0) {
        const own = tool.strField("description") orelse "";
        try t.put(cx.a, "description", .{ .string = try std.mem.concat(cx.a, u8, &.{ "Tool group: ", description, "\n", own }) });
    };
    if (custom) {
        const input = try json.newObject(cx.a);
        try input.put(cx.a, "type", .{ .string = "string" });
        var description: []const u8 = "The exact raw input for this custom tool, as a JSON string. Preserve newlines and all tool syntax.";
        if (tool.get("format")) |format| {
            const format_type = format.strField("type") orelse return cx.refuse("custom tool format needs a type");
            if (std.mem.eql(u8, format_type, "grammar")) {
                const syntax = format.strField("syntax") orelse return cx.refuse("custom tool grammar needs syntax");
                const definition = format.strField("definition") orelse return cx.refuse("custom tool grammar needs definition");
                description = try std.mem.concat(cx.a, u8, &.{ description, "\nThe input must follow this ", syntax, " grammar:\n", definition });
            } else if (!std.mem.eql(u8, format_type, "text")) return cx.refuse("custom tool format must be text or grammar");
        }
        try input.put(cx.a, "description", .{ .string = description });
        const properties = try json.newObject(cx.a);
        try properties.put(cx.a, "input", .{ .object = input });
        const parameters = try json.newObject(cx.a);
        try parameters.put(cx.a, "type", .{ .string = "object" });
        try parameters.put(cx.a, "properties", .{ .object = properties });
        const required = try cx.a.alloc(Value, 1);
        required[0] = .{ .string = "input" };
        try parameters.put(cx.a, "required", .{ .array = required });
        try parameters.put(cx.a, "additionalProperties", .{ .bool = false });
        try t.put(cx.a, "parameters", .{ .object = parameters });
    }
    try flat.append(cx.a, .{ .object = t });
    try bindings.append(cx.a, .{ .internal = internal, .name = name, .namespace = namespace, .custom = custom });
}

fn choice(cx: *Cx, raw: Value, bindings: []const Binding) errors.Refused!Value {
    if (raw != .object) return raw;
    const kind = raw.strField("type") orelse return raw;
    if (std.mem.eql(u8, kind, "function") or std.mem.eql(u8, kind, "custom")) {
        const name = try qualified(cx, try namespaceOf(cx, raw), try named(cx, raw, "name"));
        const out = try json.copyObject(cx.a, raw.object);
        try out.put(cx.a, "name", .{ .string = name });
        try out.put(cx.a, "type", .{ .string = "function" });
        return .{ .object = out };
    }
    if (!std.mem.eql(u8, kind, "allowed_tools")) return raw;
    const given = raw.get("tools") orelse return cx.refuse("allowed_tools needs a tools list");
    if (given != .array) return cx.refuse("allowed_tools needs a tools list");
    var tools: std.ArrayList(Value) = .empty;
    for (given.array) |tool| {
        if (tool.typeIs("namespace")) {
            const namespace = try named(cx, tool, "name");
            var found = false;
            for (bindings) |b| if (b.namespace != null and std.mem.eql(u8, b.namespace.?, namespace)) {
                const t = try json.newObject(cx.a);
                try t.put(cx.a, "type", .{ .string = "function" });
                try t.put(cx.a, "name", .{ .string = b.internal });
                try tools.append(cx.a, .{ .object = t });
                found = true;
            };
            if (!found) return cx.fail(.request, "allowed_tools names unknown namespace '{s}'", .{namespace});
        } else try tools.append(cx.a, try choice(cx, tool, bindings));
    }
    const out = try json.copyObject(cx.a, raw.object);
    try out.put(cx.a, "tools", .{ .array = tools.items });
    return .{ .object = out };
}

/// Tool-call input items use the same qualified names, including when their definitions are no longer offered.
pub fn history(cx: *Cx, items: []const Value) errors.Refused![]Value {
    const out = try cx.a.alloc(Value, items.len);
    for (items, out) |item, *to| {
        to.* = item;
        if (item.typeIs("function_call") or item.typeIs("custom_tool_call")) {
            const obj = try json.copyObject(cx.a, item.object);
            const name = try qualified(cx, try namespaceOf(cx, item), try named(cx, item, "name"));
            _ = obj.swapRemove("namespace");
            try obj.put(cx.a, "name", .{ .string = name });
            if (item.typeIs("custom_tool_call")) {
                const input = item.strField("input") orelse return cx.refuse("a custom_tool_call needs a string input");
                const arguments = try json.newObject(cx.a);
                try arguments.put(cx.a, "input", .{ .string = input });
                try obj.put(cx.a, "type", .{ .string = "function_call" });
                try obj.put(cx.a, "arguments", .{ .string = try json.stringify(cx.a, .{ .object = arguments }, .{}) });
            }
            to.* = .{ .object = obj };
        } else if (item.typeIs("custom_tool_call_output")) {
            const obj = try json.copyObject(cx.a, item.object);
            try obj.put(cx.a, "type", .{ .string = "function_call_output" });
            to.* = .{ .object = obj };
        }
    }
    return out;
}

pub fn prepare(cx: *Cx, body: Value) errors.Refused!Prepared {
    if (body != .object) return cx.refuse("the request body must be a JSON object");
    const obj = try json.copyObject(cx.a, body.object);
    var flat: std.ArrayList(Value) = .empty;
    var bindings: std.ArrayList(Binding) = .empty;
    if (body.get("tools")) |tools| if (tools != .null) {
        if (tools != .array) return cx.refuse("tools must be a list");
        for (tools.array) |tool| {
            if (tool.typeIs("namespace")) {
                const namespace = try named(cx, tool, "name");
                const children = tool.get("tools") orelse return cx.refuse("a namespace tool needs a tools list");
                if (children != .array or children.array.len == 0) return cx.refuse("a namespace tool needs a non-empty tools list");
                for (children.array) |child| try addTool(cx, child, namespace, tool.strField("description"), &flat, &bindings);
            } else try addTool(cx, tool, null, null, &flat, &bindings);
        }
        try obj.put(cx.a, "tools", .{ .array = flat.items });
    };
    if (body.get("input")) |input| if (input == .array) try obj.put(cx.a, "input", .{ .array = try history(cx, input.array) });
    if (body.get("tool_choice")) |raw| try obj.put(cx.a, "tool_choice", try choice(cx, raw, bindings.items));
    return .{ .body = .{ .object = obj }, .bindings = bindings.items };
}

/// Decode the function wrapper only after the complete JSON arguments have arrived.
pub fn customInput(cx: *Cx, arguments: []const u8) errors.Refused![]const u8 {
    const parsed = switch (try json.parse(cx.a, arguments)) {
        .ok => |v| v,
        .err => return cx.refuse("custom tool arguments are not complete JSON"),
    };
    return parsed.strField("input") orelse return cx.refuse("custom tool arguments need a string input");
}
