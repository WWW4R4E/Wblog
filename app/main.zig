pub fn main() !void {
    const AppCtx = struct { blog_list: []md.BlogPost = &[_]md.BlogPost{} };

    const app_ctx = if (@import("builtin").target.cpu.arch != .wasm32)
        AppCtx{ .blog_list = try md.loadBlogPosts() }
    else
        return;

    var app = try zx.App(AppCtx).init(zx.allocator, .{}, app_ctx);
    defer app.deinit();

    try app.start();
}


const zx = @import("zx");

const md = @import("mdloader.zig");

