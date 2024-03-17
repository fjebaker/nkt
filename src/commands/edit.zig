const std = @import("std");
const cli = @import("../cli.zig");
const tags = @import("../topology/tags.zig");
const time = @import("../topology/time.zig");
const utils = @import("../utils.zig");
const selections = @import("../selections.zig");

const commands = @import("../commands.zig");
const FileSystem = @import("../FileSystem.zig");
const Directory = @import("../topology/Directory.zig");
const Root = @import("../topology/Root.zig");

const Editor = @import("../Editor.zig");

const Self = @This();

pub const Error = error{InvalidEdit};

pub const alias = [_][]const u8{"e"};

pub const short_help = "Edit a note or item in the editor.";
pub const long_help = short_help;

pub const arguments = cli.Arguments(selections.selectHelp(
    "item",
    "The item to edit (see `help select`).",
    .{ .required = true },
) ++
    &[_]cli.ArgumentDescriptor{
    .{
        .arg = "-n/--new",
        .help = "Allow new notes to be created.",
    },
    .{
        .arg = "-e/--ext extension",
        .help = "The file extension for the new note (default: 'md').",
    },
});

const EditOptions = struct {
    allow_new: bool = false,
    extension: []const u8,
};

selection: selections.Selection,
opts: EditOptions,

pub fn fromArgs(_: std.mem.Allocator, itt: *cli.ArgIterator) !Self {
    const args = try arguments.parseAll(itt);

    const selection = try selections.fromArgs(
        arguments.Parsed,
        args.item,
        args,
    );

    if (args.new == false and args.ext != null) {
        try cli.throwError(
            cli.CLIErrors.InvalidFlag,
            "Cannot provide `--ext` without `--new`",
            .{},
        );
        unreachable;
    }

    return .{
        .selection = selection,
        .opts = .{
            .allow_new = args.new,
            .extension = args.ext orelse "md",
        },
    };
}

pub fn execute(
    self: *Self,
    allocator: std.mem.Allocator,
    root: *Root,
    writer: anytype,
    opts: commands.Options,
) !void {
    try root.load();
    try editElseMaybeCreate(
        writer,
        self.selection,
        allocator,
        root,
        opts,
        self.opts,
    );
}

fn editElseMaybeCreate(
    writer: anytype,
    selection: selections.Selection,
    allocator: std.mem.Allocator,
    root: *Root,
    opts: commands.Options,
    e_opts: EditOptions,
) !void {
    var maybe_item = try selection.resolveOrNull(root);
    if (maybe_item) |*item| {
        defer item.deinit();
        // edit the existing item
        switch (item.*) {
            .Note => |*n| {
                try editNote(allocator, root, n.note, &n.directory);
            },
            .Task => |*t| {
                var editor = try Editor.init(allocator);
                defer editor.deinit();

                // todo: might lead to topology getting out of sync
                const new_details = try editor.editTemporaryContent(
                    allocator,
                    t.task.details orelse "",
                );
                defer allocator.free(new_details);

                if (std.mem.eql(u8, new_details, t.task.details orelse "")) {
                    std.log.default.debug("No changes to task made", .{});
                    return;
                }

                var ptr = t.tasklist.getTaskByHashPtr(t.task.hash).?;
                ptr.details = new_details;
                ptr.modified = time.timeNow();

                root.markModified(t.tasklist.descriptor, .CollectionTasklist);

                try root.writeChanges();

                try writer.print(
                    "Task details for '{s}' in '{s}' updated\n",
                    .{ ptr.outcome, t.tasklist.descriptor.name },
                );
            },
            .Day => |*d| {
                // assert corresponding notes directory exists
                _ = root.getDescriptor(
                    d.journal.descriptor.name,
                    .CollectionDirectory,
                ) orelse {
                    try cli.throwError(
                        Root.Error.NoSuchCollection,
                        "Editing a day index as notes requires a directory of the same name as the journal ('{s}').",
                        .{d.journal.descriptor.name},
                    );
                    unreachable;
                };

                const sub_selection: selections.Selection = .{
                    .collection_name = d.journal.descriptor.name,
                    .collection_type = .CollectionDirectory,
                    .selector = .{
                        .ByDate = time.dateFromTime(d.day.created),
                    },
                };

                // recursively call
                try editElseMaybeCreate(
                    writer,
                    sub_selection,
                    allocator,
                    root,
                    opts,
                    e_opts,
                );
            },
            .Entry => |*e| {
                var editor = try Editor.init(allocator);
                defer editor.deinit();

                // todo: might lead to topology getting out of sync
                const new_entry = try editor.editTemporaryContent(
                    allocator,
                    e.entry.text,
                );
                defer allocator.free(new_entry);

                const new_text = std.mem.trim(u8, new_entry, "\r\n\t ");

                if (std.mem.eql(u8, new_text, e.entry.text)) {
                    std.log.default.debug("No changes to task made", .{});
                    return;
                }

                // difference in tags
                const old_entry_tags = try utils.parseAndAssertValidTags(
                    allocator,
                    root,
                    new_text,
                    &.{},
                );
                defer allocator.free(old_entry_tags);

                const additional_tags = try tags.setDifference(
                    allocator,
                    e.entry.tags,
                    old_entry_tags,
                );
                defer allocator.free(additional_tags);

                const entry_tags = try utils.parseAndAssertValidTags(
                    allocator,
                    root,
                    new_text,
                    &.{},
                );
                defer allocator.free(entry_tags);

                const new_tags = try tags.setUnion(
                    allocator,
                    entry_tags,
                    additional_tags,
                );
                defer allocator.free(new_tags);

                var ptr = try e.journal.getEntryPtr(e.day, e.entry);
                ptr.text = new_text;
                ptr.tags = new_tags;
                ptr.modified = time.timeNow();
                root.markModified(e.journal.descriptor, .CollectionJournal);

                try e.journal.writeDays();
                try root.writeChanges();
                try writer.print(
                    "Entry '{s}' in day '{s}' updated\n",
                    .{
                        try time.formatTimeBuf(opts.tz.makeLocal(
                            time.dateFromTime(ptr.created),
                        )),
                        try time.formatDateBuf(opts.tz.makeLocal(
                            time.dateFromTime(e.day.created),
                        )),
                    },
                );
            },
            else => {
                // TODO: implement all the others
                unreachable;
            },
        }
    } else {
        if (e_opts.allow_new) {
            // create new item
            const path = try createNew(
                selection,
                allocator,
                root,
                e_opts.extension,
                opts.tz,
            );
            defer allocator.free(path);
            try becomeEditorRelativePath(allocator, &root.fs.?, path);
        } else {
            try cli.throwError(
                Root.Error.NoSuchItem,
                "Use `--new` to allow new items to be created.",
                .{},
            );
            unreachable;
        }
    }
}

fn editNote(
    allocator: std.mem.Allocator,
    root: *Root,
    n: Directory.Note,
    dir: *Directory,
) !void {
    const note = try dir.touchNote(
        n,
        time.timeNow(),
    );
    root.markModified(
        dir.descriptor,
        .CollectionDirectory,
    );
    try root.writeChanges();

    try becomeEditorRelativePath(
        allocator,
        &root.fs.?,
        note.path,
    );
}

fn createNew(
    selection: selections.Selection,
    allocator: std.mem.Allocator,
    root: *Root,
    extension: []const u8,
    tz: time.TimeZone,
) ![]const u8 {
    if (selection.collection_type) |ctype| {
        if (ctype != .CollectionDirectory) {
            try cli.throwError(
                Error.InvalidEdit,
                "Can only create new items with `edit` in directories ('{s}' is invalid).",
                .{@tagName(ctype)},
            );
            unreachable;
        }
    }

    switch (selection.selector.?) {
        .ByDate => |date| {
            const cname = selection.collection_name orelse
                root.info.default_journal;
            const local_date = tz.makeLocal(date);
            const date_string = try time.formatDateBuf(local_date);
            const template = try dateTemplate(allocator, local_date);
            return try createNewNote(
                allocator,
                cname,
                &date_string,
                root,
                extension,
                template,
            );
        },
        .ByName => |name| {
            const cname = selection.collection_name orelse
                root.info.default_directory;
            return try createNewNote(allocator, cname, name, root, extension, null);
        },
        // all others should not be accessible for new
        else => unreachable,
    }
}

fn dateTemplate(allocator: std.mem.Allocator, date: time.Date) ![]const u8 {
    const date_string = try time.formatDateBuf(date);
    const day = try time.dayOfWeek(date);
    const month = try time.monthOfYear(date);

    // write the template
    return try std.fmt.allocPrint(
        allocator,
        "# {s}: {s} of {s}\n\n",
        .{ date_string, day, month },
    );
}

fn createNewNote(
    allocator: std.mem.Allocator,
    collection_name: []const u8,
    name: []const u8,
    root: *Root,
    extension: []const u8,
    template: ?[]const u8,
) ![]const u8 {
    var dir = (try root.getDirectory(collection_name)) orelse {
        try cli.throwError(
            Root.Error.NoSuchCollection,
            "No directory by name '{s}' exists",
            .{collection_name},
        );
        unreachable;
    };
    defer dir.deinit();
    const note = try dir.addNewNoteByName(
        name,
        .{ .extension = extension },
    );

    // write the template
    if (template) |str| {
        try root.fs.?.overwrite(note.path, str);
    } else {
        try root.fs.?.overwrite(note.path, "");
    }

    root.markModified(dir.descriptor, .CollectionDirectory);
    try root.writeChanges();

    return try allocator.dupe(u8, note.path);
}

fn becomeEditorRelativePath(
    allocator: std.mem.Allocator,
    fs: *FileSystem,
    path: []const u8,
) !void {
    var editor = try Editor.init(allocator);
    defer editor.deinit();

    const abs_path = try fs.absPathify(allocator, path);
    defer allocator.free(abs_path);

    try editor.becomeWithArgs(abs_path, &.{});
}
