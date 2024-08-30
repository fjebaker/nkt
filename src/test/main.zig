const std = @import("std");
const utils = @import("utils.zig");
const exec = utils.testExecute;

test "smoke" {
    var s = try utils.TestState.init();
    defer s.deinit();

    // basic commands work
    try exec(&s, &.{"help"});
    try exec(&s, &.{"init"});
    try exec(&s, &.{"config"});
    try exec(&s, &.{ "log", "hello world" });
    try exec(&s, &.{ "new", "tag", "abc" });

    // inline tags
    try exec(&s, &.{ "log", "hello world @abc" });

    // seperate tags
    try exec(&s, &.{ "log", "hello", "@abc" });

    // task creation
    try exec(&s, &.{ "task", "do something", "--due", "1999-01-01" });
    try exec(&s, &.{ "task", "do something", "soon", "--due", "1999-01-01" });

    // retrieval for tasks
    s.clearOutput();
    try exec(&s, &.{ "ls", "--tasklist", "todo" });
    try std.testing.expectEqualStrings(
        \\
        \\   1   10592d 12h 59m   | /b2ac5 |   do something
        \\   0   10592d 12h 59m   | /79fc7 |   do something - soon
        \\
        \\
    ,
        s.stdout.items,
    );

    // reading back log items
    s.clearOutput();
    try exec(&s, &.{"read"});
    try std.testing.expectEqualStrings(
        \\
        \\## Journal: 1970-01-01 Thursday of January
        \\
        \\00:00:10 | hello world
        \\00:00:10 | hello world @abc @
        \\00:00:10 | hello @
        \\00:00:10 | created 'do something' (/b2ac5)
        \\00:00:10 | created 'do something' (/79fc7)
        \\
        \\
    ,
        s.stdout.items,
    );

    // creating new notes
    try std.testing.expectError(
        error.NoSuchItem,
        exec(&s, &.{ "edit", "nkt" }),
    );
    try std.testing.expectError(
        error.NoExecveInTest,
        exec(&s, &.{ "edit", "nkt", "-n" }),
    );

    // get the filepath of the note we just created
    s.clearOutput();
    try exec(&s, &.{ "edit", "nkt", "--path-only" });
    try std.testing.expectEqualStrings(
        "dir.notes/nkt.md\n",
        s.stdout.items,
    );

    // write some content to the file
    try s.writeToFile("dir.notes/nkt.md", "Hello World!");

    // try and read it back
    s.clearOutput();
    try exec(&s, &.{ "r", "nkt" });
    try std.testing.expectEqualStrings(
        "Hello World!",
        s.stdout.items,
    );

    // rename the note
    try exec(&s, &.{ "mv", "nkt", "hello" });

    // try and read it back again
    try std.testing.expectError(
        error.UnknownSelection,
        exec(&s, &.{ "r", "nkt" }),
    );
    s.clearOutput();
    try exec(&s, &.{ "r", "hello" });
    try std.testing.expectEqualStrings(
        "Hello World!",
        s.stdout.items,
    );
}
