const std = @import("std");
const Token = @import("tokenizer.zig").Token;
const HSH = @import("hsh.zig").HSH;
const jobs_ = @import("jobs.zig");
const ParsedIterator = @import("parse.zig").ParsedIterator;
const log = @import("log");

// files should be lowercased, but #YOLO
pub const Aliases = @import("builtins/alias.zig");
pub const Echo = @import("builtins/echo.zig");
pub const Pipeline = @import("builtins/pipeline.zig");
pub const Set = @import("builtins/set.zig");
pub const Source = @import("builtins/source.zig");
pub const State = @import("state.zig");
pub const Which = @import("builtins/which.zig");

const alias = Aliases.alias;
const echo = Echo.echo;
const pipeline = Pipeline.pipeline;
const set = Set.set;
const source = Source.source;
const which = Which.which;

var Self = @This();

pub const Err = error{
    Unknown,
    Memory,
    IO,
    StdOut,
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
    source,
    which,
    // DEBUGGING BUILTINS
    tty,
};

/// Optional builtins "exist" only if they don't already exist on the system.
pub const BuiltinOptionals = enum {
    status,
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
        .source => source,
        .which => which,
        // DEBUGGING BUILTIN
        .tty => tty,
    };
}

/// Optional builtins "exist" only if they don't already exist on the system.
pub fn execOpt(self: BuiltinOptionals) BuiltinFn {
    return switch (self) {
        .status => status,
    };
}

/// Caller must ensure this builtin exists by calling exists, or optionalExists
pub fn strExec(str: []const u8) BuiltinFn {
    inline for (@typeInfo(Builtins).Enum.fields[0..]) |f| {
        if (std.mem.eql(u8, f.name, str)) return exec(@enumFromInt(f.value));
    }
    inline for (@typeInfo(BuiltinOptionals).Enum.fields[0..]) |f| {
        if (std.mem.eql(u8, f.name, str)) return execOpt(@enumFromInt(f.value));
    }
    log.err("strExec panic on {s}\n", .{str});
    unreachable;
}

pub fn exists(str: []const u8) bool {
    inline for (@typeInfo(Builtins).Enum.fields[0..]) |f| {
        if (std.mem.eql(u8, f.name, str)) return true;
    }
    return false;
}

/// Optional builtins "exist" only if they don't already exist on the system.
/// this is not enforced internally callers are expected to behave
pub fn existsOptional(str: []const u8) bool {
    inline for (@typeInfo(BuiltinOptionals).Enum.fields[0..]) |f| {
        if (std.mem.eql(u8, f.name, str)) return true;
    }
    return false;
}

/// reusable print function for builtins
pub fn print(
    comptime format: []const u8,
    args: anytype,
) Err!void {
    const stdout = std.io.getStdOut().writer();
    stdout.print(format, args) catch |err| {
        log.err(
            "Builtin unable to write to stdout: {}\n    but stderr will work right?\n",
            .{err},
        );
        return Err.StdOut;
    };
}

fn bg(_: *HSH, _: *ParsedIterator) Err!u8 {
    print("bg not yet implemented\n", .{}) catch return Err.Unknown;
    return 0;
}

/// Someone should add some sane input sanitzation to this
fn cd(hsh: *HSH, titr: *ParsedIterator) Err!u8 {
    // TODO pushd and popd
    std.debug.assert(std.mem.eql(u8, "cd", titr.first().cannon()));
    defer titr.close();

    while (titr.next()) |t| {
        switch (t.kind) {
            .word, .quote, .vari, .path => {
                hsh.hfs.cd(t.cannon()) catch |err| {
                    log.err("Unable to change directory because {}\n", .{err});
                    return 1;
                };
                return 0;
            },
            else => return Err.InvalidToken,
        }
    } else {
        if (hsh.hfs.names.home) |_| {
            hsh.hfs.cd("") catch @panic("CD $HOME should never fail");
            return 0;
        } else return Err.InvalidCommand;
    }
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

/// TODO implement real version of exit
fn exit(h: *HSH, i: *ParsedIterator) Err!u8 {
    return noimpl(h, i);
}

/// TODO implement job selection support
fn fg(hsh: *HSH, _: *ParsedIterator) Err!u8 {
    var paused: usize = 0;
    for (hsh.jobs.items) |j| {
        paused += if (j.status == .paused or j.status == .waiting) 1 else 0;
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

fn noimpl(_: *HSH, i: *ParsedIterator) Err!u8 {
    print("{s} not yet implemented\n", .{i.first().cannon()}) catch return Err.Unknown;
    while (i.next()) |_| {}
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
fn tty(hsh: *HSH, pi: *ParsedIterator) Err!u8 {
    std.debug.assert(std.mem.eql(u8, "tty", pi.first().cannon()));

    if (pi.next()) |next| {
        if (std.mem.eql(u8, "raw", next.cannon())) {
            try print("changing tty from \n{any}\n", .{hsh.tty.getAttr()});
            hsh.tty.setRaw() catch return Err.Unknown;
            try print("to raw \n{}\n", .{hsh.tty.getAttr()});
        } else if (std.mem.eql(u8, "orig", next.cannon())) {
            try print("changing tty from \n{any}\n", .{hsh.tty.getAttr()});
            hsh.tty.setOrig() catch return Err.Unknown;
            try print("to orig \n{}\n", .{hsh.tty.getAttr()});
        } else {
            try print("changing tty from \n{any}\n", .{hsh.tty.getAttr()});
        }
    } else {
        try print("current tty settings \n{any}\n", .{hsh.tty.getAttr()});
    }

    return 0;
}

fn status(_: *HSH, _: *ParsedIterator) Err!u8 {
    print("status not yet implemented\n", .{}) catch return Err.Unknown;
    return 0;
}
