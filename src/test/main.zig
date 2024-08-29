const utils = @import("utils.zig");
const testExecute = utils.testExecute;

test "end-to-end" {
    var state = try utils.TestState.init();
    defer state.deinit();

    // basic commands work
    try testExecute(&state, &.{"help"});
    try testExecute(&state, &.{"init"});
    try testExecute(&state, &.{"config"});
    try testExecute(&state, &.{ "log", "hello world" });
    try testExecute(&state, &.{ "new", "tag", "abc" });

    // inline tags
    try testExecute(&state, &.{ "log", "hello world @abc" });

    // seperate tags
    try testExecute(&state, &.{ "log", "hello", "@abc" });

    // task creation
    try testExecute(&state, &.{ "task", "do something", "--due", "monday" });
    try testExecute(&state, &.{ "task", "do something", "soon", "--due", "monday" });

    // retrieval
    try testExecute(&state, &.{ "ls", "--tasklist", "todo" });
    try testExecute(&state, &.{"read"});
}
