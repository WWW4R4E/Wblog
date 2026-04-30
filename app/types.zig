pub const BlogPost = struct {
    index: []const u8,
    meta: BlogMeta,
    title: []const u8,
    excerpt: []const u8,
    tags: []const []const u8,
    content: []const u8,
};

pub const BlogMeta = struct {
    date: []const u8,
    category: []const u8,
    read_time: []const u8,
};
