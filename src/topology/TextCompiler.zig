/// Struct representing the different methods for compiling and exporting
/// notes.
const std = @import("std");

const Directory = @import("Directory.zig");
const Journal = @import("Journal.zig");
const Tasklist = @import("Tasklist.zig");
const Root = @import("Root.zig");
const processing = @import("../processing.zig");
const FileSystem = @import("../FileSystem.zig");

const TextCompiler = @This();

pub const Error = error{ CompileError, CompileInterrupted };

pub const INFILE_SYMBOL = "%<";
pub const OUTFILE_SYMBOL = "%@";

/// Name for internal use
name: []const u8,
/// Command used to compile / export the text
command: []const []const u8 = &.{
    "pandoc",
    INFILE_SYMBOL,
    "-o",
    OUTFILE_SYMBOL,
},
link: []const u8 = "[%NAME](%LINK)",
/// File extensions that it is applicable for
extensions: []const []const u8,

/// Returns true if the given extension is supported by this compiler
pub fn supports(tc: TextCompiler, ext: []const u8) bool {
    for (tc.extensions) |e| {
        if (std.mem.eql(u8, e, ext)) {
            return true;
        }
    }
    return false;
}

/// Format a note link. Caller owns the memory.
pub fn formatLink(
    tc: TextCompiler,
    allocator: std.mem.Allocator,
    link: []const u8,
    name: []const u8,
) ![]const u8 {
    const sub1 = try std.mem.replaceOwned(u8, allocator, tc.link, "%NAME", name);
    defer allocator.free(sub1);
    return try std.mem.replaceOwned(u8, allocator, sub1, "%LINK", link);
}

/// Substitute blocks and write into `writer`.
pub fn processText(
    tc: TextCompiler,
    writer: anytype,
    text: []const u8,
    root: *Root,
) !void {
    return try tc.processTextImpl(
        writer,
        text,
        root,
        root.allocator,
        .{},
    );
}

const ProcessingOptions = struct {
    // rewrite note links to point to the compiled directory
    compiled_links: bool = false,
};

fn processTextImpl(
    tc: TextCompiler,
    writer: anytype,
    text: []const u8,
    root: *Root,
    allocator: std.mem.Allocator,
    opts: ProcessingOptions,
) !void {
    std.log.default.debug("Processing text with '{s}' compiler", .{tc.name});

    const Ctx = struct {
        writer: @TypeOf(writer),
        root: *Root,
        // leaky allocator
        allocator: std.mem.Allocator,
        opts: ProcessingOptions,
        tc: TextCompiler,

        fn handle(self: @This(), f: processing.Fragment) !void {
            switch (f.type) {
                .link => {
                    // find the item
                    if (try self.root.selectFromString(f.inner())) |item| {
                        const path = item.getPath();
                        const name = try item.getName(self.allocator);
                        const link_path = if (self.opts.compiled_links)
                            try makeCompiledPath(
                                self.allocator,
                                self.root,
                                path,
                            )
                        else
                            path;
                        const link = try self.tc.formatLink(self.allocator, link_path, name);
                        try self.writer.writeAll(link);
                    }
                },
                else => {
                    try self.writer.writeAll(f.text);
                },
            }
        }
    };
    const P = processing.Processor(Ctx, Ctx.handle);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var processor = P.init(.{
        .writer = writer,
        .root = root,
        .allocator = arena.allocator(),
        .opts = opts,
        .tc = tc,
    });

    try processor.processText(text);
}

const CompilerFile = struct {
    path: []const u8,
    file: std.fs.File,
};

fn makeCompilerTmpFile(
    c: TextCompiler,
    allocator: std.mem.Allocator,
    path: []const u8,
    root: *Root,
) !CompilerFile {
    const dir = std.fs.path.dirname(path).?;
    const filename = std.fs.path.stem(path);
    _ = c;

    const tmp_file = try makeFileName(
        allocator,
        dir,
        &.{ "_tmp.", filename },
        std.fs.path.extension(path),
    );
    errdefer allocator.free(tmp_file);

    var f = try root.fs.?.openElseCreate(tmp_file);
    errdefer f.close();
    try f.seekTo(0);
    return .{ .path = tmp_file, .file = f };
}

pub const CompileOptions = struct {
    keep_source_file: bool = false,
};

/// Compile a note. Returns the out path of the compiled file.
pub fn compileNote(
    c: TextCompiler,
    allocator: std.mem.Allocator,
    note: Directory.Note,
    root: *Root,
    opts: CompileOptions,
) ![]const u8 {
    try root.ensureCompiledDirectory();

    const cwd = try root.fs.?.absPathify(
        allocator,
        std.fs.path.dirname(note.path).?,
    );
    defer allocator.free(cwd);

    const source_path = try c.processForCompiling(
        allocator,
        note.path,
        root,
    );
    defer allocator.free(source_path);

    const outfile = try makeCompiledPath(
        allocator,
        root,
        note.path,
    );
    errdefer allocator.free(outfile);

    // ensure the outfile directory exists as well
    if (std.fs.path.dirname(outfile)) |d| {
        try root.fs.?.makeDirIfNotExists(d);
    }

    try c.runCompile(
        allocator,
        std.fs.path.basename(source_path),
        outfile,
        cwd,
    );

    if (opts.keep_source_file == false) {
        try root.fs.?.removeFile(source_path);
    }

    return outfile;
}

fn processForCompiling(
    c: TextCompiler,
    allocator: std.mem.Allocator,
    path: []const u8,
    root: *Root,
) ![]const u8 {
    const content = try root.fs.?.readFileAlloc(allocator, path);
    defer allocator.free(content);

    var tmp_file = try c.makeCompilerTmpFile(allocator, path, root);
    defer tmp_file.file.close();
    errdefer allocator.free(tmp_file.path);

    const file_writer = tmp_file.file.writer();
    try c.processTextImpl(
        file_writer,
        content,
        root,
        allocator,
        .{ .compiled_links = true },
    );

    return tmp_file.path;
}

fn runCompile(
    c: TextCompiler,
    allocator: std.mem.Allocator,
    in_path: []const u8,
    out_path: []const u8,
    cwd: []const u8,
) !void {
    const cmd = try c.prepareCommand(allocator, in_path, out_path);
    defer allocator.free(cmd);
    return try runCommand(allocator, cmd, cwd);
}

fn makeCompiledPath(
    allocator: std.mem.Allocator,
    root: *Root,
    path: []const u8,
) ![]const u8 {
    // to resolve links better, use the abs path
    const compiled_directory = try root.fs.?.absPathify(
        allocator,
        root.info.compiled_directory,
    );
    defer allocator.free(compiled_directory);

    const ext = std.fs.path.extension(path);
    const name = path[0 .. path.len - ext.len];

    return try makeFileName(
        allocator,
        compiled_directory,
        &.{name},
        // TODO: arbitrary output file extensions
        ".pdf",
    );
}

fn makeFileName(
    allocator: std.mem.Allocator,
    dir: []const u8,
    names: []const []const u8,
    ext: []const u8,
) ![]const u8 {
    const sep = if (ext[0] == '.') "" else ".";

    const name = try std.mem.concat(allocator, u8, names);
    defer allocator.free(name);

    const outfile_name = try std.mem.concat(
        allocator,
        u8,
        &.{ name, sep, ext },
    );
    defer allocator.free(outfile_name);
    return try std.fs.path.join(
        allocator,
        &.{ dir, outfile_name },
    );
}

fn prepareCommand(
    c: TextCompiler,
    allocator: std.mem.Allocator,
    in_path: []const u8,
    out_path: []const u8,
) ![]const []const u8 {
    var list = std.ArrayList([]const u8).init(allocator);

    for (c.command) |part| {
        if (std.mem.eql(u8, part, INFILE_SYMBOL)) {
            try list.append(in_path);
        } else if (std.mem.eql(u8, part, OUTFILE_SYMBOL)) {
            try list.append(out_path);
        } else {
            try list.append(part);
        }
    }

    return list.toOwnedSlice();
}

fn runCommand(
    allocator: std.mem.Allocator,
    cmd: []const []const u8,
    cwd: []const u8,
) !void {
    std.log.default.debug(
        "CWD '{s}' running command '{s}'",
        .{ cwd, cmd },
    );

    var proc = std.process.Child.init(
        cmd,
        allocator,
    );

    proc.cwd = cwd;
    proc.stdin_behavior = std.process.Child.StdIo.Inherit;
    proc.stdout_behavior = std.process.Child.StdIo.Inherit;
    proc.stderr_behavior = std.process.Child.StdIo.Inherit;

    try proc.spawn();

    const term = try proc.wait();
    switch (term) {
        .Exited => {},
        .Signal => return Error.CompileInterrupted,
        else => return Error.CompileError,
    }
    return;
}
