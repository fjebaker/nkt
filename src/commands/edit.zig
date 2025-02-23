const std = @import("std");
const cli = @import("../cli.zig");
const tags = @import("../topology/tags.zig");
const time = @import("../topology/time.zig");
const utils = @import("../utils.zig");
const selections = @import("../selections.zig");
const searching = @import("../searching.zig");
const stringsearch = @import("../stringsearch.zig");
const color = @import("../colors.zig");

const termui = @import("termui");

const commands = @import("../commands.zig");
const FileSystem = @import("../FileSystem.zig");
const Directory = @import("../topology/Directory.zig");
const Root = @import("../topology/Root.zig");

const Editor = @import("../Editor.zig");

const Self = @This();

pub const Error = error{InvalidEdit};

pub const alias = [_][]const u8{ "e", "e" };

pub const short_help = "Edit or create a note in the editor.";
pub const long_help =
    \\Edit a note, task or log entry in the configured editor. Supports the standard
    \\selection syntax of `select`.
    \\
    \\If no selection argument is given, an interactive fuzzy search is presented
    \\that searches through note names. In this mode, 'Enter' will select the
    \\highlighted note, whereas 'Ctrl-n' will select or else create the note and give
    \\the option to select an extension.
    \\
    \\Examples:
    \\
    \\    nkt edit --new my.new.note                  # a new note with default extension
    \\    nkt edit --new something.else --ext typ     # a new typst note
    \\    nkt edit my.new.note                        # edit an existing note
    \\    nkt e something.else                        # edit another existing note
    \\
;

pub const Arguments = cli.Arguments(selections.selectHelp(
    "item",
    "The item to edit (see `help select`). If left blank will open an interactive search through the names of the notes.",
    .{ .required = false },
) ++
    &[_]cli.ArgumentDescriptor{
    .{
        .arg = "-n/--new",
        .help = "Allow new notes to be created.",
    },
    .{
        .arg = "--ext extension",
        .help = "The file extension for the new note (default: 'md')",
    },
    .{
        .arg = "--path-only",
        .help = "Do not open the file in the editor, but print the path to stdout. Used for editor integration.",
    },
});

const EditOptions = struct {
    allow_new: bool = false,
    extension: []const u8,
    path_only: bool,
};

selection: selections.Selection,
opts: EditOptions,

pub fn fromArgs(_: std.mem.Allocator, itt: *cli.ArgIterator) !Self {
    const args = try Arguments.initParseAll(itt, .{});

    const selection =
        try selections.fromArgs(
        Arguments.Parsed,
        args.item,
        args,
    );

    if (args.new == false and args.ext != null) {
        try cli.throwError(
            cli.CLIErrors.InvalidFlag,
            "Cannot provide `--ext` without `--new`",
            .{},
        );
    }

    return .{
        .selection = selection,
        .opts = .{
            .allow_new = args.new,
            .extension = args.ext orelse "md",
            .path_only = args.@"path-only",
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
    if (self.selection.selector != null) {
        try editElseMaybeCreate(
            writer,
            self.selection,
            allocator,
            root,
            opts,
            self.opts,
        );
    } else {
        const dir_name = if (self.selection.collection_type) |ct| b: {
            if (ct == .CollectionDirectory) {
                break :b self.selection.collection_name;
            }
            try cli.throwError(
                cli.CLIErrors.BadArgument,
                "Currently can only select from directories interactively",
                .{},
            );
            unreachable;
        } else null;

        const selected_directory = dir_name orelse root.info.default_directory;
        var dir = (try root.getDirectory(selected_directory)).?;
        const ss = try searchFileNames(
            &dir,
            allocator,
        ) orelse return;
        switch (ss) {
            .note => |note| {
                try editNote(writer, allocator, root, note, &dir, self.opts, opts);
            },
            .new => |name| {
                defer allocator.free(name);
                self.selection = .{
                    .collection_type = .CollectionDirectory,
                    .selector = .{ .ByName = name },
                };
                self.opts.allow_new = true;

                // assert the note does not already exist
                const maybe_item = try self.selection.resolveOrNull(root);
                if (maybe_item != null) {
                    var n = maybe_item.?.Note;
                    try editNote(
                        writer,
                        allocator,
                        root,
                        n.note,
                        &n.directory,
                        self.opts,
                        opts,
                    );
                    return;
                }

                var ext_list = std.StringArrayHashMap(void).init(allocator);
                defer ext_list.deinit();
                for (root.info.text_compilers) |comp| {
                    for (comp.extensions) |ext| {
                        try ext_list.put(ext, {});
                    }
                }

                if (!noteNameValid(name)) {
                    return cli.throwError(
                        error.InvalidName,
                        "Note name is invalid: '{s}'",
                        .{name},
                    );
                }

                const ext = (try promptExtension(ext_list.keys())) orelse {
                    try writer.writeAll("No extension selected. Note not created.\n");
                    return;
                };
                const path = try createNew(
                    self.selection,
                    allocator,
                    root,
                    ext,
                    opts,
                );
                defer allocator.free(path);
                try becomeEditorRelativePath(allocator, &root.fs.?, path);
                try editElseMaybeCreate(
                    writer,
                    self.selection,
                    allocator,
                    root,
                    opts,
                    self.opts,
                );
            },
        }
    }
}

pub fn promptExtension(compilers: []const []const u8) !?[]const u8 {
    var tui = try termui.TermUI.init(
        std.io.getStdIn(),
        std.io.getStdOut(),
    );
    defer tui.deinit();
    const choice = try termui.Selector.interact(
        &tui,
        compilers,
        .{ .clear = true },
    ) orelse return null;
    return compilers[choice];
}

const SearchKey = struct {
    index: usize,
};
const NameSearcher = searching.Searcher(SearchKey);

const SearchSelection = union(enum) {
    note: Root.Directory.Note,
    new: []const u8,
};

const Result = stringsearch.StringSearch.Search.Result;

const InteractiveControl = struct {
    create_new: bool = false,
    name: ?[]const u8 = null,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *InteractiveControl) void {
        if (self.name) |name| {
            self.allocator.free(name);
        }
        self.* = undefined;
    }

    pub fn handleControl(
        self: *InteractiveControl,
        key: u8,
        needle: []const u8,
    ) !bool {
        switch (key) {
            'n' => {
                self.name = try self.allocator.dupe(u8, needle);
                self.create_new = true;
                return true;
            },
            else => {},
        }
        return false;
    }

    pub fn drawNote(
        _: *const InteractiveControl,
        writer: anytype,
        note: Directory.Note,
        c: color.Farbe,
    ) !void {
        try c.write(writer, "{s}", .{note.name});
    }

    pub fn sortResults(
        _: *const InteractiveControl,
        results: []Result,
        notes: []const Directory.Note,
    ) void {
        // sort the results by last modified
        std.sort.heap(
            Result,
            results,
            notes,
            sortLastModified,
        );
    }
};

fn searchFileNames(
    dir: *const Root.Directory,
    allocator: std.mem.Allocator,
) !?SearchSelection {
    const dir_info = dir.getInfo();
    const search_items = try allocator.alloc(
        []const u8,
        dir_info.notes.len,
    );
    defer allocator.free(search_items);

    // sort a copy of the notes list
    const notes_list = try allocator.dupe(Directory.Note, dir_info.notes);
    defer allocator.free(notes_list);
    std.sort.heap(Directory.Note, notes_list, {}, Directory.Note.sortModified);

    for (notes_list, search_items) |note, *item| {
        item.* = note.name;
    }

    var ss = try stringsearch.StringSearch.init(
        allocator,
        search_items,
        .{
            .wildcard_spaces = true,
            .case_sensitive = false,
            .case_penalize = true,
        },
    );
    defer ss.deinit();

    var interactive_control: InteractiveControl = .{ .allocator = allocator };
    errdefer interactive_control.deinit();

    const index = try ss.interactiveDisplay(
        &interactive_control,
        Directory.Note,
        notes_list,
        .{
            .handleControl = InteractiveControl.handleControl,
            .drawItem = InteractiveControl.drawNote,
            .sortResults = InteractiveControl.sortResults,
        },
    );

    if (interactive_control.create_new) {
        return .{ .new = interactive_control.name.? };
    }

    // cleanup the interactive control if we're not going be using it
    interactive_control.deinit();
    if (index) |i| {
        return .{ .note = notes_list[i] };
    }
    return null;
}

fn sortLastModified(
    note_descriptors: []const Directory.Note,
    lhs: Result,
    rhs: Result,
) bool {
    if (lhs.scoreEqual(rhs)) {
        const lhs_info = note_descriptors[lhs.item.index];
        const rhs_info = note_descriptors[rhs.item.index];
        return Directory.Note.sortModified({}, lhs_info, rhs_info);
    }
    return lhs.scoreLessThan(rhs);
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
        // edit the existing item
        switch (item.*) {
            .Note => |*n| {
                try editNote(writer, allocator, root, n.note, &n.directory, e_opts, opts);
            },
            .Task => |*t| {
                // TODO: clean this flag up
                if (e_opts.path_only) {
                    try writer.print("{s}\n", .{maybe_item.?.getPath()});
                    return;
                }

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
                ptr.modified = time.Time.now();

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
                    return cli.throwError(
                        Root.Error.NoSuchCollection,
                        "Editing a day index as notes requires a directory of the same name as the journal ('{s}').",
                        .{d.journal.descriptor.name},
                    );
                };

                const sub_selection: selections.Selection = .{
                    .collection_name = d.journal.descriptor.name,
                    .collection_type = .CollectionDirectory,
                    .selector = .{
                        .ByDate = d.day.created.toDate(),
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
                // TODO: clean this flag up
                if (e_opts.path_only) {
                    try writer.print("{s}\n", .{maybe_item.?.getPath()});
                    return;
                }

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
                ptr.modified = time.Time.now();
                root.markModified(e.journal.descriptor, .CollectionJournal);

                try e.journal.writeDays();
                try root.writeChanges();
                try writer.print(
                    "Entry '{s}' in day '{s}' updated\n",
                    .{
                        try time.formatTimeBuf(
                            ptr.created.toDate(),
                        ),
                        try time.formatDateBuf(
                            e.day.created.toDate(),
                        ),
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
                opts,
            );
            defer allocator.free(path);
            if (e_opts.path_only) {
                try writer.print("{s}\n", .{path});
            } else {
                try becomeEditorRelativePath(allocator, &root.fs.?, path);
            }
        } else {
            // make sure was trying to select a note
            if (selection.collection_type == null) {
                return cli.throwError(
                    Root.Error.NoSuchItem,
                    "Use `--new` to allow new items to be created.",
                    .{},
                );
            } else {
                return cli.throwError(
                    Root.Error.NoSuchItem,
                    "Cannot create new item of selection type with edit.",
                    .{},
                );
            }
        }
    }
}

fn editNote(
    writer: anytype,
    allocator: std.mem.Allocator,
    root: *Root,
    n: Directory.Note,
    dir: *Directory,
    e_opts: EditOptions,
    _: commands.Options,
) !void {
    const note = try dir.touchNote(
        n,
        time.Time.now(),
    );
    root.markModified(
        dir.descriptor,
        .CollectionDirectory,
    );
    try root.writeChanges();

    if (e_opts.path_only) {
        try writer.print("{s}\n", .{note.path});
    } else {
        try becomeEditorRelativePath(
            allocator,
            &root.fs.?,
            note.path,
        );
    }
}

fn createNew(
    selection: selections.Selection,
    allocator: std.mem.Allocator,
    root: *Root,
    extension: []const u8,
    opts: commands.Options,
) ![]const u8 {
    if (selection.collection_type) |ctype| {
        const is_index = (ctype == .CollectionJournal and
            selection.selector.? == .ByIndex and
            !selection.collection_provided);
        if (ctype != .CollectionDirectory and !is_index) {
            try cli.throwError(
                Error.InvalidEdit,
                "Can only create new items with `edit` in directories ('{s}' is invalid).",
                .{@tagName(ctype)},
            );
        }
    }

    const sel = selection.selector.?;
    switch (sel) {
        .ByDate, .ByIndex => {
            const date = if (sel == .ByDate)
                sel.ByDate
            else
                time.shiftBack(time.Time.now(), sel.ByIndex);
            const cname = selection.collection_name orelse
                root.info.default_journal;
            const local_date = date;
            const date_string = try time.formatDateBuf(local_date);
            const template = try dateTemplate(allocator, local_date);
            return try createNewNote(
                allocator,
                cname,
                &date_string,
                root,
                extension,
                template,
                opts,
            );
        },
        .ByName => |name| {
            const cname = selection.collection_name orelse
                root.info.default_directory;
            return try createNewNote(
                allocator,
                cname,
                name,
                root,
                extension,
                null,
                opts,
            );
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
    _: commands.Options,
) ![]const u8 {
    var dir = (try root.getDirectory(collection_name)) orelse {
        try cli.throwError(
            Root.Error.NoSuchCollection,
            "No directory by name '{s}' exists",
            .{collection_name},
        );
        unreachable;
    };

    // assert the extension is a valid one
    if (!root.isKnownExtension(extension)) {
        try cli.throwError(
            Root.Error.UnknownExtension,
            "No text environment / compiler known for extension '{s}'. Consider adding one with `new`.",
            .{extension},
        );
        unreachable;
    }

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

fn noteNameValid(name: []const u8) bool {
    for (name) |c| {
        switch (c) {
            ' ' => return false,
            else => {},
        }
    }
    return true;
}
