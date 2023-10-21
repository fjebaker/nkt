const std = @import("std");

const cli = @import("../cli.zig");
const utils = @import("../utils.zig");

const Commands = @import("../main.zig").Commands;
const State = @import("../NewState.zig");

const Self = @This();

pub const alias = [_][]const u8{"r"};

pub const help = "Display the contentes of notes in various ways";
pub const extended_help =
    \\Print the contents of a journal or note to stdout
    \\  nkt read
    \\     <what>                what to print: name of a journal, or a note
    \\                             entry. if choice is ambiguous, will print both,
    \\                             else specify with the `--journal` or `--dir`
    \\                             flags
    \\     [--journal name]      name of journal to read from
    \\     [--dir name]          name of directory to read from
    \\     [-n/--limit int]      maximum number of entries to display (default: 25)
    \\     [--all]               display all items (overwrites `--limit`)
    \\
;

const Selection = cli.selections.Selection;
const ContainerSelection = cli.selections.ContainerSelection;

selection: Selection,
where: ?ContainerSelection,
number: usize,
all: bool,

pub fn init(itt: *cli.ArgIterator) !Self {
    var self: Self = .{
        .selection = Selection.today(),
        .where = null,
        .number = 25,
        .all = false,
    };

    itt.counter = 0;
    while (try itt.next()) |arg| {
        if (arg.flag) {
            if (arg.is('n', "limit")) {
                const value = try itt.getValue();
                self.number = try value.as(usize);
            } else if (arg.is(null, "all")) {
                self.all = true;
            } else if (arg.is(null, "journal")) {
                if (self.where == null) {
                    const value = try itt.getValue();
                    self.where = ContainerSelection.from(.Journal, value.string);
                }
            } else if (arg.is(null, "dir") or arg.is(null, "directory")) {
                if (self.where == null) {
                    const value = try itt.getValue();
                    self.where = ContainerSelection.from(.Directory, value.string);
                }
            } else {
                return cli.CLIErrors.UnknownFlag;
            }
        } else {
            if (arg.index.? > 1) return cli.CLIErrors.TooManyArguments;
            self.selection = try Selection.parse(arg.string);
        }
    }

    return self;
}

pub fn run(
    self: *Self,
    state: *State,
    out_writer: anytype,
) !void {
    const collection = cli.selections.find(state, self.where, self.selection);
    std.debug.print("{any}\n", .{self.where});
    try out_writer.print("selected: {any}\n", .{collection});
}

// fn readDiary(
//     entry: notes.diary.Entry,
//     out_writer: anytype,
//     limit: usize,
// ) !void {
//     try out_writer.print("Notes for {s}\n", .{try utils.formatDateBuf(entry.date)});

//     const offset = @min(entry.notes.len, limit);
//     const start = entry.notes.len - offset;

//     for (entry.notes[start..]) |note| {
//         const time_of_day = utils.adjustTimezone(utils.Date.initUnixMs(note.modified));
//         try time_of_day.format("HH:mm:ss - ", .{}, out_writer);
//         try out_writer.print("{s}\n", .{note.content});
//     }
// }

// fn readDiaryContent(
//     state: *State,
//     entry: *notes.diary.Entry,
//     out_writer: anytype,
// ) !void {
//     try out_writer.print(
//         "Diary entry for {s}\n",
//         .{try utils.formatDateBuf(entry.date)},
//     );

//     const content = try entry.readDiary(state);
//     _ = try out_writer.writeAll(content);
// }

// fn readLastNotes(
//     self: Self,
//     state: *State,
//     out_writer: anytype,
// ) !void {
//     var alloc = state.mem.allocator();

//     var date_list = try list.getDiaryDateList(state);
//     defer date_list.deinit();

//     date_list.sort();

//     // calculate how many diary entries we need
//     var needed = std.ArrayList(*notes.diary.Entry).init(alloc);
//     var note_count: usize = 0;
//     for (0..date_list.items.len) |i| {
//         const date = date_list.items[date_list.items.len - i - 1];

//         var entry = try state.openDiaryEntry(date);
//         try needed.append(entry);

//         // tally how many entries we'd print now
//         note_count += entry.notes.len;
//         if (note_count >= self.number) break;
//     }

//     std.mem.reverse(*notes.diary.Entry, needed.items);

//     // print the first one truncated
//     const difference = note_count -| self.number;
//     try readDiary(needed.items[0].*, out_writer, needed.items[0].notes.len - difference);

//     // print the rest
//     if (needed.items.len > 1) {
//         for (needed.items[1..]) |entry| {
//             try readDiary(entry.*, out_writer, note_count);
//             note_count -|= entry.notes.len;
//         }
//     }
// }

// fn readNamedNode(self: Self, state: *State, out_writer: anytype) !void {
//     var note = self.selection.?;
//     const rel_path = try note.getRelPath(state);

//     if (try state.fs.fileExists(rel_path)) {
//         var content = try state.fs.readFileAlloc(state.mem.allocator(), rel_path);
//         _ = try out_writer.writeAll(content);
//     } else {
//         return notes.NoteError.NoSuchNote;
//     }
// }

// fn readEntry(
//     self: Self,
//     state: *State,
//     out_writer: anytype,
// ) !void {
//     var note = self.selection.?;
//     const date = try note.getDate(state);

//     var entry = try state.openDiaryEntry(date);

//     if (entry.has_diary) try readDiaryContent(
//         state,
//         entry,
//         out_writer,
//     );
//     try readDiary(entry.*, out_writer, self.number);
// }
