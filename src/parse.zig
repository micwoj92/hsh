const std = @import("std");
const log = @import("log");
const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const mem = std.mem;
const tokenizer = @import("tokenizer.zig");
const Tokenizer = tokenizer.Tokenizer;
const Token = tokenizer.Token;
const TokenIterator = tokenizer.TokenIterator;
const Builtins = @import("builtins.zig");
const Aliases = Builtins.Aliases;
const Variables = @import("variables.zig");
const fs = @import("fs.zig");
const exec = @import("exec.zig");

pub const Error = error{
    Unknown,
    Memory,
    ParseFailed,
    OpenGroup,
    Empty,
};

/// In effect a duplicate of std.mem.split iterator
pub const ParsedIterator = struct {
    // I hate that this requires an allocator :( but the ratio of thinking
    // to writing is already too high
    alloc: *Allocator,
    tokens: []Token,
    index: ?usize,
    subtokens: ?[]TokenIterator,
    resolved: [][]const u8,
    const Self = @This();

    /// Restart iterator, and assumes length >= 1
    pub fn first(self: *Self) *const Token {
        self.restart();
        return self.next().?;
    }

    /// Returns next Token, omitting, or splitting them as needed.
    pub fn next(self: *Self) ?*const Token {
        const i = self.index orelse return null;
        if (i >= self.tokens.len) {
            self.restart();
            self.index = null;
            return null;
        }

        const token = &self.tokens[i];
        if (self.subtokens) |_| return self.nextSubtoken(token);

        if (i == 0 and token.kind == .word) {
            if (self.nextSubtoken(token)) |tk| return tk;
            return token;
        } else {
            switch (token.kind) {
                .ws, .io, .oper => {
                    self.index.? += 1;
                    return self.next();
                },
                else => {
                    if (self.nextSubtoken(token)) |tk| return tk;
                },
            }
        }
        defer self.index.? += 1;
        return token;
    }

    fn subtokensDel(self: *Self) bool {
        if (self.subtokens) |subtkns| {
            const l = subtkns.len;
            self.alloc.free(subtkns[0].raw);
            for (subtkns[0 .. l - 1], subtkns[1..]) |*dst, src| {
                dst.* = src;
            }
            self.subtokens = self.alloc.realloc(subtkns, subtkns.len - 1) catch unreachable;
        }
        if (self.subtokens) |st| {
            return st.len > 0;
        }
        return false;
    }

    fn subtokensDupe(self: *Self, str: []const u8) !void {
        const raw = try self.alloc.dupe(u8, str);
        return self.subtokensAdd(raw);
    }

    fn subtokensAddSingle(self: *Self, str: []const u8) !void {
        if (std.mem.indexOfAny(u8, str, " \t") == null) {
            return self.subtokensDupe(str);
        }

        // TODO all breaking tokens
        if (std.mem.indexOf(u8, str, "'")) |_| {
            try self.subtokensDupe(str);
            return;
        }
        var blob = try self.alloc.alloc(u8, str.len + 2);
        @memcpy(blob[1 .. blob.len - 1], str);
        blob[0] = '\'';
        blob[blob.len - 1] = '\'';
        try self.subtokensAdd(blob);
    }

    fn subtokensAdd(self: *Self, str: []u8) !void {
        if (self.subtokens) |sub| {
            self.subtokens = try self.alloc.realloc(sub, sub.len + 1);
        } else {
            self.subtokens = try self.alloc.alloc(TokenIterator, 1);
        }
        self.subtokens.?[self.subtokens.?.len - 1] = TokenIterator{ .raw = str };
    }

    fn nextSubtoken(self: *Self, token: *const Token) ?*const Token {
        if (self.subtokens) |subtkns| {
            if (subtkns.len == 0) {
                self.subtokens = null;
                self.index.? += 1;
                return self.next();
            }

            if (subtkns[0].next()) |n| {
                return n;
            } else {
                _ = self.subtokensDel();
                return self.nextSubtoken(token);
            }
        } else {
            self.resolve(token);
            if (self.subtokens) |sts| {
                return sts[0].first();
            }
            defer self.index.? += 1;
            return token;
        }
    }

    fn resolvedAdd(self: *Self, str: []const u8) void {
        self.resolved = self.alloc.realloc(self.resolved, self.resolved.len + 1) catch unreachable;
        self.resolved[self.resolved.len - 1] = str;
    }

    fn resolve(self: *Self, token: *const Token) void {
        if (self.index) |index| {
            if (index == 0) {
                return self.resolveAlias(token);
            } else {
                return self.resolveWord(token);
            }
        }
    }

    fn resolveAlias(self: *Self, token: *const Token) void {
        for (self.resolved) |res| {
            if (std.mem.eql(u8, token.cannon(), res)) {
                return;
            }
        }
        self.resolvedAdd(token.cannon());
        if (Parser.alias(token)) |als| {
            self.subtokensDupe(als) catch unreachable;
            var owned = &self.subtokens.?[self.subtokens.?.len - 1];
            self.resolve(owned.*.first());
        } else |e| {
            if (e != Error.Empty) {
                std.debug.print("alias errr {}\n", .{e});
                unreachable;
            }
        }
    }

    fn resolveWord(self: *Self, t: *const Token) void {
        var local = t.*;
        if (std.mem.indexOf(u8, local.cannon(), "$") != null or local.kind == .vari) {
            var skip: usize = 0;
            var list = std.ArrayList(u8).init(self.alloc.*);
            for (t.str, 0..) |c, i| {
                if (skip > 0) {
                    skip -|= 1;
                    continue;
                }
                switch (c) {
                    '$' => {
                        var vari = Tokenizer.vari(t.str[i..]) catch {
                            list.append(c) catch unreachable;
                            continue;
                        };
                        skip = vari.str.len - 1;
                        const res = Parser.single(self.alloc, &vari) catch continue;
                        if (res.resolved) |str| {
                            list.appendSlice(str) catch unreachable;
                            self.alloc.free(str);
                        } else {
                            list.appendSlice(res.cannon()) catch unreachable;
                        }
                    },
                    else => list.append(c) catch unreachable,
                }
            }
            const owned = list.toOwnedSlice() catch unreachable;

            self.subtokensAdd(owned) catch unreachable;
        } else if (std.mem.indexOf(u8, local.cannon(), "*")) |_| {
            _ = Parser.single(self.alloc, &local) catch unreachable;
            defer if (local.resolved) |r| self.alloc.free(r);
            return self.resolveGlob(&local);
        } else {
            _ = Parser.single(self.alloc, &local) catch unreachable;
            defer if (local.resolved) |r| self.alloc.free(r);
            self.subtokensAddSingle(local.cannon()) catch unreachable;
        }
    }

    fn resolveGlob(self: *Self, token: *const Token) void {
        if (std.mem.indexOf(u8, token.cannon(), "*")) |_| {} else return;

        if (std.mem.indexOf(u8, token.cannon(), "/")) |_| {
            var bitr = std.mem.splitBackwards(u8, token.cannon(), "/");
            var glob = bitr.first();
            var dir = bitr.rest();
            if (Parser.globAt(self.alloc, dir, glob)) |names| {
                for (names) |name| {
                    defer self.alloc.free(name);
                    if (!std.mem.startsWith(u8, token.cannon(), ".") and
                        std.mem.startsWith(u8, name, "."))
                    {
                        continue;
                    }
                    var path = std.mem.join(self.alloc.*, "/", &[2][]const u8{ dir, name }) catch unreachable;
                    defer self.alloc.free(path);
                    self.subtokensAddSingle(path) catch unreachable;
                }
                self.alloc.free(names);
            } else |e| {
                if (e != Error.Empty) {
                    std.debug.print("error resolving glob {}\n", .{e});
                    unreachable;
                }
            }
        } else {
            if (Parser.glob(self.alloc, token.cannon())) |names| {
                for (names) |name| {
                    if (!std.mem.startsWith(u8, token.cannon(), ".") and
                        std.mem.startsWith(u8, name, "."))
                    {
                        self.alloc.free(name);
                        continue;
                    }
                    self.subtokensAdd((name)) catch unreachable;
                }
                self.alloc.free(names);
            } else |e| {
                if (e != Error.Empty) {
                    std.debug.print("error resolving glob {}\n", .{e});
                    unreachable;
                }
            }
        }
    }

    /// Resets the iterator to the initial slice.
    pub fn restart(self: *Self) void {
        self.index = 0;
        if (self.resolved.len > 0) {
            self.alloc.free(self.resolved);
        }
        self.resolved = self.alloc.alloc([]u8, 0) catch @panic("Alloc 0 can't fail");
        while (self.subtokensDel()) {}
        self.subtokens = null;
        for (self.tokens) |*t| {
            if (t.resolved) |r| {
                self.alloc.free(r);
                t.resolved = null;
            }
        }
    }

    /// Alias for restart to free stored memory
    pub fn close(self: *Self) void {
        self.restart();
    }
};

pub const Parser = struct {
    alloc: Allocator,

    pub fn parse(a: *Allocator, tokens: []Token) Error!ParsedIterator {
        if (tokens.len == 0) return Error.Empty;
        return ParsedIterator{
            .alloc = a,
            .tokens = tokens,
            .index = 0,
            .subtokens = null,
            .resolved = a.alloc([]u8, 0) catch return Error.Memory,
        };
    }

    pub fn single(a: *Allocator, token: *Token) Error!*Token {
        if (token.str.len == 0) return token;

        switch (token.kind) {
            .quote => {
                var needle = [2]u8{ '\\', token.subtoken };
                if (mem.indexOfScalar(u8, token.str, '\\')) |_| {} else return token;

                var i: usize = 0;
                var backing = ArrayList(u8).init(a.*);
                backing.appendSlice(token.cannon()) catch return Error.Memory;
                while (i + 1 < backing.items.len) : (i += 1) {
                    if (backing.items[i] == '\\') {
                        if (mem.indexOfAny(u8, backing.items[i + 1 .. i + 2], &needle)) |_| {
                            _ = backing.orderedRemove(i);
                        }
                    }
                }
                token.resolved = backing.toOwnedSlice() catch return Error.Memory;
                return token;
            },
            .vari => {
                return try variable(a.*, token);
            },
            .word, .path => {
                return try word(a, token);
            },
            .subp => {
                if (token.parsed) return token;
                return try subcmd(token, a.*);
            },
            else => {
                switch (token.str[0]) {
                    '$' => return token,
                    else => return token,
                }
            },
        }
    }

    fn resolve(token: *Token) Error!*Token {
        _ = try alias(token);
        return token;
    }

    fn alias(token: *const Token) Error![]const u8 {
        if (Aliases.find(token.cannon())) |a| {
            return a.value;
        }
        return Error.Empty;
    }

    fn word(a: *Allocator, t: *Token) Error!*Token {
        std.debug.assert(t.resolved == null);
        var new = ArrayList(u8).init(a.*);
        var esc = false;
        for (t.cannon()) |c| {
            if (c == '\\' and !esc) {
                esc = true;
                continue;
            }
            esc = false;
            new.append(c) catch @panic("memory error");
        }
        t.resolved = new.toOwnedSlice() catch @panic("memory error");

        if (t.cannon()[0] == '~' or mem.indexOf(u8, t.cannon(), "/") != null) {
            t.kind = .path;
            return path(t, a.*);
        }

        return t;
    }

    /// Caller owns memory for both list of names, and each name
    fn globAt(a: *Allocator, d: []const u8, str: []const u8) Error![][]u8 {
        var dir = std.fs.openIterableDirAbsolute(d, .{}) catch return Error.Unknown;
        defer dir.close();
        return fs.globAt(a.*, dir, str) catch @panic("this error not implemented");
    }

    /// Caller owns memory for both list of names, and each name
    fn glob(a: *Allocator, str: []const u8) Error![][]u8 {
        return fs.globCwd(a.*, str) catch @panic("this error not implemented");
    }

    fn variable(a: std.mem.Allocator, tkn: *Token) Error!*Token {
        if (Variables.getStr(tkn.cannon())) |v| {
            tkn.resolved = a.dupe(u8, v) catch return Error.Memory;
        }
        return tkn;
    }

    fn path(t: *Token, a: std.mem.Allocator) Error!*Token {
        if (t.cannon()[0] != '~') return t;

        if (Variables.getStr("HOME")) |v| {
            var list: ArrayList(u8) = undefined;
            if (t.resolved) |r| {
                list = ArrayList(u8).fromOwnedSlice(a, r);
            } else {
                list = ArrayList(u8).init(a);
                list.appendSlice(t.cannon()) catch return Error.Memory;
            }

            list.replaceRange(0, 1, v) catch return Error.Memory;
            t.resolved = list.toOwnedSlice() catch return Error.Memory;
        }
        return t;
    }

    fn subcmd(tkn: *Token, a: std.mem.Allocator) Error!*Token {
        var cmd = tkn.str[2 .. tkn.str.len - 1];
        std.debug.assert(tkn.str[0] == '$');
        std.debug.assert(tkn.str[1] == '(');
        var itr = TokenIterator{ .raw = cmd };
        var argv_t = itr.toSlice(a) catch return Error.Memory;
        defer a.free(argv_t);
        var list = ArrayList([]const u8).init(a);
        for (argv_t) |t| {
            list.append(t.cannon()) catch return Error.Memory;
        }
        var argv = list.toOwnedSlice() catch return Error.Memory;
        defer a.free(argv);
        var out = exec.child(a, argv) catch @panic("child exec failed");

        tkn.parsed = true;
        tkn.resolved = std.mem.join(a, "\n", out.stdout) catch return Error.Memory;
        for (out.stdout) |line| a.free(line);
        a.free(out.stdout);
        return tkn;
    }
};

const expect = std.testing.expect;
const expectEql = std.testing.expectEqual;
const expectError = std.testing.expectError;
const eql = std.mem.eql;
const eqlStr = std.testing.expectEqualStrings;

test "iterator nows" {
    var a = std.testing.allocator;
    var t: Tokenizer = Tokenizer.init(std.testing.allocator);
    defer t.reset();

    try t.consumes("\"this is some text\" more text");
    var itr = t.iterator();
    var ts = try itr.toSlice(a);
    defer a.free(ts);
    var ptr = try Parser.parse(&a, ts);
    var i: usize = 0;
    while (ptr.next()) |_| {
        i += 1;
    }
    try expectEql(i, 3);
}

test "iterator alias is builtin" {
    var a = std.testing.allocator;

    var ts = [_]Token{
        Token{ .kind = .word, .str = "alias" },
    };

    var itr = try Parser.parse(&a, &ts);
    var i: usize = 0;
    while (itr.next()) |_| {
        i += 1;
    }
    try expectEql(i, 1);
    try std.testing.expectEqualStrings("alias", itr.first().cannon());
    try expect(itr.next() == null);
}

test "iterator aliased" {
    var a = std.testing.allocator;
    var als = Aliases.testing_setup(a);
    defer Aliases.raze(a);
    try als.append(Aliases.Alias{
        .name = a.dupe(u8, "la") catch unreachable,
        .value = a.dupe(u8, "ls -la") catch unreachable,
    });

    var ts = [_]Token{
        Token{ .kind = .word, .str = "la" },
        Token{ .kind = .ws, .str = " " },
        Token{ .kind = .word, .str = "src" },
    };

    var itr = try Parser.parse(&a, &ts);
    var i: usize = 0;
    while (itr.next()) |_| {
        i += 1;
    }
    try expectEql(i, 3);
    try expect(eql(u8, itr.first().cannon(), "ls"));
    try expect(eql(u8, itr.next().?.cannon(), "-la"));
    try expect(eql(u8, itr.next().?.cannon(), "src"));
    try expect(itr.next() == null);
}

test "iterator aliased self" {
    var a = std.testing.allocator;
    var als = Aliases.testing_setup(a);
    defer Aliases.raze(a);
    try als.append(Aliases.Alias{
        .name = a.dupe(u8, "ls") catch unreachable,
        .value = a.dupe(u8, "ls -la") catch unreachable,
    });

    var ts = [_]Token{
        Token{ .kind = .word, .str = "ls" },
        Token{ .kind = .ws, .str = " " },
        Token{ .kind = .word, .str = "src" },
    };

    var itr = try Parser.parse(&a, &ts);
    var i: usize = 0;
    while (itr.next()) |_| {
        //std.debug.print("{}\n", .{t});
        i += 1;
    }
    try expectEql(i, 3);
    try expect(eql(u8, itr.first().cannon(), "ls"));
    try expect(eql(u8, itr.next().?.cannon(), "-la"));
    try std.testing.expectEqualStrings("src", itr.next().?.cannon());
    try expect(itr.next() == null);
}

test "iterator aliased recurse" {
    var a = std.testing.allocator;
    var als = Aliases.testing_setup(a);
    defer Aliases.raze(a);
    try als.append(Aliases.Alias{
        .name = a.dupe(u8, "la") catch unreachable,
        .value = a.dupe(u8, "ls -la") catch unreachable,
    });

    try als.append(Aliases.Alias{
        .name = a.dupe(u8, "ls") catch unreachable,
        .value = a.dupe(u8, "ls --color=auto") catch unreachable,
    });

    var ts = [_]Token{
        Token{ .kind = .word, .str = "la" },
        Token{ .kind = .ws, .str = " " },
        Token{ .kind = .word, .str = "src" },
    };

    var itr = try Parser.parse(&a, &ts);
    var i: usize = 0;
    while (itr.next()) |_| {
        //std.debug.print("{}\n", .{t});
        i += 1;
    }
    try expectEql(i, 4);
    var first = itr.first().cannon();
    try expect(eql(u8, first, "ls"));
    try expect(eql(u8, itr.next().?.cannon(), "-la"));
    try expect(eql(u8, itr.next().?.cannon(), "--color=auto"));
    try expect(eql(u8, itr.next().?.cannon(), "src"));
    try expect(itr.next() == null);
}

test "parse vars" {
    var a = std.testing.allocator;

    comptime var ts = [3]Token{
        try Tokenizer.any("echo"),
        try Tokenizer.any("$string"),
        try Tokenizer.any("blerg"),
    };

    var itr = try Parser.parse(&a, &ts);
    defer itr.close();
    var i: usize = 0;
    while (itr.next()) |_| {
        //std.debug.print("{}\n", .{t_});
        i += 1;
    }
    try expectEql(i, 3);
    var first = itr.first().cannon();
    try eqlStr("echo", first);
    var tst = itr.next();
    try eqlStr("string", tst.?.cannon());
    //try expect(itr.next().?.kind == .vari);
    try eqlStr("blerg", itr.next().?.cannon());
    try expect(itr.next() == null);
}

test "parse vars existing" {
    var a = std.testing.allocator;

    comptime var ts = [3]Token{
        try Tokenizer.any("echo"),
        try Tokenizer.any("$string"),
        try Tokenizer.any("blerg"),
    };

    Variables.init(a);
    defer Variables.raze();

    try Variables.put("string", "correct");

    try eqlStr("correct", Variables.getStr("string").?);

    var itr = try Parser.parse(&a, &ts);
    defer itr.close();
    var i: usize = 0;
    while (itr.next()) |_| {
        //std.debug.print("{}\n", .{t_});
        i += 1;
    }
    try expectEql(i, 3);
    var first = itr.first().cannon();
    try eqlStr("echo", first);
    var tst = itr.next().?;
    //try expect(tst.kind == .vari);
    try eqlStr("correct", tst.cannon());
    try eqlStr("blerg", itr.next().?.cannon());
    try expect(itr.next() == null);
}

test "parse vars existing braces" {
    var a = std.testing.allocator;

    var ti = TokenIterator{
        .raw = "echo ${string}extra blerg",
    };

    Variables.init(a);
    defer Variables.raze();

    try Variables.put("string", "value");

    try eqlStr("value", Variables.getStr("string").?);

    const slice = try ti.toSlice(a);
    defer a.free(slice);
    var itr = try Parser.parse(&a, slice);
    defer itr.close();
    var i: usize = 0;
    while (itr.next()) |_| {
        //std.debug.print("{}\n", .{t});
        i += 1;
    }
    try expectEql(i, 4);
    var first = itr.first().cannon();
    try eqlStr("echo", first);

    // the following is a bug, itr[1] should be "valueextra"
    // It's possible I may disallow this outside of double quotes
    try eqlStr("value", itr.next().?.cannon());
    //try expect(itr.next().?.kind == .vari);
    try eqlStr("extra", itr.next().?.cannon());
    try eqlStr("blerg", itr.next().?.cannon());
    try expect(itr.next() == null);
}

test "parse vars existing braces inline" {
    var a = std.testing.allocator;

    var ti = TokenIterator{
        .raw = "echo extra${string} blerg",
    };

    Variables.init(a);
    defer Variables.raze();
    try Variables.put("string", "value");

    try eqlStr("value", Variables.getStr("string").?);

    const slice = try ti.toSlice(a);
    defer a.free(slice);
    var itr = try Parser.parse(&a, slice);
    defer itr.close();
    var i: usize = 0;
    while (itr.next()) |_| {
        //std.debug.print("{}\n", .{t});
        i += 1;
    }
    try expectEql(i, 3);
    var first = itr.first().cannon();
    try eqlStr("echo", first);

    try eqlStr("extravalue", itr.next().?.cannon());
    try eqlStr("blerg", itr.next().?.cannon());
    try expect(itr.next() == null);
}

test "parse vars existing braces inline both" {
    var a = std.testing.allocator;

    var ti = TokenIterator{
        .raw = "echo extra${string}thingy blerg",
    };

    Variables.init(a);
    defer Variables.raze();
    try Variables.put("string", "value");

    try eqlStr("value", Variables.getStr("string").?);

    const slice = try ti.toSlice(a);
    defer a.free(slice);
    var itr = try Parser.parse(&a, slice);
    defer itr.close();
    var i: usize = 0;
    while (itr.next()) |_| {
        //std.debug.print("{}\n", .{t});
        i += 1;
    }
    try expectEql(i, 3);
    var first = itr.first().cannon();
    try eqlStr("echo", first);

    try eqlStr("extravaluethingy", itr.next().?.cannon());
    try eqlStr("blerg", itr.next().?.cannon());
    try expect(itr.next() == null);
}

test "parse path" {
    var a = std.testing.allocator;

    var ti = TokenIterator{
        .raw = "ls ~",
    };

    const slice = try ti.toSlice(a);
    defer a.free(slice);
    var itr = try Parser.parse(&a, slice);
    defer itr.close();

    var i: usize = 0;
    while (itr.next()) |_| {
        //std.debug.print("{}\n", .{t});
        i += 1;
    }
    try expectEql(i, 2);
    var first = itr.first().cannon();
    try eqlStr("ls", first);

    try std.testing.expect(itr.next().?.kind == .path);
    try std.testing.expect(itr.next() == null);

    // Should be done by tokenizer, but ¯\_(ツ)_/¯
    // for (slice) |*s| {
    //     if (s.backing) |*b| b.clearAndFree();
    // }
}

test "parse path ~" {
    var a = std.testing.allocator;

    var ti = TokenIterator{
        .raw = "ls ~",
    };

    Variables.init(a);
    defer Variables.raze();
    try Variables.put("HOME", "/home/user");

    const slice = try ti.toSlice(a);
    defer a.free(slice);
    var itr = try Parser.parse(&a, slice);
    defer itr.close();

    var i: usize = 0;
    while (itr.next()) |_| {
        //std.debug.print("{}\n", .{t_});
        i += 1;
    }
    try expectEql(i, 2);
    var first = itr.first().cannon();
    try eqlStr("ls", first);

    var thing = itr.next();
    try std.testing.expect(thing.?.kind == .path);
    try eqlStr("/home/user", thing.?.cannon());
    try std.testing.expect(itr.next() == null);
}

test "parse path ~/" {
    var a = std.testing.allocator;

    var ti = TokenIterator{
        .raw = "ls ~/",
    };

    Variables.init(a);
    defer Variables.raze();
    try Variables.put("HOME", "/home/user");

    const slice = try ti.toSlice(a);
    defer a.free(slice);
    var itr = try Parser.parse(&a, slice);
    defer itr.close();

    var i: usize = 0;
    while (itr.next()) |_| {
        //std.debug.print("{}\n", .{t_});
        i += 1;
    }
    try expectEql(i, 2);
    var first = itr.first().cannon();
    try eqlStr("ls", first);

    var thing = itr.next();
    try std.testing.expect(thing.?.kind == .path);
    try eqlStr("/home/user/", thing.?.cannon());
    try std.testing.expect(itr.next() == null);
}

test "parse path ~/place" {
    var a = std.testing.allocator;

    var ti = TokenIterator{
        .raw = "ls ~/place",
    };

    Variables.init(a);
    defer Variables.raze();
    try Variables.put("HOME", "/home/user");

    const slice = try ti.toSlice(a);
    defer a.free(slice);
    var itr = try Parser.parse(&a, slice);

    var i: usize = 0;
    while (itr.next()) |_| {
        //std.debug.print("{}\n", .{t});
        i += 1;
    }
    try expectEql(i, 2);
    var first = itr.first().cannon();
    try eqlStr("ls", first);

    var tst = itr.next();
    try std.testing.expect(tst.?.kind == .path);
    try eqlStr("/home/user/place", tst.?.cannon());
    try std.testing.expect(itr.next() == null);

    // Should be done by tokenizer, but ¯\_(ツ)_/¯
    for (slice) |*s| {
        if (s.resolved) |r| a.free(r);
        //     if (s.backing) |*b| b.clearAndFree();
    }
}

test "parse path /~/otherplace" {
    var a = std.testing.allocator;

    var ti = TokenIterator{
        .raw = "ls /~/otherplace",
    };

    Variables.init(a);
    defer Variables.raze();
    try Variables.put("HOME", "/home/user");

    const slice = try ti.toSlice(a);
    defer a.free(slice);
    var itr = try Parser.parse(&a, slice);

    var i: usize = 0;
    while (itr.next()) |_| {
        //std.debug.print("{}\n", .{t});
        i += 1;
    }
    try expectEql(i, 2);
    var first = itr.first().cannon();
    try eqlStr("ls", first);

    var tst = itr.next();
    try std.testing.expect(tst.?.kind == .path);
    try eqlStr("/~/otherplace", tst.?.cannon());
    try std.testing.expect(itr.next() == null);

    // Should be done by tokenizer, but ¯\_(ツ)_/¯
    for (slice) |*s| {
        if (s.resolved) |r| a.free(r);
    }
}

test "glob" {
    var a = std.testing.allocator;

    var oldcwd = std.fs.cwd();
    var basecwd = try oldcwd.realpathAlloc(a, ".");
    defer {
        var dir = std.fs.openDirAbsolute(basecwd, .{}) catch unreachable;
        dir.setAsCwd() catch {};
        a.free(basecwd);
    }

    var tmpCwd = std.testing.tmpIterableDir(.{});
    defer tmpCwd.cleanup();
    try tmpCwd.iterable_dir.dir.setAsCwd();
    _ = try tmpCwd.iterable_dir.dir.createFile("blerg", .{});
    _ = try tmpCwd.iterable_dir.dir.createFile(".blerg", .{});
    _ = try tmpCwd.iterable_dir.dir.createFile("blerg2", .{});
    _ = try tmpCwd.iterable_dir.dir.createFile("w00t", .{});
    _ = try tmpCwd.iterable_dir.dir.createFile("no_wai", .{});
    _ = try tmpCwd.iterable_dir.dir.createFile("ya-wai", .{});
    var di = tmpCwd.iterable_dir.iterate();

    var names = std.ArrayList([]u8).init(a);

    while (try di.next()) |each| {
        if (each.name[0] == '.') continue;
        try names.append(try a.dupe(u8, each.name));
    }
    try std.testing.expectEqual(@as(usize, 5), names.items.len);

    var ti = TokenIterator{
        .raw = "echo *",
    };

    const slice = try ti.toSlice(a);
    defer a.free(slice);
    var itr = try Parser.parse(&a, slice);
    defer itr.close();

    var count: usize = 0;
    while (itr.next()) |next| {
        count += 1;
        _ = next;
    }
    try std.testing.expectEqual(@as(usize, 6), count);

    try std.testing.expectEqualStrings("echo", itr.first().cannon());
    found: while (itr.next()) |next| {
        if (names.items.len == 0) return error.TestingSizeMismatch;
        for (names.items, 0..) |name, i| {
            if (std.mem.eql(u8, name, next.cannon())) {
                a.free(names.swapRemove(i));
                continue :found;
            }
        } else return error.TestingUnmatchedName;
    }
    try std.testing.expect(names.items.len == 0);
    try std.testing.expect(itr.next() == null);
    names.clearAndFree();
}

test "glob ." {
    var a = std.testing.allocator;

    var oldcwd = std.fs.cwd();
    var basecwd = try oldcwd.realpathAlloc(a, ".");
    defer {
        var dir = std.fs.openDirAbsolute(basecwd, .{}) catch unreachable;
        dir.setAsCwd() catch {};
        a.free(basecwd);
    }

    var tmpCwd = std.testing.tmpIterableDir(.{});
    defer tmpCwd.cleanup();
    try tmpCwd.iterable_dir.dir.setAsCwd();
    _ = try tmpCwd.iterable_dir.dir.createFile("blerg", .{});
    _ = try tmpCwd.iterable_dir.dir.createFile(".blerg", .{});
    _ = try tmpCwd.iterable_dir.dir.createFile("no_wai", .{});
    _ = try tmpCwd.iterable_dir.dir.createFile("ya-wai", .{});
    var di = tmpCwd.iterable_dir.iterate();

    var names = std.ArrayList([]u8).init(a);

    while (try di.next()) |each| {
        try names.append(try a.dupe(u8, each.name));
    }
    try std.testing.expectEqual(@as(usize, 4), names.items.len);

    var ti = TokenIterator{
        .raw = "echo .* *",
    };

    const slice = try ti.toSlice(a);
    defer a.free(slice);
    var itr = try Parser.parse(&a, slice);

    var count: usize = 0;
    while (itr.next()) |next| {
        count += 1;
        _ = next;
    }
    try std.testing.expectEqual(@as(usize, 5), count);

    try std.testing.expectEqualStrings("echo", itr.first().cannon());
    found: while (itr.next()) |next| {
        if (names.items.len == 0) return error.TestingSizeMismatch;
        for (names.items, 0..) |name, i| {
            if (std.mem.eql(u8, name, next.cannon())) {
                a.free(names.swapRemove(i));
                continue :found;
            }
        } else return error.TestingUnmatchedName;
    }
    try std.testing.expect(names.items.len == 0);
    try std.testing.expect(itr.next() == null);
    names.clearAndFree();
}

test "glob ~/*" {
    var a = std.testing.allocator;

    Variables.init(a);
    defer Variables.raze();

    var tmpCwd = std.testing.tmpIterableDir(.{});
    defer tmpCwd.cleanup();
    var baseCwd = try tmpCwd.iterable_dir.dir.realpathAlloc(a, ".");
    defer a.free(baseCwd);

    _ = try tmpCwd.iterable_dir.dir.createFile("blerg", .{});

    try Variables.put("HOME", baseCwd);

    var di = tmpCwd.iterable_dir.iterate();
    var names = std.ArrayList([]u8).init(a);

    while (try di.next()) |each| {
        if (each.name[0] == '.') continue;
        try names.append(try a.dupe(u8, each.name));
    }
    errdefer {
        for (names.items) |each| {
            a.free(each);
        }
        names.clearAndFree();
    }

    var ti = TokenIterator{
        .raw = "echo ~/* ",
    };

    const slice = try ti.toSlice(a);
    defer a.free(slice);
    var itr = try Parser.parse(&a, slice);
    defer itr.close();
    defer {
        for (slice) |*s| {
            if (s.resolved) |r| a.free(r);
        }
    }

    var count: usize = 0;
    while (itr.next()) |next| {
        count += 1;
        //std.debug.print("loop {s} {any}\n", .{ next.cannon(), next.kind });
        _ = next;
    }
    try std.testing.expectEqual(@as(usize, names.items.len + 1), count);

    try std.testing.expectEqualStrings("echo", itr.first().cannon());
    found: while (itr.next()) |next| {
        if (names.items.len == 0) return error.TestingSizeMismatch;
        for (names.items, 0..) |name, i| {
            if (std.mem.endsWith(u8, next.cannon(), name)) {
                a.free(names.swapRemove(i));
                continue :found;
            }
        } else {
            std.debug.print("unmatched {s}\n", .{next.cannon()});
            return error.TestingUnmatchedName;
        }
    }
    try std.testing.expect(names.items.len == 0);
    try std.testing.expect(itr.next() == null);
    names.clearAndFree();
}

test "escapes" {
    var a = std.testing.allocator;

    var t = TokenIterator{ .raw = "one\\\\ two" };
    var first = t.first();
    try std.testing.expectEqualStrings("one\\\\", first.cannon());

    var p = try Parser.word(&a, @constCast(first));
    try std.testing.expectEqualStrings("one\\", p.cannon());
    a.free(p.resolved.?);

    t = TokenIterator{ .raw = "--inline=quoted\\ string" };
    first = t.first();
    try std.testing.expectEqualStrings("--inline=quoted\\ string", first.cannon());

    p = try Parser.word(&a, @constCast(first));
    try std.testing.expectEqualStrings("--inline=quoted string", p.cannon());
    a.free(p.resolved.?);
}

test "sub process" {
    var a = std.testing.allocator;

    var t = TokenIterator{ .raw = "which $(echo 'ls')" };
    var first = t.first();
    try std.testing.expectEqualStrings("which", first.cannon());
    var next = t.next() orelse return error.Invalid;
    try std.testing.expectEqualStrings("$(echo 'ls')", next.cannon());
    var p = try Parser.single(&a, @constCast(next));
    try std.testing.expectEqualStrings("ls", p.cannon());
    a.free(p.resolved.?);
}
