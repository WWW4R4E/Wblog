const std = @import("std");
const ast = @import("ast.zig");
const block_parser = @import("block_parser.zig");
const Node = ast.Node;
const Tag = ast.Tag;
const Document = ast.Document;
const SourceSpan = ast.SourceSpan;

/// Render a parsed CommonMark document to HTML.
/// Caller owns the returned slice and must free it with `allocator`.
pub fn renderHtml(allocator: std.mem.Allocator, doc: *const Document) ![]const u8 {
    var r = Renderer{
        .doc = doc,
        .buf = .empty,
        .allocator = allocator,
        .in_tight_list = false,
        .tight_stack = .empty,
        .in_image = false,
    };
    defer r.buf.deinit(allocator);
    defer r.tight_stack.deinit(allocator);

    // Pre-size output buffer (HTML is typically ~1.5x input size)
    try r.buf.ensureTotalCapacity(allocator, doc.source.len + doc.source.len / 2);

    var iter = doc.iterator();
    while (iter.next()) |event| {
        switch (event) {
            .enter => |node| try r.handleEnter(node),
            .exit => |node| try r.handleExit(node),
            .leaf => |node| try r.handleLeaf(node),
        }
    }

    return try r.buf.toOwnedSlice(allocator);
}

const Renderer = struct {
    doc: *const Document,
    buf: std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    in_tight_list: bool,
    tight_stack: std.ArrayListUnmanaged(bool),
    in_image: bool,

    const BW = struct {
        buf: *std.ArrayListUnmanaged(u8),
        gpa: std.mem.Allocator,

        fn writeAll(self: BW, bytes: []const u8) !void {
            try self.buf.appendSlice(self.gpa, bytes);
        }

        fn print(self: BW, comptime fmt: []const u8, args: anytype) !void {
            try self.buf.print(self.gpa, fmt, args);
        }
    };

    fn w(self: *Renderer) BW {
        return .{ .buf = &self.buf, .gpa = self.allocator };
    }

    fn handleEnter(self: *Renderer, node: *Node) !void {
        if (self.in_image) return;

        switch (node.tag) {
            .document => {},
            .block_quote => {
                try self.tight_stack.append(self.allocator, self.in_tight_list);
                self.in_tight_list = false;
                try self.w().writeAll("<blockquote>\n");
            },
            .list => {
                const ld = node.data.list;
                try self.tight_stack.append(self.allocator, self.in_tight_list);
                self.in_tight_list = ld.tight;
                if (ld.ordered) {
                    try self.w().writeAll("<ol");
                    if (ld.start != 1) {
                        try self.w().print(" start=\"{}\"", .{ld.start});
                    }
                    try self.w().writeAll(">\n");
                } else {
                    try self.w().writeAll("<ul>\n");
                }
            },
            .list_item => {
                if (!self.in_tight_list) {
                    if (node.first_child != null) {
                        try self.w().writeAll("<li>\n");
                    } else {
                        try self.w().writeAll("<li>");
                    }
                } else {
                    // In tight list, add newline if first child is a block element (not paragraph)
                    const first = node.first_child;
                    if (first != null and first.?.tag != .paragraph and first.?.tag.isBlock()) {
                        try self.w().writeAll("<li>\n");
                    } else {
                        try self.w().writeAll("<li>");
                    }
                }
                // GFM task list checkbox
                switch (node.data) {
                    .task_state => |ts| switch (ts) {
                        .unchecked => try self.w().writeAll("<input type=\"checkbox\" disabled=\"\" /> "),
                        .checked => try self.w().writeAll("<input type=\"checkbox\" checked=\"\" disabled=\"\" /> "),
                        .none => {},
                    },
                    else => {},
                }
            },
            .heading => {
                try self.w().writeAll(h_open[node.data.heading.level]);
            },
            .paragraph => {
                if (!self.in_tight_list) {
                    try self.w().writeAll("<p>");
                }
            },
            .emphasis => try self.w().writeAll("<em>"),
            .strong => try self.w().writeAll("<strong>"),
            .link => {
                const link = self.doc.getLinkData(node.data.link);
                try self.w().writeAll("<a href=\"");
                try escapeHref(self.w(), link.destination);
                try self.w().writeAll("\"");
                if (link.title.len > 0) {
                    try self.w().writeAll(" title=\"");
                    try escapeHtml(self.w(), link.title);
                    try self.w().writeAll("\"");
                }
                try self.w().writeAll(">");
            },
            .image => {
                const img = self.doc.getLinkData(node.data.image);
                try self.w().writeAll("<img src=\"");
                try escapeHref(self.w(), img.destination);
                try self.w().writeAll("\" alt=\"");
                const alt = collectAltText(self.doc, node);
                try escapeHtml(self.w(), alt);
                try self.w().writeAll("\"");
                if (img.title.len > 0) {
                    try self.w().writeAll(" title=\"");
                    try escapeHtml(self.w(), img.title);
                    try self.w().writeAll("\"");
                }
                try self.w().writeAll(" />");
                self.in_image = true;
            },
            // CriticMarkup containers
            .critic_insertion => try self.w().writeAll("<ins>"),
            .critic_deletion => try self.w().writeAll("<del>"),
            .critic_highlight => try self.w().writeAll("<mark>"),
            .critic_substitution => {},
            // GFM tables
            .table => try self.w().writeAll("<table>\n"),
            .table_head => try self.w().writeAll("<thead>\n"),
            .table_body => try self.w().writeAll("<tbody>\n"),
            .table_row => try self.w().writeAll("<tr>\n"),
            .table_cell => {
                const cd = node.data.table_cell;
                const tag = if (cd.is_header) "th" else "td";
                try self.w().print("<{s}", .{tag});
                switch (cd.alignment) {
                    .left => try self.w().writeAll(" align=\"left\""),
                    .center => try self.w().writeAll(" align=\"center\""),
                    .right => try self.w().writeAll(" align=\"right\""),
                    .none => {},
                }
                try self.w().writeAll(">");
            },
            // Obsidian wiki link
            .wiki_link => {
                const wl = self.doc.getWikiLinkData(node.data.wiki_link);
                try self.w().writeAll("<a href=\"");
                try escapeHref(self.w(), wl.target);
                try self.w().writeAll("\" class=\"wikilink\">");
            },
            else => {},
        }
    }

    fn handleExit(self: *Renderer, node: *Node) !void {
        // Image node exit: clear flag but don't render child close tags
        if (node.tag == .image) {
            self.in_image = false;
            return;
        }
        // Skip close tags for nodes inside an image
        if (self.in_image) return;

        switch (node.tag) {
            .document => {},
            .block_quote => {
                try self.w().writeAll("</blockquote>\n");
                self.in_tight_list = self.tight_stack.pop().?;
            },
            .list => {
                try self.w().writeAll(if (node.data.list.ordered) "</ol>\n" else "</ul>\n");
                self.in_tight_list = self.tight_stack.pop().?;
            },
            .list_item => try self.w().writeAll("</li>\n"),
            .heading => {
                try self.w().writeAll(h_close[node.data.heading.level]);
            },
            .paragraph => {
                if (!self.in_tight_list) {
                    try self.w().writeAll("</p>\n");
                } else if (node.next != null) {
                    // In tight list, add newline between paragraph and next sibling block
                    try self.w().writeAll("\n");
                }
            },
            .emphasis => try self.w().writeAll("</em>"),
            .strong => try self.w().writeAll("</strong>"),
            .link => try self.w().writeAll("</a>"),
            // CriticMarkup
            .critic_insertion => try self.w().writeAll("</ins>"),
            .critic_deletion => try self.w().writeAll("</del>"),
            .critic_highlight => try self.w().writeAll("</mark>"),
            .critic_substitution => {},
            // GFM tables
            .table => try self.w().writeAll("</table>\n"),
            .table_head => try self.w().writeAll("</thead>\n"),
            .table_body => try self.w().writeAll("</tbody>\n"),
            .table_row => try self.w().writeAll("</tr>\n"),
            .table_cell => {
                const tag = if (node.data.table_cell.is_header) "th" else "td";
                try self.w().print("</{s}>\n", .{tag});
            },
            // Obsidian
            .wiki_link => try self.w().writeAll("</a>"),
            else => {},
        }
    }

    fn handleLeaf(self: *Renderer, node: *Node) !void {
        if (self.in_image) return;

        switch (node.tag) {
            .thematic_break => try self.w().writeAll("<hr />\n"),
            .code_block => {
                const info_str = self.doc.getCodeBlockData(node.data.code_block).info;
                if (info_str.len > 0) {
                    // Use first word of info string as language
                    const lang = if (std.mem.indexOfScalar(u8, info_str, ' ')) |i| info_str[0..i] else info_str;
                    try self.w().writeAll("<pre><code class=\"language-");
                    try escapeHtml(self.w(), lang);
                    try self.w().writeAll("\">");
                } else {
                    try self.w().writeAll("<pre><code>");
                }
                if (node.first_child) |child| {
                    try escapeHtml(self.w(), self.doc.nodeText(child));
                    try self.w().writeAll("\n");
                }
                try self.w().writeAll("</code></pre>\n");
            },
            .html_block => {
                const text = self.doc.nodeText(node);
                try self.w().writeAll(text);
                try self.w().writeAll("\n");
            },
            .text => {
                try escapeHtml(self.w(), self.doc.nodeText(node));
            },
            .code_span => {
                try self.w().writeAll("<code>");
                try escapeHtml(self.w(), self.doc.nodeText(node));
                try self.w().writeAll("</code>");
            },
            .autolink => {
                const text = self.doc.nodeText(node);
                // Email autolinks have @ but no URI scheme (no colon before @)
                const at_pos = std.mem.indexOfScalar(u8, text, '@');
                const colon_pos = std.mem.indexOfScalar(u8, text, ':');
                const is_email = at_pos != null and
                    (colon_pos == null or colon_pos.? > at_pos.?);
                try self.w().writeAll("<a href=\"");
                if (is_email) try self.w().writeAll("mailto:");
                try escapeHref(self.w(), text);
                try self.w().writeAll("\">");
                try escapeHtml(self.w(), text);
                try self.w().writeAll("</a>");
            },
            .html_inline => {
                try self.w().writeAll(self.doc.nodeText(node));
            },
            .soft_break => try self.w().writeAll("\n"),
            .hard_break => try self.w().writeAll("<br />\n"),
            // CriticMarkup comment (leaf)
            .critic_comment => {
                try self.w().writeAll("<span class=\"critic-comment\">");
                try escapeHtml(self.w(), self.doc.nodeText(node));
                try self.w().writeAll("</span>");
            },
            // Obsidian tag (leaf)
            .obsidian_tag => {
                try self.w().writeAll("<span class=\"tag\">");
                try escapeHtml(self.w(), self.doc.nodeText(node));
                try self.w().writeAll("</span>");
            },
            // Frontmatter is metadata, not rendered
            .frontmatter => {},
            else => {},
        }
    }
};

/// Escape &, <, >, " for HTML text content.
/// Uses SIMD-accelerated scanning to skip runs of safe characters in bulk.
fn escapeHtml(writer: anytype, text: []const u8) !void {
    const specials = [_]u8{ '&', '<', '>', '"' };
    var pos: usize = 0;
    while (pos < text.len) {
        if (std.mem.indexOfAnyPos(u8, text, pos, &specials)) |esc_pos| {
            if (esc_pos > pos) try writer.writeAll(text[pos..esc_pos]);
            switch (text[esc_pos]) {
                '&' => try writer.writeAll("&amp;"),
                '<' => try writer.writeAll("&lt;"),
                '>' => try writer.writeAll("&gt;"),
                '"' => try writer.writeAll("&quot;"),
                else => unreachable,
            }
            pos = esc_pos + 1;
        } else {
            try writer.writeAll(text[pos..]);
            break;
        }
    }
}

/// Escape a URL for use in an href or src attribute.
/// Percent-encodes bytes not valid in URLs, HTML-escapes &.
/// Scans runs of safe characters in bulk (same pattern as escapeHtml).
fn escapeHref(writer: anytype, text: []const u8) !void {
    var pos: usize = 0;
    while (pos < text.len) {
        const start = pos;
        while (pos < text.len and url_safe_table[text[pos]]) : (pos += 1) {}
        if (start < pos) try writer.writeAll(text[start..pos]);
        if (pos >= text.len) break;
        const c = text[pos];
        if (c == '&') {
            try writer.writeAll("&amp;");
        } else {
            try writer.writeAll(&[_]u8{ '%', hex_digits[c >> 4], hex_digits[c & 0xF] });
        }
        pos += 1;
    }
}

const hex_digits = "0123456789ABCDEF";

/// Precomputed heading tags indexed by level (1-6). Index 0 unused.
const h_open = [_][]const u8{ "", "<h1>", "<h2>", "<h3>", "<h4>", "<h5>", "<h6>" };
const h_close = [_][]const u8{ "", "</h1>\n", "</h2>\n", "</h3>\n", "</h4>\n", "</h5>\n", "</h6>\n" };

/// 256-byte lookup table for URL-safe characters.
const url_safe_table = blk: {
    var table: [256]bool = @splat(false);
    for ("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789") |c| table[c] = true;
    for ("-._~:/?#@!$'()*+,;=%") |c| table[c] = true;
    break :blk table;
};


/// Recursively collect plain text from all descendants of a node (for image alt text).
fn collectAltText(doc: *const Document, node: *const Node) []const u8 {
    // For images, the alt text is the concatenation of all text descendant content.
    // We walk children recursively. Since inline parser already allocated all text
    // as arena literals, for the common single-text-child case we can return directly.
    if (node.first_child) |child| {
        if (child.tag == .text and child.next == null) {
            return doc.nodeText(child);
        }
    } else {
        return "";
    }

    // Multiple children or nested containers — need to concatenate.
    // We need a mutable arena reference. The Document owns the arena but
    // passes it as const. We use @constCast since we're only appending
    // (the arena is designed for monotonic growth).
    var result: std.ArrayListUnmanaged(u8) = .empty;
    const arena = @constCast(&doc.arena).allocator();
    collectAltTextRecurse(doc, node, &result, arena);
    return result.items;
}

fn collectAltTextRecurse(doc: *const Document, node: *const Node, result: *std.ArrayListUnmanaged(u8), arena: std.mem.Allocator) void {
    var child = node.first_child;
    while (child) |c| : (child = c.next) {
        switch (c.tag) {
            .text => {
                result.appendSlice(arena, doc.nodeText(c)) catch {};
            },
            .soft_break, .hard_break => {
                result.append(arena, ' ') catch {};
            },
            else => {
                if (c.tag.isContainer()) {
                    collectAltTextRecurse(doc, c, result, arena);
                }
            },
        }
    }
}

// ── Tests ──────────────────────────────────────────────────────────────

fn testRender(source: []const u8) ![]const u8 {
    var doc = try block_parser.parse(std.testing.allocator, source);
    defer doc.deinit();
    return try renderHtml(std.testing.allocator, &doc);
}

test "html: empty document" {
    const html = try testRender("");
    defer std.testing.allocator.free(html);
    try std.testing.expectEqualStrings("", html);
}

test "html: single paragraph" {
    const html = try testRender("Hello, world!");
    defer std.testing.allocator.free(html);
    try std.testing.expectEqualStrings("<p>Hello, world!</p>\n", html);
}

test "html: heading levels" {
    const html = try testRender("# H1\n## H2\n### H3");
    defer std.testing.allocator.free(html);
    try std.testing.expectEqualStrings("<h1>H1</h1>\n<h2>H2</h2>\n<h3>H3</h3>\n", html);
}

test "html: thematic break" {
    const html = try testRender("---");
    defer std.testing.allocator.free(html);
    try std.testing.expectEqualStrings("<hr />\n", html);
}

test "html: fenced code block with language" {
    const html = try testRender("```zig\nconst x = 1;\n```");
    defer std.testing.allocator.free(html);
    try std.testing.expectEqualStrings("<pre><code class=\"language-zig\">const x = 1;\n</code></pre>\n", html);
}

test "html: fenced code block without language" {
    const html = try testRender("```\nhello\n```");
    defer std.testing.allocator.free(html);
    try std.testing.expectEqualStrings("<pre><code>hello\n</code></pre>\n", html);
}

test "html: blockquote" {
    const html = try testRender("> Hello");
    defer std.testing.allocator.free(html);
    try std.testing.expectEqualStrings("<blockquote>\n<p>Hello</p>\n</blockquote>\n", html);
}

test "html: unordered list" {
    const html = try testRender("- one\n- two");
    defer std.testing.allocator.free(html);
    try std.testing.expectEqualStrings("<ul>\n<li>one</li>\n<li>two</li>\n</ul>\n", html);
}

test "html: ordered list with start" {
    const html = try testRender("5. five\n6. six");
    defer std.testing.allocator.free(html);
    try std.testing.expectEqualStrings("<ol start=\"5\">\n<li>five</li>\n<li>six</li>\n</ol>\n", html);
}

test "html: loose list with paragraphs" {
    const html = try testRender("- alpha\n\n- beta");
    defer std.testing.allocator.free(html);
    try std.testing.expectEqualStrings("<ul>\n<li>\n<p>alpha</p>\n</li>\n<li>\n<p>beta</p>\n</li>\n</ul>\n", html);
}

test "html: emphasis and strong" {
    const html = try testRender("*em* and **strong**");
    defer std.testing.allocator.free(html);
    try std.testing.expectEqualStrings("<p><em>em</em> and <strong>strong</strong></p>\n", html);
}

test "html: link with title" {
    const html = try testRender("[text](/url \"title\")");
    defer std.testing.allocator.free(html);
    try std.testing.expectEqualStrings("<p><a href=\"/url\" title=\"title\">text</a></p>\n", html);
}

test "html: link without title" {
    const html = try testRender("[click](http://example.com)");
    defer std.testing.allocator.free(html);
    try std.testing.expectEqualStrings("<p><a href=\"http://example.com\">click</a></p>\n", html);
}

test "html: image" {
    const html = try testRender("![alt text](/img.png)");
    defer std.testing.allocator.free(html);
    try std.testing.expectEqualStrings("<p><img src=\"/img.png\" alt=\"alt text\" /></p>\n", html);
}

test "html: code span" {
    const html = try testRender("Use `code` here");
    defer std.testing.allocator.free(html);
    try std.testing.expectEqualStrings("<p>Use <code>code</code> here</p>\n", html);
}

test "html: hard break" {
    const html = try testRender("hello\\\nworld");
    defer std.testing.allocator.free(html);
    try std.testing.expectEqualStrings("<p>hello<br />\nworld</p>\n", html);
}

test "html: soft break" {
    const html = try testRender("hello\nworld");
    defer std.testing.allocator.free(html);
    try std.testing.expectEqualStrings("<p>hello\nworld</p>\n", html);
}

test "html: text escaping" {
    const html = try testRender("1 < 2 & 3 > 0");
    defer std.testing.allocator.free(html);
    try std.testing.expectEqualStrings("<p>1 &lt; 2 &amp; 3 &gt; 0</p>\n", html);
}

test "html: autolink URL" {
    const html = try testRender("see <http://example.com> here");
    defer std.testing.allocator.free(html);
    try std.testing.expectEqualStrings("<p>see <a href=\"http://example.com\">http://example.com</a> here</p>\n", html);
}

test "html: autolink email" {
    const html = try testRender("mail <user@example.com> now");
    defer std.testing.allocator.free(html);
    try std.testing.expectEqualStrings("<p>mail <a href=\"mailto:user@example.com\">user@example.com</a> now</p>\n", html);
}

// Extension rendering tests

fn testRenderExt(source: []const u8, extensions: ast.Extensions) ![]const u8 {
    var doc = try block_parser.parseWith(std.testing.allocator, source, extensions);
    defer doc.deinit();
    return try renderHtml(std.testing.allocator, &doc);
}

test "html: critic insertion" {
    const result = try testRenderExt("text {++added++} here", .{ .critic_markup = true });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("<p>text <ins>added</ins> here</p>\n", result);
}

test "html: critic deletion" {
    const result = try testRenderExt("{--removed--}", .{ .critic_markup = true });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("<p><del>removed</del></p>\n", result);
}

test "html: critic highlight" {
    const result = try testRenderExt("{==important==}", .{ .critic_markup = true });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("<p><mark>important</mark></p>\n", result);
}

test "html: critic comment" {
    const result = try testRenderExt("{>>a note<<}", .{ .critic_markup = true });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("<p><span class=\"critic-comment\">a note</span></p>\n", result);
}

test "html: critic substitution" {
    const result = try testRenderExt("{~~old~>new~~}", .{ .critic_markup = true });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("<p><del>old</del><ins>new</ins></p>\n", result);
}

test "html: wiki link" {
    const result = try testRenderExt("see [[page]]", .{ .obsidian = true });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("<p>see <a href=\"page\" class=\"wikilink\">page</a></p>\n", result);
}

test "html: wiki link with display" {
    const result = try testRenderExt("[[page|click here]]", .{ .obsidian = true });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("<p><a href=\"page\" class=\"wikilink\">click here</a></p>\n", result);
}

test "html: obsidian tag" {
    const result = try testRenderExt("hello #tag world", .{ .obsidian = true });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("<p>hello <span class=\"tag\">#tag</span> world</p>\n", result);
}

test "html: frontmatter not rendered" {
    const result = try testRenderExt("---\ntitle: Hello\n---\n\nBody text.", .{ .obsidian = true });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("<p>Body text.</p>\n", result);
}

// GFM table rendering tests

test "html: table basic no alignment" {
    const result = try testRenderExt(
        \\| A | B |
        \\|---|---|
        \\| 1 | 2 |
    , .{ .gfm = true });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings(
        \\<table>
        \\<thead>
        \\<tr>
        \\<th>A</th>
        \\<th>B</th>
        \\</tr>
        \\</thead>
        \\<tbody>
        \\<tr>
        \\<td>1</td>
        \\<td>2</td>
        \\</tr>
        \\</tbody>
        \\</table>
        \\
    , result);
}

test "html: table all alignments" {
    const result = try testRenderExt(
        \\| Left | Center | Right | None |
        \\|:-----|:------:|------:|------|
        \\| a    | b      | c     | d    |
    , .{ .gfm = true });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings(
        \\<table>
        \\<thead>
        \\<tr>
        \\<th align="left">Left</th>
        \\<th align="center">Center</th>
        \\<th align="right">Right</th>
        \\<th>None</th>
        \\</tr>
        \\</thead>
        \\<tbody>
        \\<tr>
        \\<td align="left">a</td>
        \\<td align="center">b</td>
        \\<td align="right">c</td>
        \\<td>d</td>
        \\</tr>
        \\</tbody>
        \\</table>
        \\
    , result);
}

test "html: table multi-row body" {
    const result = try testRenderExt(
        \\| H |
        \\|---|
        \\| r1 |
        \\| r2 |
        \\| r3 |
    , .{ .gfm = true });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings(
        \\<table>
        \\<thead>
        \\<tr>
        \\<th>H</th>
        \\</tr>
        \\</thead>
        \\<tbody>
        \\<tr>
        \\<td>r1</td>
        \\</tr>
        \\<tr>
        \\<td>r2</td>
        \\</tr>
        \\<tr>
        \\<td>r3</td>
        \\</tr>
        \\</tbody>
        \\</table>
        \\
    , result);
}

test "html: table header only" {
    const result = try testRenderExt(
        \\| A | B |
        \\|---|---|
    , .{ .gfm = true });
    defer std.testing.allocator.free(result);
    // Header-only table: no tbody
    try std.testing.expect(std.mem.indexOf(u8, result, "<thead>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "<th>A</th>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "<th>B</th>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "</table>") != null);
}

test "html: table inline formatting in cells" {
    const result = try testRenderExt(
        \\| **bold** | *em* | `code` |
        \\|----------|------|--------|
        \\| [link](/url) | normal | ~~del~~ |
    , .{ .gfm = true });
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "<strong>bold</strong>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "<em>em</em>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "<code>code</code>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "<a href=\"/url\">link</a>") != null);
}

test "html: table text escaping in cells" {
    const result = try testRenderExt(
        \\| a & b | 1 < 2 |
        \\|-------|-------|
        \\| x > y | "z"   |
    , .{ .gfm = true });
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "a &amp; b") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "1 &lt; 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "x &gt; y") != null);
}

// GFM task list rendering tests

test "html: task list unchecked" {
    const result = try testRenderExt("- [ ] todo item", .{ .gfm = true });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings(
        \\<ul>
        \\<li><input type="checkbox" disabled="" /> todo item</li>
        \\</ul>
        \\
    , result);
}

test "html: task list checked" {
    const result = try testRenderExt("- [x] done item", .{ .gfm = true });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings(
        \\<ul>
        \\<li><input type="checkbox" checked="" disabled="" /> done item</li>
        \\</ul>
        \\
    , result);
}

test "html: task list mixed with normal items" {
    const result = try testRenderExt("- [ ] todo\n- [x] done\n- normal", .{ .gfm = true });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings(
        \\<ul>
        \\<li><input type="checkbox" disabled="" /> todo</li>
        \\<li><input type="checkbox" checked="" disabled="" /> done</li>
        \\<li>normal</li>
        \\</ul>
        \\
    , result);
}

test "html: task list in ordered list" {
    const result = try testRenderExt("1. [ ] first\n2. [x] second", .{ .gfm = true });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings(
        \\<ol>
        \\<li><input type="checkbox" disabled="" /> first</li>
        \\<li><input type="checkbox" checked="" disabled="" /> second</li>
        \\</ol>
        \\
    , result);
}

// Comprehensive round-trip test covering all element types

test "html: kitchen sink — all elements" {
    const source =
        \\# ATX Heading 1
        \\
        \\## ATX Heading 2
        \\
        \\Setext H1
        \\=========
        \\
        \\Setext H2
        \\---------
        \\
        \\Plain paragraph with *emphasis*, **strong**, ***both***, `code span`,
        \\a [link](/url "title"), an ![image](/img.png "alt"), and <http://auto.link>,
        \\plus <user@mail.com> for email.
        \\
        \\Hard break\
        \\next line.
        \\
        \\> Blockquote with **bold**
        \\>
        \\> > Nested blockquote
        \\
        \\---
        \\
        \\- tight one
        \\- tight two
        \\- tight three
        \\
        \\1. ordered one
        \\2. ordered two
        \\
        \\- loose one
        \\
        \\- loose two
        \\
        \\```zig
        \\const x = 1;
        \\```
        \\
        \\    indented code
        \\
        \\Backslash: \*not emphasis\*
        \\
        \\Entity: &amp; and &#42;
    ;
    const html = try testRender(source);
    defer std.testing.allocator.free(html);

    // ATX headings
    try std.testing.expect(std.mem.indexOf(u8, html, "<h1>ATX Heading 1</h1>\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<h2>ATX Heading 2</h2>\n") != null);

    // Setext headings
    try std.testing.expect(std.mem.indexOf(u8, html, "<h1>Setext H1</h1>\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<h2>Setext H2</h2>\n") != null);

    // Inline formatting
    try std.testing.expect(std.mem.indexOf(u8, html, "<em>emphasis</em>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<strong>strong</strong>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<code>code span</code>") != null);

    // Link with title
    try std.testing.expect(std.mem.indexOf(u8, html, "<a href=\"/url\" title=\"title\">link</a>") != null);

    // Image
    try std.testing.expect(std.mem.indexOf(u8, html, "<img src=\"/img.png\" alt=\"image\"") != null);

    // Autolinks
    try std.testing.expect(std.mem.indexOf(u8, html, "<a href=\"http://auto.link\">http://auto.link</a>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<a href=\"mailto:user@mail.com\">user@mail.com</a>") != null);

    // Hard break
    try std.testing.expect(std.mem.indexOf(u8, html, "<br />\n") != null);

    // Blockquote
    try std.testing.expect(std.mem.indexOf(u8, html, "<blockquote>\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "</blockquote>\n") != null);

    // Thematic break
    try std.testing.expect(std.mem.indexOf(u8, html, "<hr />\n") != null);

    // Tight list
    try std.testing.expect(std.mem.indexOf(u8, html, "<li>tight one</li>\n") != null);

    // Ordered list
    try std.testing.expect(std.mem.indexOf(u8, html, "<ol>\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "</ol>\n") != null);

    // Loose list (items wrapped in <p>)
    try std.testing.expect(std.mem.indexOf(u8, html, "<li>\n<p>loose one</p>\n</li>\n") != null);

    // Fenced code block
    try std.testing.expect(std.mem.indexOf(u8, html, "<pre><code class=\"language-zig\">const x = 1;\n</code></pre>\n") != null);

    // Indented code block
    try std.testing.expect(std.mem.indexOf(u8, html, "<pre><code>indented code\n</code></pre>\n") != null);

    // Backslash escape
    try std.testing.expect(std.mem.indexOf(u8, html, "*not emphasis*") != null);

    // Entity decoding
    try std.testing.expect(std.mem.indexOf(u8, html, "&amp;") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "*") != null);
}

test "html: kitchen sink — all extensions combined" {
    const source =
        \\---
        \\title: Test
        \\---
        \\
        \\# Heading
        \\
        \\Paragraph with **bold**, *em*, `code`, and [link](/url).
        \\
        \\> A blockquote
        \\
        \\- [ ] unchecked task
        \\- [x] checked task
        \\- normal item
        \\
        \\| Left | Center | Right |
        \\|:-----|:------:|------:|
        \\| a    | b      | c     |
        \\| d    | e      | f     |
        \\
        \\Text with {++insertion++} and {--deletion--} here.
        \\
        \\And {==highlighted==} plus {>>a comment<<}.
        \\
        \\Substitution: {~~old~>new~~}.
        \\
        \\See [[PageName]] and [[target|display text]] and #my-tag.
        \\
        \\```
        \\code block
        \\```
        \\
        \\---
    ;
    const all_ext: ast.Extensions = .{ .gfm = true, .critic_markup = true, .obsidian = true };
    const html = try testRenderExt(source, all_ext);
    defer std.testing.allocator.free(html);

    // Frontmatter NOT rendered
    try std.testing.expect(std.mem.indexOf(u8, html, "title: Test") == null);

    // Heading
    try std.testing.expect(std.mem.indexOf(u8, html, "<h1>Heading</h1>\n") != null);

    // Inline formatting preserved
    try std.testing.expect(std.mem.indexOf(u8, html, "<strong>bold</strong>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<em>em</em>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<code>code</code>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<a href=\"/url\">link</a>") != null);

    // Blockquote
    try std.testing.expect(std.mem.indexOf(u8, html, "<blockquote>\n<p>A blockquote</p>\n</blockquote>\n") != null);

    // Task list
    try std.testing.expect(std.mem.indexOf(u8, html, "<input type=\"checkbox\" disabled=\"\" /> unchecked task") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<input type=\"checkbox\" checked=\"\" disabled=\"\" /> checked task") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<li>normal item</li>\n") != null);

    // Table with alignments
    try std.testing.expect(std.mem.indexOf(u8, html, "<table>\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<th align=\"left\">Left</th>\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<th align=\"center\">Center</th>\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<th align=\"right\">Right</th>\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<td align=\"left\">a</td>\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<td align=\"center\">e</td>\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "</table>\n") != null);

    // CriticMarkup
    try std.testing.expect(std.mem.indexOf(u8, html, "<ins>insertion</ins>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<del>deletion</del>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<mark>highlighted</mark>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<span class=\"critic-comment\">a comment</span>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<del>old</del><ins>new</ins>") != null);

    // Obsidian wiki links
    try std.testing.expect(std.mem.indexOf(u8, html, "<a href=\"PageName\" class=\"wikilink\">PageName</a>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<a href=\"target\" class=\"wikilink\">display text</a>") != null);

    // Obsidian tag
    try std.testing.expect(std.mem.indexOf(u8, html, "<span class=\"tag\">#my-tag</span>") != null);

    // Code block
    try std.testing.expect(std.mem.indexOf(u8, html, "<pre><code>code block\n</code></pre>\n") != null);

    // Thematic break
    try std.testing.expect(std.mem.indexOf(u8, html, "<hr />\n") != null);
}

test "html: kitchen sink — nested elements in lists" {
    const source =
        \\- **bold item** and *emphasis*
        \\- `code` and [link](/url "title")
        \\- ![img](/pic.png)
        \\
        \\1. item with <http://autolink.com>
        \\2. item with `code span`
        \\
        \\- outer one
        \\    - nested bullet
        \\    - nested two
        \\- outer two
        \\
        \\1. ordered outer
        \\    - mixed nested bullet
        \\
        \\- loose with blockquote
        \\
        \\  > quoted inside item
        \\
        \\- loose with code block
        \\
        \\  ```
        \\  code in list
        \\  ```
        \\
        \\- loose with paragraph
        \\
        \\  Second paragraph in item.
    ;
    const html = try testRender(source);
    defer std.testing.allocator.free(html);

    // Inline formatting inside tight list items
    try std.testing.expect(std.mem.indexOf(u8, html, "<li><strong>bold item</strong> and <em>emphasis</em></li>\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<li><code>code</code> and <a href=\"/url\" title=\"title\">link</a></li>\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<img src=\"/pic.png\" alt=\"img\" />") != null);

    // Autolink inside ordered list
    try std.testing.expect(std.mem.indexOf(u8, html, "<a href=\"http://autolink.com\">http://autolink.com</a>") != null);

    // Nested list (inner <ul> inside <li>)
    try std.testing.expect(std.mem.indexOf(u8, html, "<li>nested bullet</li>\n") != null);

    // Blockquote inside loose list item
    try std.testing.expect(std.mem.indexOf(u8, html, "<blockquote>\n<p>quoted inside item</p>\n</blockquote>\n") != null);

    // Fenced code block inside loose list item
    try std.testing.expect(std.mem.indexOf(u8, html, "<pre><code>code in list\n</code></pre>\n") != null);

    // Multi-paragraph loose list item
    try std.testing.expect(std.mem.indexOf(u8, html, "<p>Second paragraph in item.</p>\n") != null);
}
