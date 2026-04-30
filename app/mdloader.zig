const std = @import("std");
const fs = std.fs;
const mem = std.mem;

const markz = @import("markz");
const BlogPost = @import("types.zig").BlogPost;
const BlogMeta = @import("types.zig").BlogMeta;

pub fn loadBlogPosts() ![]BlogPost {
    const allocator = std.heap.page_allocator;
    const markdown_dir = "app" ++ std.fs.path.sep_str ++ "assets" ++ std.fs.path.sep_str ++ "markdown";
    var dir = try fs.cwd().openDir(markdown_dir, .{ .iterate = true });
    defer dir.close();

    var index: usize = 0;
    var iter = dir.iterate();
    var posts: std.ArrayList(BlogPost) = .empty;
    defer posts.deinit(allocator);

    while (try iter.next()) |entry| {
        if (entry.kind == .file and mem.endsWith(u8, entry.name, ".md")) {
            const file_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ markdown_dir, entry.name });
            defer allocator.free(file_path);

            const content = try fs.cwd().readFileAlloc(allocator, file_path, 1024 * 1024);
            defer allocator.free(content);

            const post = try parseBlogPost(content, allocator, index);
            index += 1;
            try posts.append(allocator, post);
        }
    }

    return posts.toOwnedSlice(allocator);
}

fn parseBlogPost(content: []const u8, allocator: std.mem.Allocator, index: usize) !BlogPost {
    const metadata_start = mem.indexOf(u8, content, "---") orelse return error.InvalidMetadata;

    const metadata_end = mem.indexOf(u8, content[metadata_start + 3 ..], "---") orelse return error.InvalidMetadata;
    const actual_end = metadata_start + 3 + metadata_end;

    const metadata = mem.trim(u8, content[metadata_start + 3 .. actual_end], "\n");

    var date: ?[]const u8 = null;
    var category: ?[]const u8 = null;
    var read_time: ?[]const u8 = null;
    var title: ?[]const u8 = null;
    var excerpt: ?[]const u8 = null;
    var tags: std.ArrayList([]const u8) = .empty;
    defer tags.deinit(allocator);

    var lines = std.mem.splitSequence(u8, metadata, "\n");
    while (lines.next()) |line| {
        const trimmed = mem.trim(u8, line, " ");
        if (mem.startsWith(u8, trimmed, "date: ")) {
            date = mem.trim(u8, trimmed[6..], "\"");
            if (date.?.len == 0) return error.EmptyDate;
        } else if (mem.startsWith(u8, trimmed, "category: ")) {
            category = mem.trim(u8, trimmed[10..], "\"");
            if (category.?.len == 0) return error.EmptyCategory;
        } else if (mem.startsWith(u8, trimmed, "read_time: ")) {
            read_time = mem.trim(u8, trimmed[11..], "\"");
            if (read_time.?.len == 0) return error.EmptyReadTime;
        } else if (mem.startsWith(u8, trimmed, "title: ")) {
            title = mem.trim(u8, trimmed[7..], "\"");
            if (title.?.len == 0) return error.EmptyTitle;
        } else if (mem.startsWith(u8, trimmed, "excerpt: ")) {
            excerpt = mem.trim(u8, trimmed[9..], "\"");
            if (excerpt.?.len == 0) return error.EmptyExcerpt;
        } else if (mem.startsWith(u8, trimmed, "tags: ")) {
            const tags_str = mem.trim(u8, trimmed[7..], "[]");
            var tag_items = mem.splitSequence(u8, tags_str, ",");
            while (tag_items.next()) |tag| {
                const trimmed_tag = mem.trim(u8, tag, " \"");
                if (trimmed_tag.len > 0) {
                    try tags.append(allocator, try allocator.dupe(u8, trimmed_tag));
                }
            }
        }
    }

    if (date == null or category == null or read_time == null or title == null or excerpt == null) {
        return error.MissingRequiredFields;
    }

    return BlogPost{
        .index = try std.fmt.allocPrint(allocator, "{d}", .{index}),
        .meta = BlogMeta{
            .date = try allocator.dupe(u8, date.?),
            .category = try allocator.dupe(u8, category.?),
            .read_time = try allocator.dupe(u8, read_time.?),
        },
        .title = try allocator.dupe(u8, title.?),
        .excerpt = try allocator.dupe(u8, excerpt.?),
        .tags = try tags.toOwnedSlice(allocator),
        .content = try allocator.dupe(u8, content[actual_end + 3 ..]),
    };
}

pub fn markdownToHtml(markdown: []const u8) ![]const u8 {
    const allocator = std.heap.page_allocator;
    const html = blk: {
        var doc = try markz.parseWith(allocator, markdown, .{
            .gfm = true,
            .critic_markup = true,
            .obsidian = true,
        });
        defer doc.deinit();
        break :blk try markz.renderHtml(allocator, &doc);
    };
    return html;
}

