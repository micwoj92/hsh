const std = @import("std");
const Token = @import("tokenizer.zig").Token;
const HSH = @import("hsh.zig").HSH;
const jobs_ = @import("jobs.zig");
const ParsedIterator = @import("parse.zig").ParsedIterator;

pub const State = @import("state.zig");
pub const aliases = @import("builtins/alias.zig");
pub const Set = @import("builtins/set.zig");
pub const Pipeline = @import("builtins/pipeline.zig");

const alias = aliases.alias;
const pipeline = Pipeline.pipeline;
const set = Set.set;

var Self = @This();

pub const Err = error{
    Unknown,
    Memory,
    IO,
    InvalidToken,
    InvalidCommand,
    FileSysErr,
};

pub const BuiltinFn = *const fn (a: *HSH, b: *ParsedIterator) Err!u8;

pub const Builtins = enum {
    alias,
    bg,
    cd,
    die,
    echo,
    exit,
    fg,
    jobs,
    pipeline,
    set,
    which,
    // DEBUGGING BUILTINS
    tty,
};

pub fn builtinToName(comptime bi: Builtins) []const u8 {
    return @tagName(bi);
}

pub fn exec(self: Builtins) BuiltinFn {
    return switch (self) {
        .alias => alias,
        .bg => bg,
        .cd => cd,
        .die => die,
        .echo => echo,
        .exit => exit, // TODO exit should be kinder than die
        .fg => fg,
        .jobs => jobs,
        .pipeline => pipeline,
        .set => set,
        .which => which,
        // DEBUGGING BUILTIN
        .tty => tty,
    };
}

/// Caller must ensure this builtin exists.
pub fn strExec(str: []const u8) BuiltinFn {
    inline for (@typeInfo(Builtins).Enum.fields[0..]) |f| {
        if (std.mem.eql(u8, f.name, str)) return exec(@intToEnum(Builtins, f.value));
    }
    std.debug.print("strExec panic on {s}\n", .{str});
    unreachable;
}

pub fn exists(str: []const u8) bool {
    inline for (@typeInfo(Builtins).Enum.fields[0..]) |f| {
        if (std.mem.eql(u8, f.name, str)) return true;
    }
    return false;
}

/// reusable print function for builtins
pub fn print(
    comptime format: []const u8,
    args: anytype,
) !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print(format, args);
}

fn bg(_: *HSH, _: *ParsedIterator) Err!u8 {
    print("bg not yet implemented\n", .{}) catch return Err.Unknown;
    return 0;
}

/// Someone should add some sane input sanitzation to this
fn cd(hsh: *HSH, titr: *ParsedIterator) Err!u8 {
    // TODO pushd and popd
    var path: [1 << 10]u8 = undefined;
    var path_len: usize = 0;

    _ = titr.first();
    while (titr.next()) |t| {
        switch (t.type) {
            .String, .Quote, .Var => {
                std.mem.copy(u8, &path, t.cannon());
                path_len = t.cannon().len;
                break;
            },
            else => return Err.InvalidToken,
        }
    } else {
        if (hsh.fs.home_name != null) {
            std.mem.copy(u8, &path, hsh.fs.home_name.?);
            path_len = hsh.fs.home_name.?.len;
        } else return Err.InvalidCommand;
    }

    // std.debug.print("cd path {s} default {s}\n", .{ &path, hsh.fs.home_name });
    const dir = hsh.fs.cwd.openDir(path[0..path_len], .{}) catch return Err.FileSysErr;
    dir.setAsCwd() catch |e| {
        std.debug.print("cwd failed! {}", .{e});
        return Err.FileSysErr;
    };
    hsh.updateFs();
    return 0;
}

pub fn die(_: *HSH, _: *ParsedIterator) Err!u8 {
    unreachable;
}

test "fs" {
    const c = std.fs.cwd();
    //std.debug.print("cwd failed! {}", .{e});
    const ndir = try c.openDir("/home/grayhatter", .{});
    //std.debug.print("test {}\n", .{ndir});
    try ndir.setAsCwd();
}

fn echo(_: *HSH, _: *ParsedIterator) Err!u8 {
    print("echo not yet implemented\n", .{}) catch return Err.Unknown;
    return 0;
}

/// TODO implement real version of exit
fn exit(h: *HSH, i: *ParsedIterator) Err!u8 {
    return noimpl(h, i);
}

/// TODO implement job selection support
fn fg(hsh: *HSH, _: *ParsedIterator) Err!u8 {
    var paused: usize = 0;
    for (hsh.jobs.items) |j| {
        paused += if (j.status == .Paused or j.status == .Waiting) 1 else 0;
    }
    if (paused == 0) {
        hsh.tty.print("No resumeable jobs\n", .{}) catch {};
        return 1;
    }
    if (paused == 1) {
        hsh.tty.print("Restarting job\n", .{}) catch {};
        jobs_.contNext(hsh, true) catch unreachable;
        return 0;
    }

    print("More than one job paused, fg not yet implemented\n", .{}) catch return Err.Unknown;
    return 0;
}

fn jobs(hsh: *HSH, _: *ParsedIterator) Err!u8 {
    for (hsh.jobs.items) |j| {
        hsh.tty.print("{}", .{j}) catch return Err.Unknown;
    }
    return 0;
}

/// TODO implement real version
fn which(h: *HSH, i: *ParsedIterator) Err!u8 {
    return noimpl(h, i);
}

fn noimpl(_: *HSH, i: *ParsedIterator) Err!u8 {
    print("{s} not yet implemented\n", .{i.first().cannon()}) catch return Err.Unknown;
    return 0;
}

test "builtins" {
    const str = @tagName(Builtins.alias);
    var bi: bool = false;
    inline for (@typeInfo(Builtins).Enum.fields[0..]) |f| {
        if (std.mem.eql(u8, f.name, str)) bi = true;
    }
    try std.testing.expect(bi);
    var bi2 = false;
    const never = "pleasegodletthisneverbecomeabuiltin";
    inline for (@typeInfo(Builtins).Enum.fields[0..]) |f| {
        if (std.mem.eql(u8, f.name, never)) bi2 = true;
    }
    try std.testing.expect(!bi2);
}

test "builtins alias" {
    try std.testing.expect(exists(@tagName(Builtins.alias)));
    try std.testing.expect(exists(@tagName(Builtins.cd)));
    try std.testing.expect(exists(@tagName(Builtins.echo)));
    try std.testing.expect(exists(@tagName(Builtins.which)));

    try std.testing.expect(!exists("BLERG"));
}

//DEBUGGING BUILTINS
fn tty(hsh: *HSH, _: *ParsedIterator) Err!u8 {
    for (hsh.tty.attrs.items) |i| {
        std.debug.print("attr {any}\n", .{i});
    }
    return 0;
}
