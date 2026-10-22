//! markz — CommonMark markdown parser for Zig
//!
//! A standalone library implementing the CommonMark spec with extensions
//! for CriticMarkup and Obsidian-flavored markdown.
//!
//! ## Usage
//!
//! ```zig
//! const markz = @import("markz");
//!
//! var doc = try markz.parse(allocator, markdown_source);
//! defer doc.deinit();
//!
//! var iter = doc.iterator();
//! while (iter.next()) |event| {
//!     switch (event) {
//!         .enter => |node| { ... },
//!         .exit => |node| { ... },
//!         .leaf => |node| { ... },
//!     }
//! }
//! ```

const std = @import("std");

pub const ast = @import("ast.zig");
pub const block_parser = @import("block_parser.zig");
pub const inline_parser = @import("inline_parser.zig");
pub const html = @import("html.zig");

// Re-export HTML rendering
pub const renderHtml = html.renderHtml;

// Re-export core types
pub const Node = ast.Node;
pub const Tag = ast.Tag;
pub const Data = ast.Data;
pub const Document = ast.Document;
pub const SourceSpan = ast.SourceSpan;
pub const Event = ast.Event;
pub const TreeIterator = ast.TreeIterator;
pub const RefDef = ast.RefDef;
pub const Extensions = ast.Extensions;
pub const WikiLinkData = ast.WikiLinkData;
pub const Alignment = ast.Alignment;
pub const TableCellData = ast.TableCellData;
pub const TaskState = ast.TaskState;

/// Parse a markdown string into an AST document (no extensions).
pub fn parse(allocator: std.mem.Allocator, source: []const u8) !Document {
    return block_parser.parse(allocator, source);
}

/// Parse a markdown string with extension flags.
pub fn parseWith(allocator: std.mem.Allocator, source: []const u8, extensions: Extensions) !Document {
    return block_parser.parseWith(allocator, source, extensions);
}

// Pull in tests from submodules
test {
    _ = ast;
    _ = block_parser;
    _ = inline_parser;
    _ = html;
    _ = @import("case_fold.zig");
}

// ── Integration tests ──────────────────────────────────────────────────

test "parse empty string" {
    var doc = try parse(std.testing.allocator, "");
    defer doc.deinit();

    try std.testing.expectEqual(Tag.document, doc.root.tag);
    try std.testing.expectEqual(null, doc.root.first_child);
}

test "parse single paragraph" {
    var doc = try parse(std.testing.allocator, "Hello, world!");
    defer doc.deinit();

    const p = doc.root.first_child.?;
    try std.testing.expectEqual(Tag.paragraph, p.tag);
    const text = p.first_child.?;
    try std.testing.expectEqual(Tag.text, text.tag);
    try std.testing.expectEqualStrings("Hello, world!", doc.nodeText(text));
}

test "parse ATX heading" {
    var doc = try parse(std.testing.allocator, "# Hello");
    defer doc.deinit();

    const h = doc.root.first_child.?;
    try std.testing.expectEqual(Tag.heading, h.tag);
    try std.testing.expectEqual(@as(u3, 1), h.data.heading.level);
    const text = h.first_child.?;
    try std.testing.expectEqualStrings("Hello", doc.nodeText(text));
}

test "parse heading then paragraph" {
    var doc = try parse(std.testing.allocator,
        \\# Title
        \\
        \\Some text here.
    );
    defer doc.deinit();

    const h = doc.root.first_child.?;
    try std.testing.expectEqual(Tag.heading, h.tag);
    try std.testing.expectEqual(@as(u3, 1), h.data.heading.level);

    const p = h.next.?;
    try std.testing.expectEqual(Tag.paragraph, p.tag);
    const text = p.first_child.?;
    try std.testing.expectEqualStrings("Some text here.", doc.nodeText(text));
}

test "parse multi-line paragraph" {
    var doc = try parse(std.testing.allocator,
        \\First line
        \\second line
    );
    defer doc.deinit();

    const p = doc.root.first_child.?;
    try std.testing.expectEqual(Tag.paragraph, p.tag);
    const text1 = p.first_child.?;
    try std.testing.expectEqual(Tag.text, text1.tag);
    try std.testing.expectEqualStrings("First line", doc.nodeText(text1));
    const sb = text1.next.?;
    try std.testing.expectEqual(Tag.soft_break, sb.tag);
    const text2 = sb.next.?;
    try std.testing.expectEqual(Tag.text, text2.tag);
    try std.testing.expectEqualStrings("second line", doc.nodeText(text2));
}

test "parse multiple paragraphs" {
    var doc = try parse(std.testing.allocator,
        \\First paragraph.
        \\
        \\Second paragraph.
    );
    defer doc.deinit();

    const p1 = doc.root.first_child.?;
    try std.testing.expectEqual(Tag.paragraph, p1.tag);

    const p2 = p1.next.?;
    try std.testing.expectEqual(Tag.paragraph, p2.tag);

    try std.testing.expectEqual(null, p2.next);
}

test "parse heading levels" {
    var doc = try parse(std.testing.allocator,
        \\# H1
        \\## H2
        \\### H3
        \\#### H4
        \\##### H5
        \\###### H6
    );
    defer doc.deinit();

    var node = doc.root.first_child;
    var level: u3 = 1;
    while (node) |n| : (level += 1) {
        try std.testing.expectEqual(Tag.heading, n.tag);
        try std.testing.expectEqual(level, n.data.heading.level);
        node = n.next;
    }
    try std.testing.expectEqual(@as(u3, 7), level);
}

test "parse fenced code block in context" {
    const source = "# Title\n\n```zig\nconst x = 1;\n```\n\nAfter.";
    var doc = try parse(std.testing.allocator, source);
    defer doc.deinit();

    const h = doc.root.first_child.?;
    try std.testing.expectEqual(Tag.heading, h.tag);

    const cb = h.next.?;
    try std.testing.expectEqual(Tag.code_block, cb.tag);
    try std.testing.expectEqualStrings("zig", doc.getCodeBlockData(cb.data.code_block).info);
    const code_text = cb.first_child.?;
    try std.testing.expectEqualStrings("const x = 1;", doc.nodeText(code_text));

    const p = cb.next.?;
    try std.testing.expectEqual(Tag.paragraph, p.tag);
}

test "parse setext heading in context" {
    var doc = try parse(std.testing.allocator,
        \\Title
        \\=====
        \\
        \\Body text.
    );
    defer doc.deinit();

    const h = doc.root.first_child.?;
    try std.testing.expectEqual(Tag.heading, h.tag);
    try std.testing.expectEqual(@as(u3, 1), h.data.heading.level);
    try std.testing.expect(h.data.heading.setext);
    const text = h.first_child.?;
    try std.testing.expectEqualStrings("Title", doc.nodeText(text));

    const p = h.next.?;
    try std.testing.expectEqual(Tag.paragraph, p.tag);
}

test "parse list in context" {
    const source = "# Title\n\n- one\n- two\n\nAfter.";
    var doc = try parse(std.testing.allocator, source);
    defer doc.deinit();

    const h = doc.root.first_child.?;
    try std.testing.expectEqual(Tag.heading, h.tag);

    const list_node = h.next.?;
    try std.testing.expectEqual(Tag.list, list_node.tag);
    try std.testing.expect(!list_node.data.list.ordered);
    try std.testing.expect(list_node.data.list.tight);

    const item1 = list_node.first_child.?;
    try std.testing.expectEqualStrings("one", doc.nodeText(item1.first_child.?.first_child.?));
    const item2 = item1.next.?;
    try std.testing.expectEqualStrings("two", doc.nodeText(item2.first_child.?.first_child.?));

    const p = list_node.next.?;
    try std.testing.expectEqual(Tag.paragraph, p.tag);
    try std.testing.expectEqualStrings("After.", doc.nodeText(p.first_child.?));
}

test "parse ordered list starting at 5" {
    var doc = try parse(std.testing.allocator,
        \\5. five
        \\6. six
    );
    defer doc.deinit();

    const list_node = doc.root.first_child.?;
    try std.testing.expectEqual(Tag.list, list_node.tag);
    try std.testing.expect(list_node.data.list.ordered);
    try std.testing.expectEqual(@as(u32, 5), list_node.data.list.start);
}

// ── Extension integration tests ──────────────────────────────────────

test "mixed: frontmatter + critic + wikilink + tag" {
    const source = "---\ntitle: Test\n---\n\nSee {++new++} text and [[page|link]] with #tag.";
    var doc = try parseWith(std.testing.allocator, source, .{ .critic_markup = true, .obsidian = true });
    defer doc.deinit();

    // Frontmatter
    const fm = doc.root.first_child.?;
    try std.testing.expectEqual(Tag.frontmatter, fm.tag);
    try std.testing.expectEqualStrings("title: Test\n", doc.nodeText(fm));

    // Paragraph with mixed inline content
    const p = fm.next.?;
    try std.testing.expectEqual(Tag.paragraph, p.tag);

    // Walk inline children: "See " -> critic_insertion -> " text and " -> wiki_link -> " with " -> obsidian_tag -> "."
    var child = p.first_child;
    const t1 = child.?;
    try std.testing.expectEqualStrings("See ", doc.nodeText(t1));
    child = t1.next;

    const ins = child.?;
    try std.testing.expectEqual(Tag.critic_insertion, ins.tag);
    child = ins.next;

    const t2 = child.?;
    try std.testing.expectEqualStrings(" text and ", doc.nodeText(t2));
    child = t2.next;

    const wl = child.?;
    try std.testing.expectEqual(Tag.wiki_link, wl.tag);
    try std.testing.expectEqualStrings("page", doc.getWikiLinkData(wl.data.wiki_link).target);
    child = wl.next;

    const t3 = child.?;
    try std.testing.expectEqualStrings(" with ", doc.nodeText(t3));
    child = t3.next;

    const tag = child.?;
    try std.testing.expectEqual(Tag.obsidian_tag, tag.tag);
    try std.testing.expectEqualStrings("#tag", doc.nodeText(tag));
    child = tag.next;

    const t4 = child.?;
    try std.testing.expectEqualStrings(".", doc.nodeText(t4));
}

test "extensions off: standard markdown unchanged" {
    // Same standard markdown should produce identical results with and without extensions
    const source = "# Hello\n\n*emphasis* and **strong**\n\n- list item";
    var doc1 = try parse(std.testing.allocator, source);
    defer doc1.deinit();
    var doc2 = try parseWith(std.testing.allocator, source, .{ .critic_markup = true, .obsidian = true });
    defer doc2.deinit();

    const html1 = try renderHtml(std.testing.allocator, &doc1);
    defer std.testing.allocator.free(html1);
    const html2 = try renderHtml(std.testing.allocator, &doc2);
    defer std.testing.allocator.free(html2);

    try std.testing.expectEqualStrings(html1, html2);
}

test "critic markup inside code span is not parsed" {
    var doc = try parseWith(std.testing.allocator, "`{++not parsed++}`", .{ .critic_markup = true });
    defer doc.deinit();

    const p = doc.root.first_child.?;
    const code = p.first_child.?;
    try std.testing.expectEqual(Tag.code_span, code.tag);
    try std.testing.expectEqualStrings("{++not parsed++}", doc.nodeText(code));
}

test "gfm table HTML rendering" {
    var doc = try parseWith(std.testing.allocator,
        \\| Name | Age |
        \\|:-----|----:|
        \\| Alice | 30 |
    , .{ .gfm = true });
    defer doc.deinit();

    const result = try renderHtml(std.testing.allocator, &doc);
    defer std.testing.allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "<table>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "<th align=\"left\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "<th align=\"right\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "<td align=\"left\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Alice") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "</table>") != null);
}

test "gfm task list HTML rendering" {
    var doc = try parseWith(std.testing.allocator, "- [ ] todo\n- [x] done", .{ .gfm = true });
    defer doc.deinit();

    const result = try renderHtml(std.testing.allocator, &doc);
    defer std.testing.allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "<input type=\"checkbox\" disabled=\"\" />") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "<input type=\"checkbox\" checked=\"\" disabled=\"\" />") != null);
}
