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

pub const arguments = cli.ArgumentsHelp(selections.selectHelp(
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
}, .{});

const EditOptions = struct {
    allow_new: bool = false,
    extension: []const u8,
};

selection: selections.Selection,
opts: EditOptions,

pub fn fromArgs(_: std.mem.Allocator, itt: *cli.ArgIterator) !Self {
    var args = try arguments.parseAll(itt);

    const selection = try selections.fromArgs(
        arguments.ParsedArguments,
        args.item,
        args,
    );

    if (args.new == null and args.ext != null) {
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
            .allow_new = args.new orelse false,
            .extension = args.ext orelse "md",
        },
    };
}

pub fn execute(
    self: *Self,
    allocator: std.mem.Allocator,
    root: *Root,
    _: anytype,
    opts: commands.Options,
) !void {
    try root.load();
    try editElseMaybeCreate(self.selection, allocator, root, opts, self.opts);
}

fn editElseMaybeCreate(
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
                    sub_selection,
                    allocator,
                    root,
                    opts,
                    e_opts,
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

// fn createDefaultInDirectory(
//     self: *Self,
//     state: *State,
// ) !State.Item {
//     // guard against trying to use journal
//     if (self.selection.collection) |w| if (w.container == .Journal)
//         return cli.SelectionError.InvalidSelection;

//     const default_dir: []const u8 = switch (self.selection.item.?) {
//         .ByIndex => return cli.SelectionError.InvalidSelection,
//         .ByDate => "diary",
//         .ByName => "notes",
//     };

//     var dir: *State.Collection = blk: {
//         if (self.selection.collection) |w| {
//             break :blk state.getDirectory(w.name) orelse
//                 return cli.SelectionError.UnknownCollection;
//         } else break :blk state.getDirectory(default_dir).?;
//     };

//     switch (self.selection.item.?) {
//         .ByName => |name| return try dir.Directory.newNote(name),
//         .ByIndex => unreachable,
//         .ByDate => |date| {
//             // format information about the day
//             const date_string = try utils.formatDateBuf(date);

//             const day = try utils.dayOfWeek(state.allocator, date);
//             defer state.allocator.free(day);
//             const month = try utils.monthOfYear(state.allocator, date);
//             defer state.allocator.free(month);

//             // create the new item
//             var note = try dir.Directory.newNote(&date_string);

//             // write the template
//             const template = try std.fmt.allocPrint(
//                 state.allocator,
//                 "# {s}: {s} of {s}\n\n",
//                 .{ date_string, day, month },
//             );
//             defer state.allocator.free(template);

//             try state.fs.overwrite(note.getPath(), template);
//             return note;
//         },
//     }
// }

// fn findOrCreateDefault(self: *Self, state: *State) !struct {
//     new: bool,
//     item: State.MaybeItem,
// } {
//     const item: ?State.MaybeItem = try self.selection.find(state);

//     if (item) |i| {
//         if (i.numActive() == 1 and (i.getActive() catch unreachable) == .Day) {
//             // need at least a note or a task
//             if (i.day.?.Day.time) |_| {
//                 return .{ .new = false, .item = i };
//             }
//         } else {
//             return .{ .new = false, .item = item.? };
//         }
//     }

//     if (self.allow_new) {
//         return .{
//             .new = true,
//             .item = .{
//                 .note = try createDefaultInDirectory(self, state),
//             },
//         };
//     } else {
//         return cli.SelectionError.NoSuchItem;
//     }
// }

// pub fn run(
//     self: *Self,
//     state: *State,
//     out_writer: anytype,
// ) !void {
//     const iteminfo = try self.findOrCreateDefault(state);
//     const item = iteminfo.item;

//     if (item.note) |note| {
//         const rel_path = note.getPath();

//         const abs_path = try state.fs.absPathify(state.allocator, rel_path);
//         defer state.allocator.free(abs_path);

//         if (iteminfo.new) {
//             try out_writer.print(
//                 "Creating new file '{s}' in '{s}'\n",
//                 .{ rel_path, note.collectionName() },
//             );
//         } else {
//             try out_writer.print("Opening file '{s}'\n", .{rel_path});
//         }

//         note.Note.note.modified = utils.now();
//         // write changes before popping editor
//         try state.writeChanges();

//         var editor = try Editor.init(state.allocator);
//         defer editor.deinit();
//         try editor.becomeWithArgs(abs_path, &.{});
//     } else if (item.task) |task| {
//         var editor = try Editor.init(state.allocator);
//         defer editor.deinit();

//         // todo: might lead to topology getting out of sync
//         const task_allocator = task.Task.tasklist.mem.allocator();
//         const new_details = try editor.editTemporaryContent(
//             task_allocator,
//             task.Task.task.details,
//         );

//         if (std.mem.eql(u8, new_details, task.Task.task.details)) {
//             return;
//         }

//         task.Task.task.details = new_details;
//         task.Task.task.modified = utils.now();

//         try state.writeChanges();
//         try out_writer.print(
//             "Task details for '{s}' in '{s}' updated\n",
//             .{ task.getName(), task.collectionName() },
//         );
//     } else if (item.day) |day| {
//         const index = try day.Day.indexAtTime();
//         var entry = try day.Day.getEntryPtr(index);

//         var editor = try Editor.init(state.allocator);
//         defer editor.deinit();

//         // todo: might lead to topology getting out of sync
//         const day_allocator = day.Day.journal.mem.allocator();
//         const raw_text = try editor.editTemporaryContent(
//             day_allocator,
//             entry.item,
//         );

//         const entry_text = std.mem.trim(u8, raw_text, " \t\n\r");
//         if (std.mem.eql(u8, entry.item, entry_text)) {
//             return;
//         }

//         // validate the changes to the entry
//         // must not have any new lines, all subsequent lines will be treated as tags
//         if (std.mem.count(u8, entry_text, "\n") != 0) {
//             return EditError.InvalidEdit;
//         }

//         const allowed_tags = state.getTagInfo();

//         var old_context = try tags.parseContexts(state.allocator, entry.item);
//         defer old_context.deinit();
//         const old_tags = try old_context.getTags(allowed_tags);

//         var new_context = try tags.parseContexts(state.allocator, entry_text);
//         defer new_context.deinit();
//         const new_tags = try new_context.getTags(allowed_tags);

//         entry.tags = try tags.removeAndUpdate(
//             day.Day.journal.content.allocator(),
//             entry.tags,
//             old_tags,
//             new_tags,
//         );

//         const now = utils.now();
//         entry.item = entry_text;
//         entry.modified = now;
//         day.Day.day.modified = now;

//         try state.writeChanges();
//         try out_writer.print(
//             "Entry '{s}' in '{s}' updated\n",
//             .{ day.Day.time.?, day.collectionName() },
//         );
//     } else {
//         return cli.SelectionError.InvalidSelection;
//     }
// }
