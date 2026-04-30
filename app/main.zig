pub fn main() !void {
    const TagMap = std.StringHashMap(std.ArrayList(BlogPost));
    var tag_map = TagMap.init(zx.allocator);
    defer tag_map.deinit();

    var blog_list: []BlogPost = &.{};
    if (@import("builtin").target.cpu.arch != .wasm32) {
        const md = @import("mdloader.zig");
        blog_list = try md.loadBlogPosts();
        for (blog_list) |item| {
            for (item.tags) |tag| {
                const entry = try tag_map.getOrPut(tag);
                if (!entry.found_existing) {
                    entry.value_ptr.* = std.ArrayList(BlogPost).empty;
                }
                try entry.value_ptr.append(zx.allocator, item);
            }
        }
    }

    const app_ctx = AppCtx{ .blog_list = blog_list, .tag_map = tag_map };

    var app = try zx.App(AppCtx).init(zx.allocator, .{}, app_ctx);
    // defer app.deinit();

    try app.start();
}

const std = @import("std");

const zx = @import("zx");

const AppCtx = @import("app_ctx.zig").AppCtx;
const BlogPost = @import("types.zig").BlogPost;
