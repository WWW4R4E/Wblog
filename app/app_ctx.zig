const std = @import("std");

const BlogPost = @import("types.zig").BlogPost;

pub const AppCtx = struct {
    blog_list: []BlogPost = &[_]BlogPost{},
    tag_map: std.StringHashMap(std.ArrayList(BlogPost)),
};
