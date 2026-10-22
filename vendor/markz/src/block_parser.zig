const std = @import("std");
const ast = @import("ast.zig");
const entities = @import("entities.zig");
const case_fold = @import("case_fold.zig");
const inline_parser = @import("inline_parser.zig");
const Node = ast.Node;
const Tag = ast.Tag;
const Data = ast.Data;
const Document = ast.Document;
const SourceSpan = ast.SourceSpan;

const MAX_BQ_DEPTH = 16;

/// State for an open fenced code block.
const FenceState = struct {
    fence_char: u8,
    fence_len: u8,
    fence_indent: u3,
    info: []const u8,
    content_buf: std.ArrayListUnmanaged(u8),
    has_content: bool,
    node_start: usize,
    bq_depth: usize,
};

/// State for an open indented code block.
const IndentCodeState = struct {
    content_buf: std.ArrayListUnmanaged(u8),
    node_start: usize,
    node_end: usize,
    pending_blanks: usize,
    bq_depth: usize,
};

/// HTML block type.
const HtmlBlockType = enum { type1, type6, type7 };

/// State for an open HTML block.
const HtmlBlockState = struct {
    html_type: HtmlBlockType,
    content_buf: std.ArrayListUnmanaged(u8),
    node_start: usize,
    bq_depth: usize,
    close_str: ?[]const u8,
};

/// State for paragraph accumulation.
const ParaState = struct {
    active: bool = false,
    source_start: usize = 0,
    source_end: usize = 0,
    buf: std.ArrayListUnmanaged(u8) = .empty,
    in_container: bool = false,

    fn reset(self: *ParaState) void {
        self.active = false;
        self.buf.clearRetainingCapacity();
    }
};

/// Deferred inline parsing — stores (node, text) pairs for second pass.
const PendingInline = struct {
    node: *Node,
    text: []const u8,
};

/// State for an open list.
const ListState = struct {
    node: *Node,
    item_node: *Node,
    marker: u8, // '-', '*', '+', '.', ')'
    ordered: bool,
    content_indent: usize,
    had_blank: bool,
    tight: bool,
    bq_depth: usize,
    item_buf: std.ArrayListUnmanaged(u8),
    item_has_content: bool,
    pending_blanks: usize,
};

/// State for an open GFM table.
const TableState = struct {
    node: *Node, // the table node
    body: *Node, // the tbody node
    col_count: usize,
    alignments: [max_cols]ast.Alignment,
    bq_depth: usize,

    const max_cols = 64;
};

/// Parse markdown source into an AST document (no extensions).
pub fn parse(allocator: std.mem.Allocator, source: []const u8) !Document {
    return parseWith(allocator, source, .{});
}

/// Parse markdown source with extension flags.
pub fn parseWith(allocator: std.mem.Allocator, source: []const u8, extensions: ast.Extensions) !Document {
    var doc = try Document.init(allocator, source, extensions);
    errdefer doc.deinit();
    var pending_inlines: std.ArrayListUnmanaged(PendingInline) = .empty;
    _ = try parseBlocks(&doc, doc.root, source, &pending_inlines, false);

    // Second pass: parse inlines now that all link reference definitions are collected
    for (pending_inlines.items) |pi| {
        try inline_parser.parseInlines(&doc, pi.node, pi.text);
    }
    return doc;
}

/// Parse block-level content and append children to `parent`.
/// Returns true if blank lines occurred between top-level blocks (for tight/loose detection).
fn parseBlocks(
    doc: *Document,
    parent: *Node,
    source: []const u8,
    pending_inlines: *std.ArrayListUnmanaged(PendingInline),
    is_sub_parse: bool,
) error{OutOfMemory}!bool {
    const arena = doc.arena.allocator();

    // Container stack: container_stack[0] = parent
    var container_stack: [MAX_BQ_DEPTH + 1]*Node = undefined;
    container_stack[0] = parent;
    var bq_depth: usize = 0;

    var para: ParaState = .{};
    var fence: ?FenceState = null;
    var list: ?ListState = null;
    var indent_code: ?IndentCodeState = null;
    var html_block: ?HtmlBlockState = null;
    var table: ?TableState = null;

    // Track blank lines between top-level blocks for tight/loose detection
    var had_blank_at_top: bool = false;
    var top_block_count: usize = 0;
    var had_blank_between_blocks: bool = false;

    var line_start: usize = 0;

    // Frontmatter detection (only at document root, not in sub-parses)
    if (!is_sub_parse and doc.extensions.obsidian) {
        if (tryParseFrontmatter(source)) |fm| {
            const node = try doc.createNode(.frontmatter, .{ .content = .{
                .start = fm.content_start,
                .end = fm.content_end,
            } }, .{ .start = 0, .end = fm.block_end });
            parent.appendChild(node);
            line_start = fm.block_end;
        }
    }

    while (line_start < source.len) {
        const line_end = if (std.mem.indexOfScalarPos(u8, source, line_start, '\n')) |pos| pos else source.len;
        const line = source[line_start..line_end];

        if (fence) |*f| {
            // Inside fenced code block — strip markers up to fence depth, check for close
            var stripped = line;
            var bq_stripped: usize = 0;
            for (0..f.bq_depth) |_| {
                if (try tryStripBqMarker(stripped, arena)) |s| {
                    stripped = s;
                    bq_stripped += 1;
                } else break;
            }

            // If line doesn't have enough BQ markers, close the fence and re-process
            if (bq_stripped < f.bq_depth) {
                try closeFencedCodeBlock(doc, f, container_stack[f.bq_depth], line_start, line_end);
                fence = null;
                continue; // re-process this line through normal parsing
            }

            if (tryParseClosingFence(stripped, f.fence_char, f.fence_len)) {
                try closeFencedCodeBlock(doc, f, container_stack[f.bq_depth], line_start, line_end);
                fence = null;
            } else {
                // Strip up to fence_indent spaces from content line
                var content_line = stripped;
                var spaces_stripped: u3 = 0;
                while (spaces_stripped < f.fence_indent and content_line.len > 0 and content_line[0] == ' ') {
                    content_line = content_line[1..];
                    spaces_stripped += 1;
                }
                if (f.has_content) try f.content_buf.append(arena, '\n');
                f.has_content = true;
                try f.content_buf.appendSlice(arena, content_line);
            }
        } else if (html_block) |*hb| {
            // Inside HTML block — strip BQ markers, check end condition
            var stripped = line;
            for (0..hb.bq_depth) |_| {
                stripped = try tryStripBqMarker(stripped, arena) orelse break;
            }

            if (hb.html_type == .type1) {
                // Type 1: include every line; end when close_str found
                if (hb.content_buf.items.len > 0) try hb.content_buf.append(arena, '\n');
                try hb.content_buf.appendSlice(arena, stripped);
                if (hb.close_str) |cs| {
                    if (containsIgnoreCase(stripped, cs)) {
                        try closeHtmlBlock(doc, hb, container_stack[hb.bq_depth], line_end);
                        html_block = null;
                    }
                }
            } else {
                // Type 6/7: blank line ends block (not included in content)
                const check = std.mem.trimStart(u8, stripped, " \t");
                if (check.len == 0) {
                    try closeHtmlBlock(doc, hb, container_stack[hb.bq_depth], line_end);
                    html_block = null;
                } else {
                    if (hb.content_buf.items.len > 0) try hb.content_buf.append(arena, '\n');
                    try hb.content_buf.appendSlice(arena, stripped);
                }
            }
        } else {
            // GFM table continuation — check before list/normal processing
            if (table) |*tbl| {
                var tbl_closed = false;
                var tbl_stripped = line;
                for (0..tbl.bq_depth) |_| {
                    tbl_stripped = try tryStripBqMarker(tbl_stripped, arena) orelse {
                        tbl.node.source.end = line_start;
                        tbl_closed = true;
                        break;
                    };
                }
                if (!tbl_closed) {
                    const tbl_trimmed = std.mem.trimStart(u8, tbl_stripped, " \t");
                    if (tbl_trimmed.len == 0 or std.mem.indexOfScalar(u8, tbl_trimmed, '|') == null) {
                        tbl.node.source.end = line_start;
                        tbl_closed = true;
                    } else {
                        // Data row
                        const row = try buildTableRow(doc, arena, tbl_trimmed, tbl.col_count, tbl.alignments, false, line_start, line_end, pending_inlines);
                        tbl.body.appendChild(row);
                        tbl.node.source.end = line_end;
                        if (line_end >= source.len) break;
                        line_start = line_end + 1;
                        continue;
                    }
                }
                if (tbl_closed) table = null;
            }

            // Check list continuation BEFORE full BQ stripping.
            // Strip only the BQ markers matching the list's depth, then check
            // if the remaining content is indented enough for continuation.
            // This prevents inner > markers (part of item content) from being
            // treated as outer BQ markers.
            if (list) |*ls| {
                if (ls.bq_depth == bq_depth) {
                    var pre_stripped = line;
                    var pre_bq_ok = true;
                    for (0..ls.bq_depth) |_| {
                        if (try tryStripBqMarker(pre_stripped, arena)) |rest| {
                            pre_stripped = rest;
                        } else {
                            pre_bq_ok = false;
                            break;
                        }
                    }
                    if (pre_bq_ok) {
                        const line_indent = computeIndent(pre_stripped);
                        if (line_indent.columns >= ls.content_indent and (ls.item_has_content or !ls.had_blank)) {
                            const line_trimmed = pre_stripped[line_indent.bytes..];
                            if (line_trimmed.len > 0) {
                                // Continuation line — strip content_indent columns
                                const content = try stripAndExpandCols(arena, pre_stripped, ls.content_indent, 0);
                                for (0..ls.pending_blanks) |_| {
                                    try ls.item_buf.append(arena, '\n');
                                }
                                if (ls.pending_blanks > 0) ls.had_blank = false;
                                ls.pending_blanks = 0;
                                if (ls.item_has_content) try ls.item_buf.append(arena, '\n');
                                try ls.item_buf.appendSlice(arena, content);
                                ls.item_has_content = true;
                                ls.item_node.source.end = line_end;
                                ls.node.source.end = line_end;
                                if (line_end >= source.len) break;
                                line_start = line_end + 1;
                                continue;
                            }
                        }
                    } else if (ls.item_has_content and ls.pending_blanks == 0) {
                        // BQ markers insufficient — check for lazy continuation
                        // through nested structures (e.g., line lazily continues a
                        // paragraph inside a blockquote within this list item)
                        const lazy_trimmed = std.mem.trimStart(u8, line, " \t");
                        if (lazy_trimmed.len > 0 and !canStartBlock(lazy_trimmed) and
                            tryParseListMarker(lazy_trimmed) == null)
                        {
                            if (ls.item_has_content) try ls.item_buf.append(arena, '\n');
                            try ls.item_buf.appendSlice(arena, lazy_trimmed);
                            ls.item_node.source.end = line_end;
                            ls.node.source.end = line_end;
                            if (line_end >= source.len) break;
                            line_start = line_end + 1;
                            continue;
                        }
                    }
                }
            }

            // Strip blockquote markers and count depth
            var stripped = line;
            var new_depth: usize = 0;
            while (new_depth < MAX_BQ_DEPTH) {
                if (try tryStripBqMarker(stripped, arena)) |rest| {
                    new_depth += 1;
                    stripped = rest;
                } else break;
            }

            // Lazy continuation: if we're in a deeper blockquote with an active paragraph,
            // a non-blank line without enough > markers continues that paragraph,
            // unless the line could start a new block structure.
            if (new_depth < bq_depth and para.active and
                fence == null and indent_code == null and html_block == null)
            {
                const lazy_trimmed = std.mem.trimStart(u8, stripped, " \t");
                if (lazy_trimmed.len > 0 and !canStartBlock(lazy_trimmed)) {
                    // Continue the paragraph at the current depth (lazy continuation)
                    try startOrContinuePara(&para, arena, lazy_trimmed, line_start, line_end, true);
                    if (bq_depth > 0) {
                        container_stack[bq_depth].source.end = line_end;
                    }
                    if (line_end >= source.len) break;
                    line_start = line_end + 1;
                    continue;
                }
            }

            // Close deeper levels
            while (bq_depth > new_depth) {
                if (indent_code) |*ic| {
                    if (ic.bq_depth == bq_depth) {
                        try closeIndentedCodeBlock(doc, ic, container_stack[bq_depth]);
                        indent_code = null;
                    }
                }
                if (list) |*ls| {
                    if (ls.bq_depth == bq_depth) {
                        try flushListItem(doc, arena, ls, pending_inlines);
                        ls.node.data.list.tight = ls.tight;
                        list = null;
                    }
                }
                if (para.active) {
                    try flushParagraph(doc, arena, &para, container_stack[bq_depth], pending_inlines);
                }
                bq_depth -= 1;
            }

            // Open new levels
            while (bq_depth < new_depth) {
                if (indent_code) |*ic| {
                    if (ic.bq_depth == bq_depth) {
                        try closeIndentedCodeBlock(doc, ic, container_stack[bq_depth]);
                        indent_code = null;
                    }
                }
                if (list) |*ls| {
                    if (ls.bq_depth == bq_depth) {
                        try flushListItem(doc, arena, ls, pending_inlines);
                        ls.node.data.list.tight = ls.tight;
                        list = null;
                    }
                }
                if (para.active) {
                    try flushParagraph(doc, arena, &para, container_stack[bq_depth], pending_inlines);
                }
                bq_depth += 1;
                const bq = try doc.createNode(.block_quote, .{ .none = {} }, .{ .start = line_start, .end = line_end });
                container_stack[bq_depth - 1].appendChild(bq);
                container_stack[bq_depth] = bq;
            }

            // Update blockquote source span to cover this line
            if (bq_depth > 0) {
                container_stack[bq_depth].source.end = line_end;
            }

            const indent_info = computeIndent(stripped);
            const indent = indent_info.columns;
            const trimmed = stripped[indent_info.bytes..];

            // ── List handling ──
            var list_handled: bool = false;
            if (list) |*ls| {
                if (bq_depth != ls.bq_depth) {
                    // BQ depth changed — close list
                    if (ls.pending_blanks > 0) had_blank_at_top = true;
                    try flushListItem(doc, arena, ls, pending_inlines);
                    ls.node.data.list.tight = ls.tight;
                    list = null;
                } else if (trimmed.len == 0) {
                    // Blank line in list
                    ls.pending_blanks += 1;
                    ls.had_blank = true;
                    list_handled = true;
                } else {
                    if (indent >= ls.content_indent and (ls.item_has_content or !ls.had_blank)) {
                        // Continuation line — strip content_indent columns
                        // Use tab-expanding strip to ensure correct column positions in sub-parse
                        const content = try stripAndExpandCols(arena, stripped, ls.content_indent, 0);
                        // Add pending blanks to item buffer
                        for (0..ls.pending_blanks) |_| {
                            try ls.item_buf.append(arena, '\n');
                        }
                        if (ls.pending_blanks > 0) ls.had_blank = false;
                        ls.pending_blanks = 0;
                        if (ls.item_has_content) try ls.item_buf.append(arena, '\n');
                        try ls.item_buf.appendSlice(arena, content);
                        ls.item_has_content = true;
                        ls.item_node.source.end = line_end;
                        ls.node.source.end = line_end;
                        list_handled = true;
                    } else if (indent < 4 and !tryParseThematicBreak(trimmed)) {
                        // Check for new same-type item
                        if (tryParseListMarker(trimmed)) |marker| {
                            if (ls.ordered == marker.ordered and ls.marker == marker.marker) {
                                try flushListItem(doc, arena, ls, pending_inlines);
                                if (ls.had_blank) ls.tight = false;
                                ls.had_blank = false;
                                ls.pending_blanks = 0;
                                const item = try doc.createNode(.list_item, .{ .none = {} }, .{
                                    .start = line_start,
                                    .end = line_end,
                                });
                                ls.node.appendChild(item);
                                ls.item_node = item;
                                ls.content_indent = indent + marker.content_col_offset;
                                ls.node.source.end = line_end;
                                ls.item_buf.clearRetainingCapacity();
                                ls.item_has_content = false;
                                if (marker.content_offset < trimmed.len) {
                                    const content = try stripAndExpandCols(arena, trimmed[marker.marker_end..], marker.content_col_offset, marker.marker_end);
                                    if (content.len > 0) {
                                        try ls.item_buf.appendSlice(arena, content);
                                        ls.item_has_content = true;
                                    }
                                }
                                list_handled = true;
                            }
                        }
                        if (!list_handled) {
                            // Check for lazy continuation: paragraph text can
                            // continue without full indentation.
                            // At indent < 4, list markers block lazy continuation
                            // (they may start a new list of a different type).
                            if (ls.item_has_content and ls.pending_blanks == 0 and
                                !canStartBlock(trimmed) and tryParseListMarker(trimmed) == null)
                            {
                                if (ls.item_has_content) try ls.item_buf.append(arena, '\n');
                                try ls.item_buf.appendSlice(arena, trimmed);
                                ls.item_node.source.end = line_end;
                                ls.node.source.end = line_end;
                                list_handled = true;
                            } else {
                                // Not a continuation and not a sibling — close list
                                if (ls.pending_blanks > 0) had_blank_at_top = true;
                                try flushListItem(doc, arena, ls, pending_inlines);
                                ls.node.data.list.tight = ls.tight;
                                list = null;
                            }
                        }
                    } else {
                        // indent >= 4 or thematic break
                        // Check for lazy continuation
                        if (ls.item_has_content and ls.pending_blanks == 0 and !canStartBlock(trimmed)) {
                            if (ls.item_has_content) try ls.item_buf.append(arena, '\n');
                            // Add 4 spaces so the sub-parser treats this as paragraph
                            // continuation (indented lines can't interrupt paragraphs),
                            // preventing list markers from being mis-detected.
                            try ls.item_buf.appendSlice(arena, "    ");
                            try ls.item_buf.appendSlice(arena, trimmed);
                            ls.item_node.source.end = line_end;
                            ls.node.source.end = line_end;
                            list_handled = true;
                        } else {
                            // Not a continuation — close list
                            if (ls.pending_blanks > 0) had_blank_at_top = true;
                            try flushListItem(doc, arena, ls, pending_inlines);
                            ls.node.data.list.tight = ls.tight;
                            list = null;
                        }
                    }
                }
            }

            if (!list_handled) {
                const block_parent = container_stack[bq_depth];
                const in_container = is_sub_parse or bq_depth > 0;

                if (trimmed.len == 0) {
                    // Blank line
                    if (para.active) try flushParagraph(doc, arena, &para, block_parent, pending_inlines);
                    if (indent_code) |*ic| {
                        if (indent >= 4) {
                            const code_strip = stripCols(stripped, 4, 0);
                            const remainder_content = stripped[code_strip.offset..];
                            if (remainder_content.len > 0 or code_strip.remainder > 0) {
                                // Preserve indentation beyond 4 columns as content
                                for (0..ic.pending_blanks) |_| try ic.content_buf.append(arena, '\n');
                                ic.pending_blanks = 0;
                                if (ic.content_buf.items.len > 0) try ic.content_buf.append(arena, '\n');
                                for (0..code_strip.remainder) |_| try ic.content_buf.append(arena, ' ');
                                try ic.content_buf.appendSlice(arena, remainder_content);
                                ic.node_end = line_end;
                            } else {
                                ic.pending_blanks += 1;
                            }
                        } else {
                            ic.pending_blanks += 1;
                        }
                    }
                    had_blank_at_top = true;
                } else if (indent >= 4) {
                    if (para.active) {
                        // Indented code blocks cannot interrupt a paragraph
                        try startOrContinuePara(&para, arena, stripped, line_start, line_end, in_container);
                    } else {
                        // Start or continue indented code block
                        // Strip 4 columns of indent for code content
                        const code_strip = stripCols(stripped, 4, 0);
                        const code_content = stripped[code_strip.offset..];

                        if (indent_code) |*ic| {
                            // Flush pending blanks
                            for (0..ic.pending_blanks) |_| {
                                try ic.content_buf.append(arena, '\n');
                            }
                            ic.pending_blanks = 0;
                            if (ic.content_buf.items.len > 0) try ic.content_buf.append(arena, '\n');
                            // Add remainder spaces from partial tab
                            for (0..code_strip.remainder) |_| try ic.content_buf.append(arena, ' ');
                            try ic.content_buf.appendSlice(arena, code_content);
                            ic.node_end = line_end;
                        } else {
                            if (had_blank_at_top and top_block_count > 0) had_blank_between_blocks = true;
                            top_block_count += 1;
                            had_blank_at_top = false;
                            indent_code = .{
                                .content_buf = .empty,
                                .node_start = line_start,
                                .node_end = line_end,
                                .pending_blanks = 0,
                                .bq_depth = bq_depth,
                            };
                            // Add remainder spaces from partial tab
                            for (0..code_strip.remainder) |_| try indent_code.?.content_buf.append(arena, ' ');
                            try indent_code.?.content_buf.appendSlice(arena, code_content);
                        }
                    }
                } else {
                    // Close indented code block on non-blank, non-indented line
                    if (indent_code) |*ic| {
                        try closeIndentedCodeBlock(doc, ic, block_parent);
                        indent_code = null;
                    }

                    if (tryParseAtxHeading(trimmed)) |heading| {
                        if (para.active) try flushParagraph(doc, arena, &para, block_parent, pending_inlines);
                        if (had_blank_at_top and top_block_count > 0) had_blank_between_blocks = true;
                        top_block_count += 1;
                        had_blank_at_top = false;

                        const h = try doc.createNode(.heading, .{ .heading = .{
                            .level = heading.level,
                            .setext = false,
                        } }, .{ .start = line_start, .end = line_end });

                        block_parent.appendChild(h);
                        if (heading.content.len > 0) {
                            try pending_inlines.append(arena, .{ .node = h, .text = heading.content });
                        }
                    } else if (tryParseFenceOpen(trimmed)) |fo| {
                        if (para.active) try flushParagraph(doc, arena, &para, block_parent, pending_inlines);
                        if (had_blank_at_top and top_block_count > 0) had_blank_between_blocks = true;
                        top_block_count += 1;
                        had_blank_at_top = false;

                        const info_decoded = if (fo.info.len > 0)
                            try processEscapes(arena, fo.info)
                        else
                            @as([]const u8, "");

                        fence = .{
                            .fence_char = fo.char,
                            .fence_len = fo.len,
                            .fence_indent = @intCast(indent),
                            .info = info_decoded,
                            .content_buf = .empty,
                            .has_content = false,
                            .node_start = line_start,
                            .bq_depth = bq_depth,
                        };
                    } else if (tryParseHtmlBlockStart(trimmed, para.active)) |hb_start| {
                        if (para.active) try flushParagraph(doc, arena, &para, block_parent, pending_inlines);
                        if (had_blank_at_top and top_block_count > 0) had_blank_between_blocks = true;
                        top_block_count += 1;
                        had_blank_at_top = false;
                        html_block = .{
                            .html_type = hb_start.html_type,
                            .content_buf = .empty,
                            .node_start = line_start,
                            .bq_depth = bq_depth,
                            .close_str = hb_start.close_str,
                        };
                        try html_block.?.content_buf.appendSlice(arena, stripped);
                        // Type 1: check if close tag is on the same opening line
                        if (hb_start.html_type == .type1) {
                            if (hb_start.close_str) |cs| {
                                if (containsIgnoreCase(stripped, cs)) {
                                    try closeHtmlBlock(doc, &html_block.?, block_parent, line_end);
                                    html_block = null;
                                }
                            }
                        }
                    } else if (para.active and tryParseSetextMarker(trimmed) != null) {
                        const level = tryParseSetextMarker(trimmed).?;
                        if (!try closeSetextHeading(doc, arena, &para, level, line_end, block_parent, pending_inlines)) {
                            // All paragraph content was link ref defs, setext not created.
                            // Treat marker line as new paragraph content.
                            try startOrContinuePara(&para, arena, stripped, line_start, line_end, in_container);
                        }
                    } else if (doc.extensions.gfm and para.active and tryParseTableSeparator(trimmed) != null) {
                        const sep = tryParseTableSeparator(trimmed).?;
                        // The previous paragraph line is the header row
                        if (paraExtractLastLine(&para, source)) |header_line| {
                            // Flush remaining paragraph content (before the header)
                            if (para.active) try flushParagraph(doc, arena, &para, block_parent, pending_inlines);
                            if (had_blank_at_top and top_block_count > 0) had_blank_between_blocks = true;
                            top_block_count += 1;
                            had_blank_at_top = false;

                            const tbl_node = try doc.createNode(.table, .{ .none = {} }, .{ .start = line_start, .end = line_end });
                            block_parent.appendChild(tbl_node);

                            // thead with header row
                            const thead = try doc.createNode(.table_head, .{ .none = {} }, .{ .start = line_start, .end = line_end });
                            tbl_node.appendChild(thead);
                            const header_row = try buildTableRow(doc, arena, header_line, sep.col_count, sep.alignments, true, line_start, line_end, pending_inlines);
                            thead.appendChild(header_row);

                            // tbody (data rows will be appended during continuation)
                            const tbody = try doc.createNode(.table_body, .{ .none = {} }, .{ .start = line_end, .end = line_end });
                            tbl_node.appendChild(tbody);

                            table = .{
                                .node = tbl_node,
                                .body = tbody,
                                .col_count = sep.col_count,
                                .alignments = sep.alignments,
                                .bq_depth = bq_depth,
                            };
                        } else {
                            // No header line available — treat as paragraph
                            try startOrContinuePara(&para, arena, stripped, line_start, line_end, in_container);
                        }
                    } else if (tryParseThematicBreak(trimmed)) {
                        if (para.active) try flushParagraph(doc, arena, &para, block_parent, pending_inlines);
                        if (had_blank_at_top and top_block_count > 0) had_blank_between_blocks = true;
                        top_block_count += 1;
                        had_blank_at_top = false;
                        const tb = try doc.createNode(.thematic_break, .{ .none = {} }, .{
                            .start = line_start,
                            .end = line_end,
                        });
                        block_parent.appendChild(tb);
                    } else if (tryParseListMarker(trimmed)) |marker| {
                        if (para.active and !canInterruptParagraph(marker, trimmed)) {
                            try startOrContinuePara(&para, arena, stripped, line_start, line_end, in_container);
                        } else {
                            if (para.active) try flushParagraph(doc, arena, &para, block_parent, pending_inlines);
                            if (had_blank_at_top and top_block_count > 0) had_blank_between_blocks = true;
                            top_block_count += 1;
                            had_blank_at_top = false;
                            const list_node = try doc.createNode(.list, .{ .list = .{
                                .ordered = marker.ordered,
                                .start = marker.start_num,
                                .marker = marker.marker,
                                .tight = true,
                            } }, .{ .start = line_start, .end = line_end });
                            const item = try doc.createNode(.list_item, .{ .none = {} }, .{
                                .start = line_start,
                                .end = line_end,
                            });
                            list_node.appendChild(item);
                            block_parent.appendChild(list_node);
                            list = .{
                                .node = list_node,
                                .item_node = item,
                                .marker = marker.marker,
                                .ordered = marker.ordered,
                                .content_indent = indent + marker.content_col_offset,
                                .had_blank = false,
                                .tight = true,
                                .bq_depth = bq_depth,
                                .item_buf = .empty,
                                .item_has_content = false,
                                .pending_blanks = 0,
                            };
                            if (marker.content_offset < trimmed.len) {
                                // Use column-aware stripping to correctly handle tabs
                                const content = try stripAndExpandCols(arena, trimmed[marker.marker_end..], marker.content_col_offset, marker.marker_end);
                                if (content.len > 0) {
                                    try list.?.item_buf.appendSlice(arena, content);
                                    list.?.item_has_content = true;
                                }
                            }
                        }
                    } else {
                        // Paragraph continuation or start
                        if (!para.active) {
                            if (had_blank_at_top and top_block_count > 0) had_blank_between_blocks = true;
                            top_block_count += 1;
                            had_blank_at_top = false;
                        }
                        try startOrContinuePara(&para, arena, stripped, line_start, line_end, in_container);
                    }
                }
            }
        }

        if (line_end >= source.len) break;
        line_start = line_end + 1;
    }

    // Close remaining open structures
    if (fence) |*f| {
        try closeFencedCodeBlock(doc, f, container_stack[f.bq_depth], source.len, source.len);
    }
    if (indent_code) |*ic| {
        try closeIndentedCodeBlock(doc, ic, container_stack[@min(ic.bq_depth, bq_depth)]);
        indent_code = null;
    }
    if (html_block) |*hb| {
        try closeHtmlBlock(doc, hb, container_stack[@min(hb.bq_depth, bq_depth)], source.len);
        html_block = null;
    }
    if (table) |*tbl| {
        tbl.node.source.end = source.len;
        table = null;
    }
    while (bq_depth > 0) {
        if (list) |*ls| {
            if (ls.bq_depth == bq_depth) {
                try flushListItem(doc, arena, ls, pending_inlines);
                ls.node.data.list.tight = ls.tight;
                list = null;
            }
        }
        if (para.active) try flushParagraph(doc, arena, &para, container_stack[bq_depth], pending_inlines);
        bq_depth -= 1;
    }
    if (list) |*ls| {
        try flushListItem(doc, arena, ls, pending_inlines);
        ls.node.data.list.tight = ls.tight;
        list = null;
    }
    if (para.active) try flushParagraph(doc, arena, &para, container_stack[0], pending_inlines);

    return had_blank_between_blocks;
}

// ── Paragraph helpers ──────────────────────────────────────────────────

fn startOrContinuePara(para: *ParaState, arena: std.mem.Allocator, stripped: []const u8, line_start: usize, line_end: usize, in_container: bool) !void {
    if (!para.active) {
        para.active = true;
        para.source_start = line_start;
        para.in_container = in_container;
        para.buf.clearRetainingCapacity();
    }
    para.source_end = line_end;
    if (para.in_container) {
        if (para.buf.items.len > 0) try para.buf.append(arena, '\n');
        try para.buf.appendSlice(arena, stripped);
    }
}

fn flushParagraph(doc: *Document, arena: std.mem.Allocator, para: *ParaState, parent: *Node, pending: *std.ArrayListUnmanaged(PendingInline)) !void {
    if (!para.active) return;
    defer para.reset();

    if (para.in_container) {
        // Extract link reference definitions from start of text
        var text = para.buf.items;
        while (text.len > 0) {
            const consumed = try tryParseLinkRefDef(doc, arena, text) orelse break;
            if (consumed == 0) break;
            text = text[consumed..];
        }
        const content = std.mem.trimEnd(u8, text, " \t\r");
        if (content.len == 0) return;
        const stripped_content = try stripLineLeadingSpaces(arena, content);
        const duped = try arena.dupe(u8, stripped_content);
        const p = try doc.createNode(.paragraph, .{ .none = {} }, .{ .start = para.source_start, .end = para.source_end });
        parent.appendChild(p);
        try pending.append(arena, .{ .node = p, .text = duped });
    } else {
        // Extract link reference definitions from start of text
        var start = para.source_start;
        while (start < para.source_end) {
            const slice = doc.source[start..para.source_end];
            const consumed = try tryParseLinkRefDef(doc, arena, slice) orelse break;
            if (consumed == 0) break;
            start += consumed;
        }
        const raw = doc.source[start..para.source_end];
        const content = std.mem.trimEnd(u8, raw, " \t\r");
        if (content.len == 0) return;
        const stripped_content = try stripLineLeadingSpaces(arena, content);
        const p = try doc.createNode(.paragraph, .{ .none = {} }, .{ .start = start, .end = para.source_end });
        parent.appendChild(p);
        try pending.append(arena, .{ .node = p, .text = stripped_content });
    }
}

/// Flush a list item by sub-parsing its accumulated content as blocks.
fn flushListItem(doc: *Document, _: std.mem.Allocator, ls: *ListState, pending: *std.ArrayListUnmanaged(PendingInline)) !void {
    if (!ls.item_has_content or ls.item_buf.items.len == 0) return;
    // Alias the content directly — old arena memory stays alive.
    var content = ls.item_buf.items;
    // GFM task list: detect [ ]/[x]/[X] at start of first line
    if (doc.extensions.gfm) {
        if (tryParseTaskMarker(content)) |task| {
            ls.item_node.data = .{ .task_state = task.state };
            content = content[task.offset..];
        }
    }
    const had_inner_blanks = try parseBlocks(doc, ls.item_node, content, pending, true);
    if (had_inner_blanks) ls.tight = false;
    ls.item_buf = .empty;
    ls.item_has_content = false;
    ls.pending_blanks = 0;
}

const TaskMarker = struct { state: ast.TaskState, offset: usize };

fn tryParseTaskMarker(content: []const u8) ?TaskMarker {
    if (content.len < 4) return null;
    if (content[0] != '[') return null;
    const state: ast.TaskState = switch (content[1]) {
        ' ' => .unchecked,
        'x', 'X' => .checked,
        else => return null,
    };
    if (content[2] != ']') return null;
    if (content[3] != ' ' and content[3] != '\n') return null;
    return .{ .state = state, .offset = 4 };
}

/// Strip leading spaces/tabs from each line of a multi-line string.
fn stripLineLeadingSpaces(arena: std.mem.Allocator, content: []const u8) ![]const u8 {
    // Quick check: if first char isn't whitespace, check if there are any lines with leading whitespace
    if (content.len == 0 or (content[0] != ' ' and content[0] != '\t' and std.mem.indexOfScalar(u8, content, '\n') == null)) {
        return content;
    }
    var needs_strip = content[0] == ' ' or content[0] == '\t';
    if (!needs_strip) {
        // Check if any line after \n starts with whitespace
        var i: usize = 0;
        while (std.mem.indexOfScalarPos(u8, content, i, '\n')) |nl| {
            if (nl + 1 < content.len and (content[nl + 1] == ' ' or content[nl + 1] == '\t')) {
                needs_strip = true;
                break;
            }
            i = nl + 1;
        }
    }
    if (!needs_strip) return content;

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var pos: usize = 0;
    while (pos <= content.len) {
        // Strip leading spaces from this line
        while (pos < content.len and (content[pos] == ' ' or content[pos] == '\t')) : (pos += 1) {}
        // Copy until newline or end
        const line_start = pos;
        while (pos < content.len and content[pos] != '\n') : (pos += 1) {}
        try buf.appendSlice(arena, content[line_start..pos]);
        if (pos < content.len) {
            try buf.append(arena, '\n');
            pos += 1; // skip \n
        } else {
            break;
        }
    }
    return buf.items;
}

/// Try to close a setext heading. Returns true if a heading was created.
/// If the paragraph content is entirely link ref defs, returns false (no heading).
fn closeSetextHeading(doc: *Document, arena: std.mem.Allocator, para: *ParaState, level: u3, marker_end: usize, parent: *Node, pending: *std.ArrayListUnmanaged(PendingInline)) !bool {
    if (!para.active) return false;

    if (para.in_container) {
        // Extract link reference definitions from start of text
        var text = para.buf.items;
        while (text.len > 0) {
            const consumed = try tryParseLinkRefDef(doc, arena, text) orelse break;
            if (consumed == 0) break;
            text = text[consumed..];
        }
        const content = std.mem.trimEnd(u8, text, " \t\r");
        if (content.len == 0) return false;

        // Dupe content out of para.buf BEFORE reset (which clears the buffer
        // to undefined in 0.16's clearRetainingCapacity).
        const stripped_content = try stripLineLeadingSpaces(arena, content);
        const duped = try arena.dupe(u8, stripped_content);
        const source_start = para.source_start;
        para.reset();
        const h = try doc.createNode(.heading, .{ .heading = .{
            .level = level,
            .setext = true,
        } }, .{ .start = source_start, .end = marker_end });
        try pending.append(arena, .{ .node = h, .text = duped });
        parent.appendChild(h);
    } else {
        // Extract link reference definitions from start of text
        var start = para.source_start;
        while (start < para.source_end) {
            const slice = doc.source[start..para.source_end];
            const consumed = try tryParseLinkRefDef(doc, arena, slice) orelse break;
            if (consumed == 0) break;
            start += consumed;
        }
        const raw = doc.source[start..para.source_end];
        const content = std.mem.trimEnd(u8, raw, " \t\r");
        if (content.len == 0) return false;

        para.reset();
        const h = try doc.createNode(.heading, .{ .heading = .{
            .level = level,
            .setext = true,
        } }, .{ .start = start, .end = marker_end });
        const stripped_content = try stripLineLeadingSpaces(arena, content);
        try pending.append(arena, .{ .node = h, .text = stripped_content });
        parent.appendChild(h);
    }
    return true;
}

fn closeFencedCodeBlock(doc: *Document, f: *FenceState, parent: *Node, _: usize, close_line_end: usize) !void {
    const cbd_idx = try doc.storeCodeBlockData(.{
        .info = f.info,
        .fenced = true,
        .fence_char = f.fence_char,
        .fence_len = f.fence_len,
        .indent = f.fence_indent,
    });
    const cb = try doc.createNode(.code_block, .{ .code_block = cbd_idx }, .{ .start = f.node_start, .end = close_line_end });

    if (f.has_content) {
        const duped = try doc.allocString(f.content_buf.items);
        const text = try doc.createNode(.text, .{ .literal = duped }, .{
            .start = f.node_start,
            .end = close_line_end,
        });
        cb.appendChild(text);
    }
    parent.appendChild(cb);
}

fn closeIndentedCodeBlock(doc: *Document, ic: *IndentCodeState, parent: *Node) !void {
    if (ic.content_buf.items.len > 0) {
        const duped = try doc.allocString(ic.content_buf.items);
        const cbd_idx = try doc.storeCodeBlockData(.{
            .info = "",
            .fenced = false,
            .fence_char = 0,
            .fence_len = 0,
            .indent = 0,
        });
        const cb = try doc.createNode(.code_block, .{ .code_block = cbd_idx }, .{ .start = ic.node_start, .end = ic.node_end });
        const text = try doc.createNode(.text, .{ .literal = duped }, .{
            .start = ic.node_start,
            .end = ic.node_end,
        });
        cb.appendChild(text);
        parent.appendChild(cb);
    }
}

fn closeHtmlBlock(doc: *Document, hb: *HtmlBlockState, parent: *Node, end_pos: usize) !void {
    if (hb.content_buf.items.len > 0) {
        const duped = try doc.allocString(hb.content_buf.items);
        const node = try doc.createNode(.html_block, .{ .literal = duped }, .{
            .start = hb.node_start,
            .end = end_pos,
        });
        parent.appendChild(node);
    }
}

// ── Line-level parsers ─────────────────────────────────────────────────

/// Strip a single blockquote marker (`>` + optional space) from a line.
/// Returns the remaining content, or null if no marker found.
fn tryStripBqMarker(line: []const u8, arena: std.mem.Allocator) !?[]const u8 {
    // Fast path: no tabs anywhere before or after > (most common case)
    if (line.len > 0) {
        if (line[0] == '>') {
            if (line.len > 1 and line[1] == ' ') return line[2..];
            if (line.len == 1 or line[1] != '\t') return line[1..];
            // Tab after > — fall through to slow path for expansion
        } else if (line[0] == ' ') {
            var s: usize = 1;
            while (s < 3 and s < line.len and line[s] == ' ') s += 1;
            if (s < line.len and line[s] == '>') {
                const after = line[s + 1 ..];
                if (after.len > 0 and after[0] == ' ') return after[1..];
                if (after.len == 0 or after[0] != '\t') return after;
                // Tab after > — fall through to slow path
            } else {
                if (s >= 3) return null;
            }
        } else if (line[0] == '\t') {
            // Tab at start → 4+ columns of indent → not a blockquote marker
            return null;
        }
    }
    // Slow path: handle tabs and edge cases
    const info = computeIndent(line);
    if (info.columns >= 4) return null;
    const after_indent = line[info.bytes..];
    if (after_indent.len == 0 or after_indent[0] != '>') return null;
    const after_gt = after_indent[1..];

    const gt_col = info.columns;
    var content_start: usize = 0;
    var effective_col: usize = gt_col + 1;
    var partial_tab_remainder: usize = 0;

    if (after_gt.len > 0 and (after_gt[0] == ' ' or after_gt[0] == '\t')) {
        content_start = 1;
        if (after_gt[0] == ' ') {
            effective_col = gt_col + 2;
        } else {
            // Tab after > — one column consumed as optional space, rest is virtual indent
            const next_tab = ((gt_col + 1) / 4 + 1) * 4;
            effective_col = next_tab;
            partial_tab_remainder = next_tab - gt_col - 2;
        }
    }

    const rest = after_gt[content_start..];

    // Check if any leading whitespace contains tabs that need column-correct expansion
    var has_leading_tab = false;
    for (rest) |c| {
        if (c == '\t') {
            has_leading_tab = true;
            break;
        }
        if (c != ' ') break;
    }

    if (partial_tab_remainder == 0 and !has_leading_tab) {
        return rest;
    }

    // Build result with correct column-based tab expansion
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    for (0..partial_tab_remainder) |_| try buf.append(arena, ' ');

    var col = effective_col;
    var i: usize = 0;
    while (i < rest.len and (rest[i] == ' ' or rest[i] == '\t')) {
        if (rest[i] == ' ') {
            try buf.append(arena, ' ');
            col += 1;
        } else {
            const nts = (col / 4 + 1) * 4;
            for (0..(nts - col)) |_| try buf.append(arena, ' ');
            col = nts;
        }
        i += 1;
    }
    try buf.appendSlice(arena, rest[i..]);
    return buf.items;
}

const AtxHeading = struct {
    level: u3,
    content: []const u8,
};

fn tryParseAtxHeading(trimmed: []const u8) ?AtxHeading {
    if (trimmed.len == 0 or trimmed[0] != '#') return null;

    var level: u3 = 0;
    var pos: usize = 0;
    while (pos < trimmed.len and trimmed[pos] == '#' and level < 6) {
        level += 1;
        pos += 1;
    }

    if (pos < trimmed.len and trimmed[pos] != ' ' and trimmed[pos] != '\t') return null;

    while (pos < trimmed.len and (trimmed[pos] == ' ' or trimmed[pos] == '\t')) {
        pos += 1;
    }

    var end = trimmed.len;

    // Strip trailing whitespace first
    while (end > pos and (trimmed[end - 1] == ' ' or trimmed[end - 1] == '\t')) {
        end -= 1;
    }
    // Strip trailing '#' (closing sequence)
    const before_hashes = end;
    while (end > pos and trimmed[end - 1] == '#') {
        end -= 1;
    }
    // Closing '#' must be preceded by a space (or be at content start)
    if (end < before_hashes and end > pos and trimmed[end - 1] != ' ' and trimmed[end - 1] != '\t') {
        end = before_hashes; // not a valid closing sequence
    }
    // Strip trailing whitespace after removing closing hashes
    while (end > pos and (trimmed[end - 1] == ' ' or trimmed[end - 1] == '\t')) {
        end -= 1;
    }

    return .{ .level = level, .content = trimmed[pos..end] };
}

const FenceOpen = struct {
    char: u8,
    len: u8,
    info: []const u8,
};

fn tryParseFenceOpen(trimmed: []const u8) ?FenceOpen {
    if (trimmed.len < 3) return null;
    const ch = trimmed[0];
    if (ch != '`' and ch != '~') return null;

    var count: u8 = 0;
    var pos: usize = 0;
    while (pos < trimmed.len and trimmed[pos] == ch) {
        count += 1;
        pos += 1;
    }
    if (count < 3) return null;

    const info = std.mem.trim(u8, trimmed[pos..], " \t");

    if (ch == '`') {
        for (info) |c| {
            if (c == '`') return null;
        }
    }

    return .{ .char = ch, .len = count, .info = info };
}

fn tryParseClosingFence(line: []const u8, fence_char: u8, fence_len: u8) bool {
    const trimmed = std.mem.trimStart(u8, line, " \t");
    const indent = line.len - trimmed.len;
    if (indent >= 4) return false;

    var count: usize = 0;
    var pos: usize = 0;
    while (pos < trimmed.len and trimmed[pos] == fence_char) {
        count += 1;
        pos += 1;
    }
    if (count < fence_len) return false;

    while (pos < trimmed.len) {
        if (trimmed[pos] != ' ' and trimmed[pos] != '\t') return false;
        pos += 1;
    }
    return true;
}

fn tryParseSetextMarker(trimmed: []const u8) ?u3 {
    if (trimmed.len == 0) return null;
    const ch = trimmed[0];
    if (ch != '=' and ch != '-') return null;

    var pos: usize = 0;
    while (pos < trimmed.len and trimmed[pos] == ch) {
        pos += 1;
    }
    while (pos < trimmed.len) {
        if (trimmed[pos] != ' ' and trimmed[pos] != '\t') return null;
        pos += 1;
    }

    return if (ch == '=') @as(u3, 1) else @as(u3, 2);
}

/// Check if a trimmed line could start a new block-level structure.
/// Used to determine if lazy continuation applies.
fn canStartBlock(trimmed: []const u8) bool {
    if (trimmed.len == 0) return false;
    // Thematic break
    if (tryParseThematicBreak(trimmed)) return true;
    // ATX heading
    if (tryParseAtxHeading(trimmed) != null) return true;
    // Fenced code block
    if (tryParseFenceOpen(trimmed) != null) return true;
    // Blockquote marker
    if (trimmed[0] == '>') return true;
    // HTML block start
    if (tryParseHtmlBlockStart(trimmed, false) != null) return true;
    return false;
}

/// Compute the column width of leading whitespace, with tabs expanded to 4-column tab stops.
/// Returns the number of columns and the byte offset past the whitespace.
const IndentInfo = struct {
    columns: usize,
    bytes: usize,
};

fn computeIndent(text: []const u8) IndentInfo {
    return computeIndentFrom(text, 0);
}

fn computeIndentFrom(text: []const u8, start_col: usize) IndentInfo {
    var col = start_col;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == ' ') {
            col += 1;
            i += 1;
        } else if (text[i] == '\t') {
            col = (col / 4 + 1) * 4;
            i += 1;
        } else break;
    }
    return .{ .columns = col, .bytes = i };
}

/// Advance past `target_cols` columns of whitespace from the beginning of text.
/// Returns the byte offset and the remaining column (for partial tabs that exceed target).
/// If a tab would go past target_cols, the remaining spaces are tracked in `remainder`.
const StripResult = struct {
    offset: usize,
    remainder: usize, // spaces to emit if this was a partial tab
};

/// Strip `target_cols` columns from text and return the remaining content
/// with tabs expanded to spaces based on original column positions.
/// This is needed for list item content where tabs may span structural boundaries.
fn stripAndExpandCols(arena: std.mem.Allocator, text: []const u8, target_cols: usize, start_col: usize) ![]const u8 {
    var col = start_col;
    var i: usize = 0;
    // Strip target_cols columns
    while (i < text.len and col < target_cols) {
        if (text[i] == ' ') {
            col += 1;
            i += 1;
        } else if (text[i] == '\t') {
            const next_tab = (col / 4 + 1) * 4;
            if (next_tab <= target_cols) {
                col = next_tab;
                i += 1;
            } else {
                // Partial tab
                i += 1;
                col = next_tab;
                break;
            }
        } else break;
    }
    // No tabs in remaining content? Return with just remainder spaces
    const remaining = text[i..];
    const remainder = if (col > target_cols) col - target_cols else 0;
    if (std.mem.indexOfScalar(u8, remaining, '\t') == null) {
        if (remainder == 0) return remaining;
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        for (0..remainder) |_| try buf.append(arena, ' ');
        try buf.appendSlice(arena, remaining);
        return buf.items;
    }
    // Expand tabs based on original column positions
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    for (0..remainder) |_| try buf.append(arena, ' ');
    var eff_col = col;
    for (remaining) |c| {
        if (c == '\t') {
            const next = (eff_col / 4 + 1) * 4;
            for (0..(next - eff_col)) |_| try buf.append(arena, ' ');
            eff_col = next;
        } else {
            try buf.append(arena, c);
            eff_col += 1;
        }
    }
    return buf.items;
}

fn stripCols(text: []const u8, target_cols: usize, start_col: usize) StripResult {
    var col = start_col;
    var i: usize = 0;
    while (i < text.len and col < target_cols) {
        if (text[i] == ' ') {
            col += 1;
            i += 1;
        } else if (text[i] == '\t') {
            const next_tab = (col / 4 + 1) * 4;
            if (next_tab <= target_cols) {
                col = next_tab;
                i += 1;
            } else {
                // Partial tab: consume it but track remaining spaces
                i += 1;
                return .{ .offset = i, .remainder = next_tab - target_cols };
            }
        } else break;
    }
    return .{ .offset = i, .remainder = 0 };
}

fn tryParseThematicBreak(trimmed: []const u8) bool {
    if (trimmed.len < 3) return false;
    const first = trimmed[0];
    if (first != '-' and first != '*' and first != '_') return false;

    var count: usize = 0;
    for (trimmed) |c| {
        if (c == first) {
            count += 1;
        } else if (c != ' ' and c != '\t') {
            return false;
        }
    }
    return count >= 3;
}

const ListMarkerResult = struct {
    ordered: bool,
    marker: u8,
    start_num: u32,
    marker_end: usize, // byte offset past the marker character(s)
    content_offset: usize, // byte offset of content start in trimmed
    content_col_offset: usize, // column offset of content start (for indent calculation)
};

fn tryParseListMarker(trimmed: []const u8) ?ListMarkerResult {
    if (trimmed.len == 0) return null;

    var pos: usize = 0;
    var ordered = false;
    var marker: u8 = 0;
    var start_num: u32 = 0;

    if (trimmed[0] == '-' or trimmed[0] == '*' or trimmed[0] == '+') {
        marker = trimmed[0];
        pos = 1;
    } else if (trimmed[0] >= '0' and trimmed[0] <= '9') {
        while (pos < trimmed.len and pos < 9 and trimmed[pos] >= '0' and trimmed[pos] <= '9') {
            start_num = start_num * 10 + @as(u32, trimmed[pos] - '0');
            pos += 1;
        }
        if (pos >= trimmed.len) return null;
        if (trimmed[pos] != '.' and trimmed[pos] != ')') return null;
        marker = trimmed[pos];
        pos += 1;
        ordered = true;
    } else {
        return null;
    }

    // Must be followed by space/tab, or be at end of line (empty item)
    const marker_end = pos;
    const marker_end_col = pos; // marker chars are all ASCII, 1 byte = 1 col
    if (pos >= trimmed.len) {
        return .{ .ordered = ordered, .marker = marker, .start_num = start_num, .marker_end = marker_end, .content_offset = marker_end + 1, .content_col_offset = marker_end_col + 1 };
    }
    if (trimmed[pos] != ' ' and trimmed[pos] != '\t') return null;

    // Skip spaces/tabs after marker, counting columns with tab expansion
    var col = marker_end_col;
    while (pos < trimmed.len and (trimmed[pos] == ' ' or trimmed[pos] == '\t')) {
        if (trimmed[pos] == '\t') {
            col = (col / 4 + 1) * 4;
        } else {
            col += 1;
        }
        pos += 1;
    }

    // If no content (only trailing spaces), use marker_width + 1
    if (pos >= trimmed.len) {
        return .{ .ordered = ordered, .marker = marker, .start_num = start_num, .marker_end = marker_end, .content_offset = marker_end + 1, .content_col_offset = marker_end_col + 1 };
    }

    // Cap N (columns after marker) at 4: if more, treat as marker + 1 column
    const n_cols = col - marker_end_col;
    if (n_cols > 4) {
        return .{ .ordered = ordered, .marker = marker, .start_num = start_num, .marker_end = marker_end, .content_offset = marker_end + 1, .content_col_offset = marker_end_col + 1 };
    }

    return .{ .ordered = ordered, .marker = marker, .start_num = start_num, .marker_end = marker_end, .content_offset = pos, .content_col_offset = col };
}

/// Whether a list marker can interrupt an active paragraph.
/// Empty items and ordered items not starting with 1 cannot interrupt.
fn canInterruptParagraph(marker: ListMarkerResult, trimmed: []const u8) bool {
    if (marker.content_offset >= trimmed.len) return false;
    if (marker.ordered and marker.start_num != 1) return false;
    return true;
}

// ── HTML block detection ──────────────────────────────────────────────

/// Block-level HTML tag names for type 6 detection.
const html_block_tags = [_][]const u8{
    "address",    "article",    "aside",     "base",       "basefont",
    "blockquote", "body",       "caption",   "center",     "col",
    "colgroup",   "dd",         "details",   "dialog",     "dir",
    "div",        "dl",         "dt",        "fieldset",   "figcaption",
    "figure",     "footer",     "form",      "frame",      "frameset",
    "h1",         "h2",         "h3",        "h4",         "h5",
    "h6",         "head",       "header",    "hr",         "html",
    "iframe",     "legend",     "li",        "link",       "main",
    "menu",       "menuitem",   "nav",       "noframes",   "ol",
    "optgroup",   "option",     "p",         "param",      "search",
    "section",    "summary",    "table",     "tbody",      "td",
    "tfoot",      "th",         "thead",     "title",      "tr",
    "track",      "ul",
};

/// Type 1 tags and their closing strings.
const HtmlType1Entry = struct { open: []const u8, close: []const u8 };
const html_type1_tags = [_]HtmlType1Entry{
    .{ .open = "pre", .close = "</pre>" },
    .{ .open = "script", .close = "</script>" },
    .{ .open = "style", .close = "</style>" },
    .{ .open = "textarea", .close = "</textarea>" },
};

const HtmlBlockStartResult = struct {
    html_type: HtmlBlockType,
    close_str: ?[]const u8,
};

/// Check if a line starts an HTML block. Returns start info or null.
fn tryParseHtmlBlockStart(trimmed: []const u8, para_active: bool) ?HtmlBlockStartResult {
    if (trimmed.len == 0 or trimmed[0] != '<') return null;

    // Type 1: <pre, <script, <style, <textarea
    for (html_type1_tags) |entry| {
        if (startsWithTagIgnoreCase(trimmed[1..], entry.open)) {
            return .{ .html_type = .type1, .close_str = entry.close };
        }
    }

    // Type 2: HTML comment <!--
    if (trimmed.len >= 4 and std.mem.eql(u8, trimmed[1..4], "!--")) {
        return .{ .html_type = .type1, .close_str = "-->" };
    }

    // Type 3: Processing instruction <?
    if (trimmed.len >= 2 and trimmed[1] == '?') {
        return .{ .html_type = .type1, .close_str = "?>" };
    }

    // Type 4: Declaration <!LETTER
    if (trimmed.len >= 3 and trimmed[1] == '!' and isAsciiAlpha(trimmed[2])) {
        return .{ .html_type = .type1, .close_str = ">" };
    }

    // Type 5: CDATA <![CDATA[
    if (trimmed.len >= 9 and std.mem.eql(u8, trimmed[1..9], "![CDATA[")) {
        return .{ .html_type = .type1, .close_str = "]]>" };
    }

    // Type 6: block-level tag (CAN interrupt paragraphs)
    if (isType6Start(trimmed)) {
        return .{ .html_type = .type6, .close_str = null };
    }

    // Type 7: any tag (CANNOT interrupt paragraphs)
    if (!para_active and isType7Start(trimmed)) {
        return .{ .html_type = .type7, .close_str = null };
    }

    return null;
}

/// Check if trimmed starts with `<tagname` or `</tagname` where tagname
/// is followed by whitespace, `>`, `/>`, or end of line.
fn startsWithTagIgnoreCase(after_lt: []const u8, tag: []const u8) bool {
    if (after_lt.len < tag.len) return false;
    for (after_lt[0..tag.len], tag) |a, b| {
        if (toLowerAscii(a) != b) return false;
    }
    if (after_lt.len == tag.len) return true;
    const ch = after_lt[tag.len];
    return ch == ' ' or ch == '\t' or ch == '>' or ch == '/' or ch == '\n';
}

fn isType6Start(trimmed: []const u8) bool {
    // Must start with `<` or `</`
    if (trimmed.len < 2) return false;
    var pos: usize = 1;
    const closing = trimmed[1] == '/';
    if (closing) {
        pos = 2;
        if (pos >= trimmed.len) return false;
    }
    for (html_block_tags) |tag| {
        if (startsWithTagIgnoreCase(trimmed[pos..], tag)) {
            const after = pos + tag.len;
            if (after >= trimmed.len) return true;
            const ch = trimmed[after];
            if (ch == ' ' or ch == '\t' or ch == '>' or ch == '/' or ch == '\n') return true;
        }
    }
    return false;
}

fn isType7Start(trimmed: []const u8) bool {
    if (trimmed.len < 2 or trimmed[0] != '<') return false;
    if (trimmed[1] == '/') {
        // Closing tag: </tagname followed by optional whitespace and >
        if (trimmed.len < 4) return false;
        if (!isAsciiAlpha(trimmed[2])) return false;
        var pos: usize = 3;
        while (pos < trimmed.len and isAsciiAlphaNum(trimmed[pos])) : (pos += 1) {}
        while (pos < trimmed.len and (trimmed[pos] == ' ' or trimmed[pos] == '\t')) : (pos += 1) {}
        if (pos < trimmed.len and trimmed[pos] == '>') {
            // Rest of line must be blank
            return isRestBlank(trimmed[pos + 1 ..]);
        }
        return false;
    } else {
        // Open tag: <tagname (attributes)* /? >
        // Per CommonMark spec, must be a complete open tag on the line.
        if (!isAsciiAlpha(trimmed[1])) return false;
        var pos: usize = 2;
        // Tag name: [a-zA-Z0-9-]*
        while (pos < trimmed.len and (isAsciiAlphaNum(trimmed[pos]) or trimmed[pos] == '-')) : (pos += 1) {}
        // After tag name: must be whitespace, >, />, or end of line
        // (not `:` or other chars — this rejects <http://...>)
        return parseType7Attrs(trimmed, pos);
    }
}

/// Parse type 7 attributes: whitespace-separated attr names with optional values.
/// Returns true if the remainder forms a valid complete open tag.
fn parseType7Attrs(trimmed: []const u8, start: usize) bool {
    var pos = start;
    // Parse zero or more attributes
    while (pos < trimmed.len) {
        // Skip whitespace
        const ws_start = pos;
        while (pos < trimmed.len and (trimmed[pos] == ' ' or trimmed[pos] == '\t' or trimmed[pos] == '\n')) : (pos += 1) {}
        // Check for end of tag
        if (pos < trimmed.len and trimmed[pos] == '>') {
            return isRestBlank(trimmed[pos + 1 ..]);
        }
        if (pos < trimmed.len and trimmed[pos] == '/' and pos + 1 < trimmed.len and trimmed[pos + 1] == '>') {
            return isRestBlank(trimmed[pos + 2 ..]);
        }
        // Must have had whitespace before attribute
        if (pos == ws_start) return false;
        // Attribute name: [a-zA-Z_:][a-zA-Z0-9_.:-]*
        if (!isAsciiAlpha(trimmed[pos]) and trimmed[pos] != '_' and trimmed[pos] != ':') return false;
        pos += 1;
        while (pos < trimmed.len and (isAsciiAlphaNum(trimmed[pos]) or
            trimmed[pos] == '_' or trimmed[pos] == '.' or
            trimmed[pos] == ':' or trimmed[pos] == '-')) : (pos += 1)
        {}
        // Optional value specification
        // Skip whitespace
        const ws2 = pos;
        while (pos < trimmed.len and (trimmed[pos] == ' ' or trimmed[pos] == '\t' or trimmed[pos] == '\n')) : (pos += 1) {}
        if (pos < trimmed.len and trimmed[pos] == '=') {
            pos += 1;
            // Skip whitespace after =
            while (pos < trimmed.len and (trimmed[pos] == ' ' or trimmed[pos] == '\t' or trimmed[pos] == '\n')) : (pos += 1) {}
            if (pos >= trimmed.len) return false;
            if (trimmed[pos] == '\'' or trimmed[pos] == '"') {
                // Quoted value
                const quote = trimmed[pos];
                pos += 1;
                while (pos < trimmed.len and trimmed[pos] != quote) : (pos += 1) {}
                if (pos >= trimmed.len) return false;
                pos += 1; // skip closing quote
            } else {
                // Unquoted value: non-empty, no spaces/quotes/=/</>
                const val_start = pos;
                while (pos < trimmed.len and trimmed[pos] != ' ' and trimmed[pos] != '\t' and
                    trimmed[pos] != '\n' and trimmed[pos] != '"' and trimmed[pos] != '\'' and
                    trimmed[pos] != '=' and trimmed[pos] != '<' and trimmed[pos] != '>' and
                    trimmed[pos] != '`') : (pos += 1)
                {}
                if (pos == val_start) return false;
            }
        } else {
            // No '=' — rewind whitespace (it wasn't part of value spec)
            pos = ws2;
        }
    }
    return false;
}

fn isRestBlank(rest: []const u8) bool {
    for (rest) |c| {
        if (c != ' ' and c != '\t' and c != '\n') return false;
    }
    return true;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var match = true;
        for (0..needle.len) |j| {
            if (toLowerAscii(haystack[i + j]) != toLowerAscii(needle[j])) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

fn toLowerAscii(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

fn isAsciiAlpha(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

fn isAsciiAlphaNum(c: u8) bool {
    return isAsciiAlpha(c) or (c >= '0' and c <= '9');
}

// ── Link reference definition parsing ─────────────────────────────────

const LinkPart = struct {
    value: []const u8,
    end: usize,
};

/// Try to parse a link reference definition from the start of text.
/// Returns the number of bytes consumed, or null if no valid ref def found.
/// Stores the definition in doc.ref_map (first definition wins).
fn tryParseLinkRefDef(doc: *Document, arena: std.mem.Allocator, text: []const u8) !?usize {
    var pos: usize = 0;

    // Skip up to 3 spaces of indentation
    while (pos < text.len and pos < 3 and text[pos] == ' ') : (pos += 1) {}

    // 1. [label]
    if (pos >= text.len or text[pos] != '[') return null;
    pos += 1;
    const label_start = pos;
    while (pos < text.len) {
        if (text[pos] == '\\' and pos + 1 < text.len) {
            pos += 2;
            continue;
        }
        if (text[pos] == '[') return null; // unescaped [ not allowed
        if (text[pos] == ']') break;
        pos += 1;
    }
    if (pos >= text.len) return null;
    const label = text[label_start..pos];
    if (label.len == 0 or label.len > 999) return null;
    // Must contain at least one non-whitespace char
    if (std.mem.trim(u8, label, " \t\n").len == 0) return null;
    pos += 1; // skip ]

    // 2. : after ]
    if (pos >= text.len or text[pos] != ':') return null;
    pos += 1;

    // 3. Optional whitespace (including up to one newline)
    pos = skipOptionalSpaceAndNewline(text, pos);

    // 4. Destination
    const dest = parseLinkDestination(text, pos) orelse return null;
    pos = dest.end;

    // Save for backtracking if title parsing fails
    const pos_after_dest = pos;

    // 5. Optional title
    var title: []const u8 = "";
    var has_title = false;

    if (pos < text.len and (text[pos] == ' ' or text[pos] == '\t' or text[pos] == '\n')) {
        const ws_start = pos;
        const title_check_pos = skipOptionalSpaceAndNewline(text, pos);

        if (title_check_pos != ws_start and title_check_pos < text.len and
            (text[title_check_pos] == '"' or text[title_check_pos] == '\'' or text[title_check_pos] == '('))
        {
            if (parseLinkTitle(text, title_check_pos)) |t| {
                // Check rest of line is blank after title
                if (isRestOfLineBlank(text, t.end)) {
                    title = t.value;
                    pos = skipToEndOfLine(text, t.end);
                    has_title = true;
                }
            }
        }
    }

    if (!has_title) {
        // No title — check rest of line blank after destination
        if (!isRestOfLineBlank(text, pos_after_dest)) return null;
        pos = skipToEndOfLine(text, pos_after_dest);
    }

    // Normalize label and store
    const normalized = try normalizeLabel(arena, label);

    // First definition wins
    const gop = try doc.ref_map.getOrPut(arena, normalized);
    if (!gop.found_existing) {
        // processEscapes may return its input slice when no escapes are present,
        // and `text` (and thus `dest.value`/`title`) can alias the transient
        // ParaState.buf, which gets reset+overwritten between paragraphs.
        // Dupe ensures arena ownership for the lifetime of the document.
        const dest_processed = try processEscapes(arena, dest.value);
        const dest_owned = if (dest_processed.ptr == dest.value.ptr)
            try arena.dupe(u8, dest_processed)
        else
            dest_processed;
        const title_owned = if (title.len == 0) "" else blk: {
            const t = try processEscapes(arena, title);
            break :blk if (t.ptr == title.ptr) try arena.dupe(u8, t) else t;
        };
        gop.value_ptr.* = .{
            .destination = dest_owned,
            .title = title_owned,
        };
    }

    return pos;
}

/// Skip spaces/tabs, then optionally one newline followed by more spaces/tabs.
fn isAsciiPunctuation(c: u8) bool {
    return switch (c) {
        '!', '"', '#', '$', '%', '&', '\'', '(', ')', '*', '+', ',', '-', '.', '/' => true,
        ':', ';', '<', '=', '>', '?', '@' => true,
        '[', '\\', ']', '^', '_', '`' => true,
        '{', '|', '}', '~' => true,
        else => false,
    };
}

/// Process backslash escapes: \X → X for ASCII punctuation, \other → \other
fn processEscapes(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, text, '\\') == null and
        std.mem.indexOfScalar(u8, text, '&') == null) return text;
    var result: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '\\' and i + 1 < text.len and isAsciiPunctuation(text[i + 1])) {
            try result.append(arena, text[i + 1]);
            i += 2;
        } else if (text[i] == '&') {
            if (inline_parser.tryParseEntityRef(text, i)) |ref| {
                try result.appendSlice(arena, ref.value);
                i = ref.end;
            } else {
                try result.append(arena, text[i]);
                i += 1;
            }
        } else {
            try result.append(arena, text[i]);
            i += 1;
        }
    }
    return result.items;
}

fn skipOptionalSpaceAndNewline(text: []const u8, start: usize) usize {
    var pos = start;
    while (pos < text.len and (text[pos] == ' ' or text[pos] == '\t')) : (pos += 1) {}
    if (pos < text.len and text[pos] == '\n') {
        pos += 1;
        while (pos < text.len and (text[pos] == ' ' or text[pos] == '\t')) : (pos += 1) {}
    }
    return pos;
}

/// Parse a link destination: `<...>` or bare URL.
fn parseLinkDestination(text: []const u8, pos: usize) ?LinkPart {
    if (pos >= text.len) return null;

    if (text[pos] == '<') {
        // Angle-bracket destination
        var p = pos + 1;
        const start = p;
        while (p < text.len) {
            if (text[p] == '\\' and p + 1 < text.len) {
                p += 2;
                continue;
            }
            if (text[p] == '\n' or text[p] == '<') return null;
            if (text[p] == '>') {
                return .{ .value = text[start..p], .end = p + 1 };
            }
            p += 1;
        }
        return null;
    } else {
        // Bare destination: balanced parens, no spaces/control chars
        var p = pos;
        var paren_depth: usize = 0;
        while (p < text.len) {
            if (text[p] == '\\' and p + 1 < text.len) {
                p += 2;
                continue;
            }
            if (text[p] <= ' ') break; // space, tab, newline, control
            if (text[p] == '(') {
                paren_depth += 1;
            } else if (text[p] == ')') {
                if (paren_depth == 0) break;
                paren_depth -= 1;
            }
            p += 1;
        }
        if (paren_depth != 0) return null;
        return .{ .value = text[pos..p], .end = p };
    }
}

/// Parse a link title: `"..."`, `'...'`, or `(...)`.
fn parseLinkTitle(text: []const u8, pos: usize) ?LinkPart {
    if (pos >= text.len) return null;
    const open = text[pos];
    if (open != '"' and open != '\'' and open != '(') return null;
    const close: u8 = if (open == '(') ')' else open;

    var p = pos + 1;
    const start = p;
    while (p < text.len) {
        if (text[p] == '\\' and p + 1 < text.len) {
            p += 2;
            continue;
        }
        if (text[p] == close) {
            return .{ .value = text[start..p], .end = p + 1 };
        }
        if (open == '(' and text[p] == '(') return null; // unescaped ( in (...)
        p += 1;
    }
    return null;
}

/// Check if all characters from pos to the next newline (or end) are whitespace.
fn isRestOfLineBlank(text: []const u8, pos: usize) bool {
    var p = pos;
    while (p < text.len and text[p] != '\n') : (p += 1) {
        if (text[p] != ' ' and text[p] != '\t') return false;
    }
    return true;
}

/// Advance past end of current line (including the newline character).
fn skipToEndOfLine(text: []const u8, pos: usize) usize {
    var p = pos;
    while (p < text.len and text[p] != '\n') : (p += 1) {}
    if (p < text.len) p += 1; // skip newline
    return p;
}

const normalizeLabel = case_fold.normalizeLabel;

// ── Frontmatter ───────────────────────────────────────────────────────

const FrontmatterResult = struct {
    content_start: usize, // start of YAML content (after first --- line)
    content_end: usize, // end of YAML content (before closing ---)
    block_end: usize, // position after the closing --- line (including newline)
};

/// Detect YAML frontmatter at the very start of a document.
/// Frontmatter is delimited by `---` lines. Returns null if not found.
fn tryParseFrontmatter(source: []const u8) ?FrontmatterResult {
    if (source.len < 3) return null;
    if (!std.mem.startsWith(u8, source, "---")) return null;

    var pos: usize = 3;
    // Allow trailing spaces/tabs after opening ---
    while (pos < source.len and (source[pos] == ' ' or source[pos] == '\t')) pos += 1;
    if (pos >= source.len or source[pos] != '\n') return null;
    pos += 1; // skip newline
    const content_start = pos;

    // Scan for closing ---
    while (pos < source.len) {
        const line_begin = pos;
        if (pos + 3 <= source.len and std.mem.startsWith(u8, source[pos..], "---")) {
            var p = pos + 3;
            while (p < source.len and (source[p] == ' ' or source[p] == '\t')) p += 1;
            if (p >= source.len or source[p] == '\n') {
                return .{
                    .content_start = content_start,
                    .content_end = line_begin,
                    .block_end = if (p < source.len) p + 1 else p,
                };
            }
        }
        // Skip to next line
        while (pos < source.len and source[pos] != '\n') pos += 1;
        if (pos < source.len) pos += 1;
    }
    return null; // no closing --- found
}

// ── GFM table helpers ──────────────────────────────────────────────────

/// Parse a GFM table separator row. Returns column count and alignments, or null.
/// Valid separator cells: `---`, `:---`, `---:`, `:---:` (with optional leading/trailing pipes).
fn tryParseTableSeparator(line: []const u8) ?struct { col_count: usize, alignments: [TableState.max_cols]ast.Alignment } {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len == 0) return null;
    // Must contain at least one pipe
    if (std.mem.indexOfScalar(u8, trimmed, '|') == null) return null;

    var alignments: [TableState.max_cols]ast.Alignment = @splat(.none);
    var col_count: usize = 0;
    var pos: usize = 0;

    // Skip leading pipe
    if (pos < trimmed.len and trimmed[pos] == '|') pos += 1;

    while (pos < trimmed.len) {
        // Skip spaces
        while (pos < trimmed.len and trimmed[pos] == ' ') pos += 1;
        if (pos >= trimmed.len) break;
        // Trailing pipe only
        if (trimmed[pos] == '|' and pos == trimmed.len - 1) break;

        // Parse cell: optional ':', one or more '-', optional ':'
        const left_colon = pos < trimmed.len and trimmed[pos] == ':';
        if (left_colon) pos += 1;

        var dash_count: usize = 0;
        while (pos < trimmed.len and trimmed[pos] == '-') {
            dash_count += 1;
            pos += 1;
        }
        if (dash_count == 0) return null; // need at least one dash

        const right_colon = pos < trimmed.len and trimmed[pos] == ':';
        if (right_colon) pos += 1;

        if (col_count >= TableState.max_cols) return null;
        alignments[col_count] = if (left_colon and right_colon)
            .center
        else if (right_colon)
            .right
        else if (left_colon)
            .left
        else
            .none;
        col_count += 1;

        // Skip spaces then expect pipe or end
        while (pos < trimmed.len and trimmed[pos] == ' ') pos += 1;
        if (pos < trimmed.len) {
            if (trimmed[pos] == '|') {
                pos += 1;
            } else {
                return null; // unexpected character
            }
        }
    }
    if (col_count == 0) return null;
    return .{ .col_count = col_count, .alignments = alignments };
}

/// Split a table row into cells. Handles escaped pipes (\|).
/// Returns slice of cell text slices (trimmed), using a static buffer.
fn splitTableRow(line: []const u8, buf: *[TableState.max_cols][]const u8) usize {
    const trimmed = std.mem.trim(u8, line, " \t");
    var count: usize = 0;
    var pos: usize = 0;

    // Skip leading pipe
    if (pos < trimmed.len and trimmed[pos] == '|') pos += 1;

    while (pos < trimmed.len and count < TableState.max_cols) {
        const cell_start = pos;
        var cell_end = pos;
        while (pos < trimmed.len and trimmed[pos] != '|') {
            if (trimmed[pos] == '\\' and pos + 1 < trimmed.len and trimmed[pos + 1] == '|') {
                pos += 2; // skip escaped pipe
            } else {
                pos += 1;
            }
            cell_end = pos;
        }
        // Don't add empty cell after trailing pipe
        if (pos >= trimmed.len and cell_start == cell_end) break;
        buf[count] = std.mem.trim(u8, trimmed[cell_start..cell_end], " \t");
        count += 1;
        if (pos < trimmed.len and trimmed[pos] == '|') pos += 1;
    }
    return count;
}

/// Extract the last line from paragraph state. Returns the last line and
/// updates para to exclude it. Returns null if para has no content.
fn paraExtractLastLine(para: *ParaState, source: []const u8) ?[]const u8 {
    if (para.in_container) {
        const text = para.buf.items;
        if (text.len == 0) return null;
        // Find last newline
        if (std.mem.lastIndexOfScalar(u8, text, '\n')) |nl| {
            const last_line = text[nl + 1 ..];
            para.buf.shrinkRetainingCapacity(nl);
            if (para.buf.items.len == 0) para.active = false;
            return last_line;
        } else {
            // Single line — take it all
            const line = para.buf.items;
            para.reset();
            return line;
        }
    } else {
        const text = source[para.source_start..para.source_end];
        if (text.len == 0) return null;
        if (std.mem.lastIndexOfScalar(u8, text, '\n')) |nl| {
            const last_line = text[nl + 1 ..];
            para.source_end = para.source_start + nl;
            if (para.source_start >= para.source_end) para.active = false;
            return last_line;
        } else {
            const line = text;
            para.reset();
            return line;
        }
    }
}

/// Build a table row node with cells, parsing inline content in each cell.
fn buildTableRow(
    doc: *Document,
    arena: std.mem.Allocator,
    row_text: []const u8,
    col_count: usize,
    alignments: [TableState.max_cols]ast.Alignment,
    is_header: bool,
    source_start: usize,
    source_end: usize,
    pending: *std.ArrayListUnmanaged(PendingInline),
) !*Node {
    const row = try doc.createNode(.table_row, .{ .none = {} }, .{ .start = source_start, .end = source_end });
    var cell_buf: [TableState.max_cols][]const u8 = undefined;
    const cell_count = splitTableRow(row_text, &cell_buf);

    for (0..col_count) |i| {
        const cell_text = if (i < cell_count) cell_buf[i] else "";
        const cell = try doc.createNode(.table_cell, .{ .table_cell = .{
            .alignment = alignments[i],
            .is_header = is_header,
        } }, .{ .start = source_start, .end = source_end });
        row.appendChild(cell);
        if (cell_text.len > 0) {
            const duped = try arena.dupe(u8, cell_text);
            try pending.append(arena, .{ .node = cell, .text = duped });
        }
    }
    return row;
}

// ── Tests ──────────────────────────────────────────────────────────────

test "ATX heading parsing" {
    try std.testing.expectEqual(@as(u3, 1), tryParseAtxHeading("# Hello").?.level);
    try std.testing.expectEqualStrings("Hello", tryParseAtxHeading("# Hello").?.content);
    try std.testing.expectEqual(@as(u3, 2), tryParseAtxHeading("## World").?.level);
    try std.testing.expectEqual(@as(u3, 6), tryParseAtxHeading("###### Six").?.level);
    try std.testing.expectEqual(null, tryParseAtxHeading("#NoSpace"));
    try std.testing.expectEqual(null, tryParseAtxHeading("####### Seven"));
    try std.testing.expectEqualStrings("", tryParseAtxHeading("#").?.content);
    try std.testing.expectEqualStrings("", tryParseAtxHeading("# ").?.content);
    try std.testing.expectEqualStrings("Hello", tryParseAtxHeading("# Hello #").?.content);
    try std.testing.expectEqualStrings("Hello", tryParseAtxHeading("# Hello ###").?.content);
}

test "fence open parsing" {
    const f1 = tryParseFenceOpen("```").?;
    try std.testing.expectEqual(@as(u8, '`'), f1.char);
    try std.testing.expectEqual(@as(u8, 3), f1.len);
    try std.testing.expectEqualStrings("", f1.info);

    const f2 = tryParseFenceOpen("```rust").?;
    try std.testing.expectEqualStrings("rust", f2.info);

    const f3 = tryParseFenceOpen("~~~").?;
    try std.testing.expectEqual(@as(u8, '~'), f3.char);

    const f4 = tryParseFenceOpen("`````python").?;
    try std.testing.expectEqual(@as(u8, 5), f4.len);
    try std.testing.expectEqualStrings("python", f4.info);

    try std.testing.expectEqual(null, tryParseFenceOpen("``"));
    try std.testing.expectEqual(null, tryParseFenceOpen("``` foo`bar"));

    const f5 = tryParseFenceOpen("~~~ foo`bar").?;
    try std.testing.expectEqualStrings("foo`bar", f5.info);
}

test "closing fence parsing" {
    try std.testing.expect(tryParseClosingFence("```", '`', 3));
    try std.testing.expect(tryParseClosingFence("````", '`', 3));
    try std.testing.expect(tryParseClosingFence("```  ", '`', 3));
    try std.testing.expect(!tryParseClosingFence("``", '`', 3));
    try std.testing.expect(!tryParseClosingFence("~~~", '`', 3));
    try std.testing.expect(!tryParseClosingFence("    ```", '`', 3));
    try std.testing.expect(!tryParseClosingFence("``` foo", '`', 3));
}

test "setext marker parsing" {
    try std.testing.expectEqual(@as(u3, 1), tryParseSetextMarker("==="));
    try std.testing.expectEqual(@as(u3, 1), tryParseSetextMarker("="));
    try std.testing.expectEqual(@as(u3, 1), tryParseSetextMarker("=====  "));
    try std.testing.expectEqual(@as(u3, 2), tryParseSetextMarker("---"));
    try std.testing.expectEqual(@as(u3, 2), tryParseSetextMarker("-"));
    try std.testing.expectEqual(@as(u3, 2), tryParseSetextMarker("-----  "));
    try std.testing.expectEqual(null, tryParseSetextMarker("- - -"));
    try std.testing.expectEqual(null, tryParseSetextMarker("==-"));
    try std.testing.expectEqual(null, tryParseSetextMarker(""));
}

test "blockquote marker stripping" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("hello", (try tryStripBqMarker("> hello", a)).?);
    try std.testing.expectEqualStrings("hello", (try tryStripBqMarker(">hello", a)).?);
    try std.testing.expectEqualStrings("", (try tryStripBqMarker("> ", a)).?);
    try std.testing.expectEqualStrings("", (try tryStripBqMarker(">", a)).?);
    try std.testing.expectEqual(null, try tryStripBqMarker("hello", a));
    try std.testing.expectEqual(null, try tryStripBqMarker("", a));
    try std.testing.expectEqual(null, try tryStripBqMarker("    > too indented", a));
    // Leading spaces (0-3) before >
    try std.testing.expectEqualStrings("ok", (try tryStripBqMarker("  > ok", a)).?);
    try std.testing.expectEqualStrings("ok", (try tryStripBqMarker("   > ok", a)).?);
    // Tab after > — partial tab expansion with leading tabs expanded
    // > at col 0, tab at col 1 → expands to col 4, 1 col consumed as optional space, 2 remaining
    // Second tab at col 4 → expands to col 8 → 4 spaces. Total: 2+4=6 spaces before foo
    try std.testing.expectEqualStrings("      foo", (try tryStripBqMarker(">\t\tfoo", a)).?);
}

test "thematic break parsing" {
    try std.testing.expect(tryParseThematicBreak("---"));
    try std.testing.expect(tryParseThematicBreak("***"));
    try std.testing.expect(tryParseThematicBreak("___"));
    try std.testing.expect(tryParseThematicBreak("- - -"));
    try std.testing.expect(tryParseThematicBreak("----------"));
    try std.testing.expect(!tryParseThematicBreak("--"));
    try std.testing.expect(!tryParseThematicBreak("-_-"));
    try std.testing.expect(!tryParseThematicBreak("abc"));
}

test "parse thematic break" {
    const allocator = std.testing.allocator;
    var doc = try parse(allocator,
        \\First
        \\
        \\---
        \\
        \\Second
    );
    defer doc.deinit();

    const p1 = doc.root.first_child.?;
    try std.testing.expectEqual(Tag.paragraph, p1.tag);
    const tb = p1.next.?;
    try std.testing.expectEqual(Tag.thematic_break, tb.tag);
    const p2 = tb.next.?;
    try std.testing.expectEqual(Tag.paragraph, p2.tag);
}

test "parse fenced code block" {
    const allocator = std.testing.allocator;
    const source =
        \\```
        \\hello
        \\world
        \\```
    ;
    var doc = try parse(allocator, source);
    defer doc.deinit();

    const cb = doc.root.first_child.?;
    try std.testing.expectEqual(Tag.code_block, cb.tag);
    const cbd = doc.getCodeBlockData(cb.data.code_block);
    try std.testing.expect(cbd.fenced);
    try std.testing.expectEqual(@as(u8, '`'), cbd.fence_char);
    try std.testing.expectEqual(@as(u8, 3), cbd.fence_len);

    const text = cb.first_child.?;
    try std.testing.expectEqualStrings("hello\nworld", doc.nodeText(text));
}

test "parse fenced code block with info string" {
    const allocator = std.testing.allocator;
    const source =
        \\```rust
        \\fn main() {}
        \\```
    ;
    var doc = try parse(allocator, source);
    defer doc.deinit();

    const cb = doc.root.first_child.?;
    try std.testing.expectEqual(Tag.code_block, cb.tag);
    try std.testing.expectEqualStrings("rust", doc.getCodeBlockData(cb.data.code_block).info);

    const text = cb.first_child.?;
    try std.testing.expectEqualStrings("fn main() {}", doc.nodeText(text));
}

test "parse unclosed fenced code block" {
    const allocator = std.testing.allocator;
    const source =
        \\```
        \\no closing fence
    ;
    var doc = try parse(allocator, source);
    defer doc.deinit();

    const cb = doc.root.first_child.?;
    try std.testing.expectEqual(Tag.code_block, cb.tag);
    const text = cb.first_child.?;
    try std.testing.expectEqualStrings("no closing fence", doc.nodeText(text));
}

test "parse empty fenced code block" {
    const allocator = std.testing.allocator;
    const source =
        \\```
        \\```
    ;
    var doc = try parse(allocator, source);
    defer doc.deinit();

    const cb = doc.root.first_child.?;
    try std.testing.expectEqual(Tag.code_block, cb.tag);
    try std.testing.expectEqual(null, cb.first_child);
}

test "parse setext heading level 1" {
    const allocator = std.testing.allocator;
    var doc = try parse(allocator,
        \\Hello
        \\=====
    );
    defer doc.deinit();

    const h = doc.root.first_child.?;
    try std.testing.expectEqual(Tag.heading, h.tag);
    try std.testing.expectEqual(@as(u3, 1), h.data.heading.level);
    try std.testing.expect(h.data.heading.setext);
    const text = h.first_child.?;
    try std.testing.expectEqualStrings("Hello", doc.nodeText(text));
}

test "parse setext heading level 2" {
    const allocator = std.testing.allocator;
    var doc = try parse(allocator,
        \\World
        \\-----
    );
    defer doc.deinit();

    const h = doc.root.first_child.?;
    try std.testing.expectEqual(Tag.heading, h.tag);
    try std.testing.expectEqual(@as(u3, 2), h.data.heading.level);
    try std.testing.expect(h.data.heading.setext);
}

test "setext vs thematic break — paragraph present means setext" {
    const allocator = std.testing.allocator;
    var doc = try parse(allocator,
        \\Heading
        \\---
    );
    defer doc.deinit();

    const h = doc.root.first_child.?;
    try std.testing.expectEqual(Tag.heading, h.tag);
    try std.testing.expectEqual(@as(u3, 2), h.data.heading.level);
    try std.testing.expectEqual(null, h.next);
}

test "--- without paragraph is thematic break" {
    const allocator = std.testing.allocator;
    var doc = try parse(allocator,
        \\---
    );
    defer doc.deinit();

    const tb = doc.root.first_child.?;
    try std.testing.expectEqual(Tag.thematic_break, tb.tag);
}

test "parse multi-line setext heading" {
    const allocator = std.testing.allocator;
    var doc = try parse(allocator,
        \\First line
        \\second line
        \\===
    );
    defer doc.deinit();

    const h = doc.root.first_child.?;
    try std.testing.expectEqual(Tag.heading, h.tag);
    try std.testing.expectEqual(@as(u3, 1), h.data.heading.level);
    try std.testing.expect(h.data.heading.setext);
    const text1 = h.first_child.?;
    try std.testing.expectEqual(Tag.text, text1.tag);
    try std.testing.expectEqualStrings("First line", doc.nodeText(text1));
    const sb = text1.next.?;
    try std.testing.expectEqual(Tag.soft_break, sb.tag);
    const text2 = sb.next.?;
    try std.testing.expectEqual(Tag.text, text2.tag);
    try std.testing.expectEqualStrings("second line", doc.nodeText(text2));
}

test "parse simple blockquote" {
    const allocator = std.testing.allocator;
    var doc = try parse(allocator,
        \\> Hello, world!
    );
    defer doc.deinit();

    const bq = doc.root.first_child.?;
    try std.testing.expectEqual(Tag.block_quote, bq.tag);
    const p = bq.first_child.?;
    try std.testing.expectEqual(Tag.paragraph, p.tag);
    const text = p.first_child.?;
    try std.testing.expectEqualStrings("Hello, world!", doc.nodeText(text));
}

test "parse multi-line blockquote" {
    const allocator = std.testing.allocator;
    var doc = try parse(allocator,
        \\> Line one
        \\> Line two
    );
    defer doc.deinit();

    const bq = doc.root.first_child.?;
    try std.testing.expectEqual(Tag.block_quote, bq.tag);
    const p = bq.first_child.?;
    try std.testing.expectEqual(Tag.paragraph, p.tag);
    const text1 = p.first_child.?;
    try std.testing.expectEqual(Tag.text, text1.tag);
    try std.testing.expectEqualStrings("Line one", doc.nodeText(text1));
    const sb = text1.next.?;
    try std.testing.expectEqual(Tag.soft_break, sb.tag);
    const text2 = sb.next.?;
    try std.testing.expectEqual(Tag.text, text2.tag);
    try std.testing.expectEqualStrings("Line two", doc.nodeText(text2));
}

test "parse blockquote with heading" {
    const allocator = std.testing.allocator;
    var doc = try parse(allocator,
        \\> # Heading
        \\> Some text
    );
    defer doc.deinit();

    const bq = doc.root.first_child.?;
    try std.testing.expectEqual(Tag.block_quote, bq.tag);

    const h = bq.first_child.?;
    try std.testing.expectEqual(Tag.heading, h.tag);
    const h_text = h.first_child.?;
    try std.testing.expectEqualStrings("Heading", doc.nodeText(h_text));

    const p = h.next.?;
    try std.testing.expectEqual(Tag.paragraph, p.tag);
    const p_text = p.first_child.?;
    try std.testing.expectEqualStrings("Some text", doc.nodeText(p_text));
}

test "parse nested blockquote" {
    const allocator = std.testing.allocator;
    var doc = try parse(allocator,
        \\> > Nested
    );
    defer doc.deinit();

    const bq1 = doc.root.first_child.?;
    try std.testing.expectEqual(Tag.block_quote, bq1.tag);
    const bq2 = bq1.first_child.?;
    try std.testing.expectEqual(Tag.block_quote, bq2.tag);
    const p = bq2.first_child.?;
    try std.testing.expectEqual(Tag.paragraph, p.tag);
    try std.testing.expectEqualStrings("Nested", doc.nodeText(p.first_child.?));
}

test "parse blockquote then paragraph" {
    const allocator = std.testing.allocator;
    var doc = try parse(allocator,
        \\> Quoted
        \\
        \\Regular
    );
    defer doc.deinit();

    const bq = doc.root.first_child.?;
    try std.testing.expectEqual(Tag.block_quote, bq.tag);
    const bq_p = bq.first_child.?;
    try std.testing.expectEqualStrings("Quoted", doc.nodeText(bq_p.first_child.?));

    const p = bq.next.?;
    try std.testing.expectEqual(Tag.paragraph, p.tag);
    try std.testing.expectEqualStrings("Regular", doc.nodeText(p.first_child.?));
}

test "parse blockquote with code block" {
    const allocator = std.testing.allocator;
    var doc = try parse(allocator,
        \\> ```
        \\> code
        \\> ```
    );
    defer doc.deinit();

    const bq = doc.root.first_child.?;
    try std.testing.expectEqual(Tag.block_quote, bq.tag);
    const cb = bq.first_child.?;
    try std.testing.expectEqual(Tag.code_block, cb.tag);
    const text = cb.first_child.?;
    try std.testing.expectEqualStrings("code", doc.nodeText(text));
}

test "parse empty blockquote" {
    const allocator = std.testing.allocator;
    var doc = try parse(allocator,
        \\>
    );
    defer doc.deinit();

    const bq = doc.root.first_child.?;
    try std.testing.expectEqual(Tag.block_quote, bq.tag);
    try std.testing.expectEqual(null, bq.first_child);
}

test "blockquote lazy continuation" {
    const allocator = std.testing.allocator;
    // No blank line — lazy continuation: "Not quoted" stays in blockquote
    var doc = try parse(allocator,
        \\> Quoted
        \\Not quoted
    );
    defer doc.deinit();

    const bq = doc.root.first_child.?;
    try std.testing.expectEqual(Tag.block_quote, bq.tag);
    // Both lines are in the same blockquote paragraph
    try std.testing.expect(bq.first_child != null);
}

test "blockquote ends with blank line" {
    const allocator = std.testing.allocator;
    // Blank line breaks out of blockquote
    var doc = try parse(allocator, "> Quoted\n\nNot quoted");
    defer doc.deinit();

    const bq = doc.root.first_child.?;
    try std.testing.expectEqual(Tag.block_quote, bq.tag);

    const p = bq.next.?;
    try std.testing.expectEqual(Tag.paragraph, p.tag);
}

// ── List marker parsing tests ─────────────────────────────────────────

test "list marker parsing — bullet" {
    const m1 = tryParseListMarker("- foo").?;
    try std.testing.expect(!m1.ordered);
    try std.testing.expectEqual(@as(u8, '-'), m1.marker);
    try std.testing.expectEqual(@as(usize, 2), m1.content_offset);

    const m2 = tryParseListMarker("* bar").?;
    try std.testing.expectEqual(@as(u8, '*'), m2.marker);

    const m3 = tryParseListMarker("+ baz").?;
    try std.testing.expectEqual(@as(u8, '+'), m3.marker);

    // No space after marker
    try std.testing.expectEqual(null, tryParseListMarker("-foo"));
    try std.testing.expectEqual(null, tryParseListMarker("*foo"));

    // Empty item (marker at end of line)
    const m4 = tryParseListMarker("-").?;
    try std.testing.expect(!m4.ordered);
    try std.testing.expectEqual(@as(usize, 2), m4.content_offset);
}

test "list marker parsing — ordered" {
    const m1 = tryParseListMarker("1. foo").?;
    try std.testing.expect(m1.ordered);
    try std.testing.expectEqual(@as(u8, '.'), m1.marker);
    try std.testing.expectEqual(@as(u32, 1), m1.start_num);
    try std.testing.expectEqual(@as(usize, 3), m1.content_offset);

    const m2 = tryParseListMarker("10) bar").?;
    try std.testing.expect(m2.ordered);
    try std.testing.expectEqual(@as(u8, ')'), m2.marker);
    try std.testing.expectEqual(@as(u32, 10), m2.start_num);
    try std.testing.expectEqual(@as(usize, 4), m2.content_offset);

    // No delimiter
    try std.testing.expectEqual(null, tryParseListMarker("1 foo"));
    // No space after delimiter
    try std.testing.expectEqual(null, tryParseListMarker("1.foo"));
}

// ── List integration tests ────────────────────────────────────────────

test "parse simple bullet list" {
    const allocator = std.testing.allocator;
    var doc = try parse(allocator,
        \\- alpha
        \\- beta
        \\- gamma
    );
    defer doc.deinit();

    const list_node = doc.root.first_child.?;
    try std.testing.expectEqual(Tag.list, list_node.tag);
    try std.testing.expect(!list_node.data.list.ordered);
    try std.testing.expectEqual(@as(u8, '-'), list_node.data.list.marker);
    try std.testing.expect(list_node.data.list.tight);

    // Three items
    var item = list_node.first_child.?;
    try std.testing.expectEqual(Tag.list_item, item.tag);
    try std.testing.expectEqualStrings("alpha", doc.nodeText(item.first_child.?.first_child.?));

    item = item.next.?;
    try std.testing.expectEqual(Tag.list_item, item.tag);
    try std.testing.expectEqualStrings("beta", doc.nodeText(item.first_child.?.first_child.?));

    item = item.next.?;
    try std.testing.expectEqual(Tag.list_item, item.tag);
    try std.testing.expectEqualStrings("gamma", doc.nodeText(item.first_child.?.first_child.?));

    try std.testing.expectEqual(null, item.next);
}

test "parse ordered list" {
    const allocator = std.testing.allocator;
    var doc = try parse(allocator,
        \\1. first
        \\2. second
        \\3. third
    );
    defer doc.deinit();

    const list_node = doc.root.first_child.?;
    try std.testing.expectEqual(Tag.list, list_node.tag);
    try std.testing.expect(list_node.data.list.ordered);
    try std.testing.expectEqual(@as(u8, '.'), list_node.data.list.marker);
    try std.testing.expectEqual(@as(u32, 1), list_node.data.list.start);
    try std.testing.expect(list_node.data.list.tight);

    var item = list_node.first_child.?;
    try std.testing.expectEqualStrings("first", doc.nodeText(item.first_child.?.first_child.?));
    item = item.next.?;
    try std.testing.expectEqualStrings("second", doc.nodeText(item.first_child.?.first_child.?));
    item = item.next.?;
    try std.testing.expectEqualStrings("third", doc.nodeText(item.first_child.?.first_child.?));
    try std.testing.expectEqual(null, item.next);
}

test "parse multi-line list item" {
    const allocator = std.testing.allocator;
    var doc = try parse(allocator,
        \\- line one
        \\  line two
    );
    defer doc.deinit();

    const list_node = doc.root.first_child.?;
    try std.testing.expectEqual(Tag.list, list_node.tag);

    const item = list_node.first_child.?;
    const text1 = item.first_child.?.first_child.?;
    try std.testing.expectEqual(Tag.text, text1.tag);
    try std.testing.expectEqualStrings("line one", doc.nodeText(text1));
    const sb = text1.next.?;
    try std.testing.expectEqual(Tag.soft_break, sb.tag);
    const text2 = sb.next.?;
    try std.testing.expectEqual(Tag.text, text2.tag);
    try std.testing.expectEqualStrings("line two", doc.nodeText(text2));
}

test "parse loose list" {
    const allocator = std.testing.allocator;
    var doc = try parse(allocator,
        \\- alpha
        \\
        \\- beta
    );
    defer doc.deinit();

    const list_node = doc.root.first_child.?;
    try std.testing.expectEqual(Tag.list, list_node.tag);
    try std.testing.expect(!list_node.data.list.tight);

    var item = list_node.first_child.?;
    try std.testing.expectEqualStrings("alpha", doc.nodeText(item.first_child.?.first_child.?));
    item = item.next.?;
    try std.testing.expectEqualStrings("beta", doc.nodeText(item.first_child.?.first_child.?));
}

test "list followed by paragraph" {
    const allocator = std.testing.allocator;
    var doc = try parse(allocator,
        \\- item
        \\
        \\After the list.
    );
    defer doc.deinit();

    const list_node = doc.root.first_child.?;
    try std.testing.expectEqual(Tag.list, list_node.tag);

    const p = list_node.next.?;
    try std.testing.expectEqual(Tag.paragraph, p.tag);
    try std.testing.expectEqualStrings("After the list.", doc.nodeText(p.first_child.?));
}

test "list lazy continuation on unindented paragraph text" {
    const allocator = std.testing.allocator;
    // Per CommonMark laziness rule: unindented paragraph continuation text
    // continues the list item's paragraph.
    var doc = try parse(allocator,
        \\- item
        \\not a list
    );
    defer doc.deinit();

    const list_node = doc.root.first_child.?;
    try std.testing.expectEqual(Tag.list, list_node.tag);

    // "not a list" is lazy continuation of the paragraph in the list item
    const item = list_node.first_child.?;
    try std.testing.expectEqual(Tag.list_item, item.tag);
    try std.testing.expectEqual(null, list_node.next);
}

test "list ends after blank then unindented line" {
    const allocator = std.testing.allocator;
    // After a blank line, unindented text closes the list
    var doc = try parse(allocator,
        \\- item
        \\
        \\not a list
    );
    defer doc.deinit();

    const list_node = doc.root.first_child.?;
    try std.testing.expectEqual(Tag.list, list_node.tag);

    const p = list_node.next.?;
    try std.testing.expectEqual(Tag.paragraph, p.tag);
    try std.testing.expectEqualStrings("not a list", doc.nodeText(p.first_child.?));
}

test "different bullet markers create separate lists" {
    const allocator = std.testing.allocator;
    var doc = try parse(allocator,
        \\- dash
        \\* star
    );
    defer doc.deinit();

    const list1 = doc.root.first_child.?;
    try std.testing.expectEqual(Tag.list, list1.tag);
    try std.testing.expectEqual(@as(u8, '-'), list1.data.list.marker);

    const list2 = list1.next.?;
    try std.testing.expectEqual(Tag.list, list2.tag);
    try std.testing.expectEqual(@as(u8, '*'), list2.data.list.marker);
}

test "thematic break ends bullet list" {
    const allocator = std.testing.allocator;
    var doc = try parse(allocator,
        \\- item
        \\---
    );
    defer doc.deinit();

    const list_node = doc.root.first_child.?;
    try std.testing.expectEqual(Tag.list, list_node.tag);

    const tb = list_node.next.?;
    try std.testing.expectEqual(Tag.thematic_break, tb.tag);
}

test "paragraph then list — list interrupts paragraph" {
    const allocator = std.testing.allocator;
    var doc = try parse(allocator,
        \\Some text
        \\- item
    );
    defer doc.deinit();

    const p = doc.root.first_child.?;
    try std.testing.expectEqual(Tag.paragraph, p.tag);
    try std.testing.expectEqualStrings("Some text", doc.nodeText(p.first_child.?));

    const list_node = p.next.?;
    try std.testing.expectEqual(Tag.list, list_node.tag);
}

test "ordered list starting with non-1 cannot interrupt paragraph" {
    const allocator = std.testing.allocator;
    var doc = try parse(allocator,
        \\Some text
        \\3. item
    );
    defer doc.deinit();

    // Should be a single paragraph since ordered list starting with 3 can't interrupt
    const p = doc.root.first_child.?;
    try std.testing.expectEqual(Tag.paragraph, p.tag);
    try std.testing.expectEqual(null, p.next);
}

test "ordered list starting with 1 can interrupt paragraph" {
    const allocator = std.testing.allocator;
    var doc = try parse(allocator,
        \\Some text
        \\1. item
    );
    defer doc.deinit();

    const p = doc.root.first_child.?;
    try std.testing.expectEqual(Tag.paragraph, p.tag);

    const list_node = p.next.?;
    try std.testing.expectEqual(Tag.list, list_node.tag);
    try std.testing.expect(list_node.data.list.ordered);
}

test "parse empty list item" {
    const allocator = std.testing.allocator;
    var doc = try parse(allocator,
        \\-
        \\- item
    );
    defer doc.deinit();

    const list_node = doc.root.first_child.?;
    try std.testing.expectEqual(Tag.list, list_node.tag);

    const item1 = list_node.first_child.?;
    try std.testing.expectEqual(Tag.list_item, item1.tag);
    try std.testing.expectEqual(null, item1.first_child); // empty item

    const item2 = item1.next.?;
    try std.testing.expectEqual(Tag.list_item, item2.tag);
    try std.testing.expectEqualStrings("item", doc.nodeText(item2.first_child.?.first_child.?));
}

// ── Indented code block tests ─────────────────────────────────────────

test "parse basic indented code block" {
    const allocator = std.testing.allocator;
    var doc = try parse(allocator, "    hello");
    defer doc.deinit();

    const cb = doc.root.first_child.?;
    try std.testing.expectEqual(Tag.code_block, cb.tag);
    try std.testing.expect(!doc.getCodeBlockData(cb.data.code_block).fenced);
    const text = cb.first_child.?;
    try std.testing.expectEqualStrings("hello", doc.nodeText(text));
}

test "parse multi-line indented code block" {
    const allocator = std.testing.allocator;
    var doc = try parse(allocator,
        \\    line one
        \\    line two
        \\    line three
    );
    defer doc.deinit();

    const cb = doc.root.first_child.?;
    try std.testing.expectEqual(Tag.code_block, cb.tag);
    const text = cb.first_child.?;
    try std.testing.expectEqualStrings("line one\nline two\nline three", doc.nodeText(text));
}

test "indented code block with blank lines" {
    const allocator = std.testing.allocator;
    var doc = try parse(allocator,
        \\    line one
        \\
        \\    line three
    );
    defer doc.deinit();

    const cb = doc.root.first_child.?;
    try std.testing.expectEqual(Tag.code_block, cb.tag);
    const text = cb.first_child.?;
    try std.testing.expectEqualStrings("line one\n\nline three", doc.nodeText(text));
}

test "indented code block trailing blanks stripped" {
    const allocator = std.testing.allocator;
    var doc = try parse(allocator,
        \\    code
        \\
        \\paragraph
    );
    defer doc.deinit();

    const cb = doc.root.first_child.?;
    try std.testing.expectEqual(Tag.code_block, cb.tag);
    const text = cb.first_child.?;
    try std.testing.expectEqualStrings("code", doc.nodeText(text));

    const p = cb.next.?;
    try std.testing.expectEqual(Tag.paragraph, p.tag);
}

test "indented code block cannot interrupt paragraph" {
    const allocator = std.testing.allocator;
    var doc = try parse(allocator,
        \\hello
        \\    world
    );
    defer doc.deinit();

    const p = doc.root.first_child.?;
    try std.testing.expectEqual(Tag.paragraph, p.tag);
    // Indented line continues the paragraph (lazy continuation)
    try std.testing.expectEqual(null, p.next);
}

test "indented code block after blank line after paragraph" {
    const allocator = std.testing.allocator;
    var doc = try parse(allocator,
        \\hello
        \\
        \\    code
    );
    defer doc.deinit();

    const p = doc.root.first_child.?;
    try std.testing.expectEqual(Tag.paragraph, p.tag);

    const cb = p.next.?;
    try std.testing.expectEqual(Tag.code_block, cb.tag);
    try std.testing.expect(!doc.getCodeBlockData(cb.data.code_block).fenced);
    try std.testing.expectEqualStrings("code", doc.nodeText(cb.first_child.?));
}

test "indented code block preserves extra indent" {
    const allocator = std.testing.allocator;
    var doc = try parse(allocator, "      extra");
    defer doc.deinit();

    const cb = doc.root.first_child.?;
    try std.testing.expectEqual(Tag.code_block, cb.tag);
    // 6 spaces - 4 stripped = 2 extra spaces preserved
    try std.testing.expectEqualStrings("  extra", doc.nodeText(cb.first_child.?));
}

test "indented code block in blockquote" {
    const allocator = std.testing.allocator;
    // ">      code" — after BQ strip (> + 1 space), 5 spaces remain, minus 4 = "code" with 1 extra
    var doc = try parse(allocator,
        \\>      code
    );
    defer doc.deinit();

    const bq = doc.root.first_child.?;
    try std.testing.expectEqual(Tag.block_quote, bq.tag);
    const cb = bq.first_child.?;
    try std.testing.expectEqual(Tag.code_block, cb.tag);
    try std.testing.expectEqualStrings(" code", doc.nodeText(cb.first_child.?));
}

// ── HTML block tests ──────────────────────────────────────────────────

test "HTML block type 1 — pre" {
    const allocator = std.testing.allocator;
    var doc = try parse(allocator, "<pre>\nhello\n</pre>");
    defer doc.deinit();

    const hb = doc.root.first_child.?;
    try std.testing.expectEqual(Tag.html_block, hb.tag);
    try std.testing.expectEqualStrings("<pre>\nhello\n</pre>", doc.nodeText(hb));
}

test "HTML block type 1 — script" {
    const allocator = std.testing.allocator;
    var doc = try parse(allocator, "<script>\nvar x = 1;\n</script>");
    defer doc.deinit();

    const hb = doc.root.first_child.?;
    try std.testing.expectEqual(Tag.html_block, hb.tag);
    try std.testing.expectEqualStrings("<script>\nvar x = 1;\n</script>", doc.nodeText(hb));
}

test "HTML block type 1 — same line close" {
    const allocator = std.testing.allocator;
    var doc = try parse(allocator, "<pre>foo</pre>");
    defer doc.deinit();

    const hb = doc.root.first_child.?;
    try std.testing.expectEqual(Tag.html_block, hb.tag);
    try std.testing.expectEqualStrings("<pre>foo</pre>", doc.nodeText(hb));
}

test "HTML block type 6 — div ends on blank line" {
    const allocator = std.testing.allocator;
    var doc = try parse(allocator, "<div>\ncontent\n\nAfter.");
    defer doc.deinit();

    const hb = doc.root.first_child.?;
    try std.testing.expectEqual(Tag.html_block, hb.tag);
    try std.testing.expectEqualStrings("<div>\ncontent", doc.nodeText(hb));

    const p = hb.next.?;
    try std.testing.expectEqual(Tag.paragraph, p.tag);
    try std.testing.expectEqualStrings("After.", doc.nodeText(p.first_child.?));
}

test "HTML block type 6 — interrupts paragraph" {
    const allocator = std.testing.allocator;
    var doc = try parse(allocator, "Some text\n<div>\nhtml\n\nAfter.");
    defer doc.deinit();

    const p1 = doc.root.first_child.?;
    try std.testing.expectEqual(Tag.paragraph, p1.tag);

    const hb = p1.next.?;
    try std.testing.expectEqual(Tag.html_block, hb.tag);
    try std.testing.expectEqualStrings("<div>\nhtml", doc.nodeText(hb));
}

test "HTML block type 7 — generic tag ends on blank" {
    const allocator = std.testing.allocator;
    var doc = try parse(allocator, "<custom>\nstuff\n\nAfter.");
    defer doc.deinit();

    const hb = doc.root.first_child.?;
    try std.testing.expectEqual(Tag.html_block, hb.tag);
    try std.testing.expectEqualStrings("<custom>\nstuff", doc.nodeText(hb));
}

test "HTML block type 7 — cannot interrupt paragraph" {
    const allocator = std.testing.allocator;
    var doc = try parse(allocator,
        \\Some text
        \\<custom>
    );
    defer doc.deinit();

    // Should be a single paragraph
    const p = doc.root.first_child.?;
    try std.testing.expectEqual(Tag.paragraph, p.tag);
    try std.testing.expectEqual(null, p.next);
}

test "HTML block unclosed at EOF" {
    const allocator = std.testing.allocator;
    var doc = try parse(allocator, "<div>\ncontent");
    defer doc.deinit();

    const hb = doc.root.first_child.?;
    try std.testing.expectEqual(Tag.html_block, hb.tag);
    try std.testing.expectEqualStrings("<div>\ncontent", doc.nodeText(hb));
}

test "HTML block type 1 unclosed at EOF" {
    const allocator = std.testing.allocator;
    var doc = try parse(allocator, "<pre>\ncode\nmore");
    defer doc.deinit();

    const hb = doc.root.first_child.?;
    try std.testing.expectEqual(Tag.html_block, hb.tag);
    try std.testing.expectEqualStrings("<pre>\ncode\nmore", doc.nodeText(hb));
}

// ── Link reference definition tests ───────────────────────────────────

test "link ref def — simple" {
    const allocator = std.testing.allocator;
    var doc = try parse(allocator, "[foo]: /url");
    defer doc.deinit();

    try std.testing.expectEqual(null, doc.root.first_child);

    const ref = doc.lookupRef("foo").?;
    try std.testing.expectEqualStrings("/url", ref.destination);
    try std.testing.expectEqualStrings("", ref.title);
}

test "link ref def — with double-quote title" {
    const allocator = std.testing.allocator;
    var doc = try parse(allocator,
        \\[foo]: /url "The Title"
    );
    defer doc.deinit();

    try std.testing.expectEqual(null, doc.root.first_child);

    const ref = doc.lookupRef("foo").?;
    try std.testing.expectEqualStrings("/url", ref.destination);
    try std.testing.expectEqualStrings("The Title", ref.title);
}

test "link ref def — with single-quote title" {
    const allocator = std.testing.allocator;
    var doc = try parse(allocator, "[foo]: /url 'The Title'");
    defer doc.deinit();

    const ref = doc.lookupRef("foo").?;
    try std.testing.expectEqualStrings("The Title", ref.title);
}

test "link ref def — with paren title" {
    const allocator = std.testing.allocator;
    var doc = try parse(allocator, "[foo]: /url (The Title)");
    defer doc.deinit();

    const ref = doc.lookupRef("foo").?;
    try std.testing.expectEqualStrings("The Title", ref.title);
}

test "link ref def — angle-bracket destination" {
    const allocator = std.testing.allocator;
    var doc = try parse(allocator, "[foo]: <http://example.com>");
    defer doc.deinit();

    const ref = doc.lookupRef("foo").?;
    try std.testing.expectEqualStrings("http://example.com", ref.destination);
}

test "link ref def — multiple defs" {
    const allocator = std.testing.allocator;
    var doc = try parse(allocator, "[foo]: /url1\n[bar]: /url2");
    defer doc.deinit();

    try std.testing.expectEqual(null, doc.root.first_child);

    const foo = doc.lookupRef("foo").?;
    try std.testing.expectEqualStrings("/url1", foo.destination);

    const bar = doc.lookupRef("bar").?;
    try std.testing.expectEqualStrings("/url2", bar.destination);
}

test "link ref def — partial consumption" {
    const allocator = std.testing.allocator;
    var doc = try parse(allocator, "[foo]: /url\nSome text here.");
    defer doc.deinit();

    const ref = doc.lookupRef("foo").?;
    try std.testing.expectEqualStrings("/url", ref.destination);

    const p = doc.root.first_child.?;
    try std.testing.expectEqual(Tag.paragraph, p.tag);
    try std.testing.expectEqualStrings("Some text here.", doc.nodeText(p.first_child.?));
}

test "link ref def — first def wins" {
    const allocator = std.testing.allocator;
    var doc = try parse(allocator, "[foo]: /url1\n[foo]: /url2");
    defer doc.deinit();

    const ref = doc.lookupRef("foo").?;
    try std.testing.expectEqualStrings("/url1", ref.destination);
}

test "link ref def — case-insensitive labels" {
    const allocator = std.testing.allocator;
    var doc = try parse(allocator, "[FOO]: /url");
    defer doc.deinit();

    const ref = doc.lookupRef("foo").?;
    try std.testing.expectEqualStrings("/url", ref.destination);
}

test "link ref def — invalid stays as paragraph" {
    const allocator = std.testing.allocator;
    var doc = try parse(allocator, "[foo] /url");
    defer doc.deinit();

    try std.testing.expectEqual(null, doc.lookupRef("foo"));

    const p = doc.root.first_child.?;
    try std.testing.expectEqual(Tag.paragraph, p.tag);
}

test "link ref def — in blockquote" {
    const allocator = std.testing.allocator;
    var doc = try parse(allocator, "> [foo]: /url\n> text");
    defer doc.deinit();

    const ref = doc.lookupRef("foo").?;
    try std.testing.expectEqualStrings("/url", ref.destination);

    const bq = doc.root.first_child.?;
    try std.testing.expectEqual(Tag.block_quote, bq.tag);
    const p = bq.first_child.?;
    try std.testing.expectEqual(Tag.paragraph, p.tag);
    try std.testing.expectEqualStrings("text", doc.nodeText(p.first_child.?));
}

test "link ref def — empty destination with angle brackets" {
    const allocator = std.testing.allocator;
    var doc = try parse(allocator, "[foo]: <>");
    defer doc.deinit();

    const ref = doc.lookupRef("foo").?;
    try std.testing.expectEqualStrings("", ref.destination);
}

// ── Frontmatter tests ─────────────────────────────────────────────────

test "frontmatter — basic" {
    const allocator = std.testing.allocator;
    var doc = try parseWith(allocator, "---\ntitle: Hello\n---\n\nBody text.", .{ .obsidian = true });
    defer doc.deinit();

    const fm = doc.root.first_child.?;
    try std.testing.expectEqual(Tag.frontmatter, fm.tag);
    try std.testing.expectEqualStrings("title: Hello\n", doc.nodeText(fm));

    const p = fm.next.?;
    try std.testing.expectEqual(Tag.paragraph, p.tag);
}

test "frontmatter — empty" {
    const allocator = std.testing.allocator;
    var doc = try parseWith(allocator, "---\n---\n\nBody.", .{ .obsidian = true });
    defer doc.deinit();

    const fm = doc.root.first_child.?;
    try std.testing.expectEqual(Tag.frontmatter, fm.tag);
    try std.testing.expectEqualStrings("", doc.nodeText(fm));
}

test "frontmatter — unclosed is not frontmatter" {
    const allocator = std.testing.allocator;
    var doc = try parseWith(allocator, "---\ntitle: Hello\nBody text.", .{ .obsidian = true });
    defer doc.deinit();

    // Should be treated as a thematic break + paragraph, not frontmatter
    const first = doc.root.first_child.?;
    try std.testing.expect(first.tag != .frontmatter);
}

test "frontmatter — extensions off treats --- as thematic break" {
    const allocator = std.testing.allocator;
    var doc = try parse(allocator, "---\ntitle: Hello\n---\n\nBody.");
    defer doc.deinit();

    const first = doc.root.first_child.?;
    try std.testing.expectEqual(Tag.thematic_break, first.tag);
}

test "frontmatter — not at start is not frontmatter" {
    const allocator = std.testing.allocator;
    var doc = try parseWith(allocator, "Hello\n\n---\ntitle: x\n---", .{ .obsidian = true });
    defer doc.deinit();

    const first = doc.root.first_child.?;
    try std.testing.expectEqual(Tag.paragraph, first.tag);
    // The --- should be a thematic break, not frontmatter
    const second = first.next.?;
    try std.testing.expect(second.tag != .frontmatter);
}

// ── GFM task list tests ──────────────────────────────────────────────────

test "gfm task list — checked and unchecked" {
    const allocator = std.testing.allocator;
    var doc = try parseWith(allocator, "- [ ] todo\n- [x] done", .{ .gfm = true });
    defer doc.deinit();

    const list_node = doc.root.first_child.?;
    try std.testing.expectEqual(Tag.list, list_node.tag);

    const item1 = list_node.first_child.?;
    try std.testing.expectEqual(Tag.list_item, item1.tag);
    try std.testing.expectEqual(ast.TaskState.unchecked, item1.data.task_state);

    const item2 = item1.next.?;
    try std.testing.expectEqual(Tag.list_item, item2.tag);
    try std.testing.expectEqual(ast.TaskState.checked, item2.data.task_state);
}

test "gfm task list — not enabled without gfm flag" {
    const allocator = std.testing.allocator;
    var doc = try parse(allocator, "- [ ] todo\n- [x] done");
    defer doc.deinit();

    const list_node = doc.root.first_child.?;
    const item1 = list_node.first_child.?;
    // Without gfm, list_item has .none data and "[ ] todo" is part of text
    try std.testing.expectEqual(ast.Data.none, item1.data);
}

test "gfm task list — uppercase X" {
    const allocator = std.testing.allocator;
    var doc = try parseWith(allocator, "- [X] done", .{ .gfm = true });
    defer doc.deinit();

    const item = doc.root.first_child.?.first_child.?;
    try std.testing.expectEqual(ast.TaskState.checked, item.data.task_state);
}

// ── GFM table tests ──────────────────────────────────────────────────

test "gfm table — basic" {
    const allocator = std.testing.allocator;
    var doc = try parseWith(allocator,
        \\| A | B |
        \\|---|---|
        \\| 1 | 2 |
    , .{ .gfm = true });
    defer doc.deinit();

    const tbl = doc.root.first_child.?;
    try std.testing.expectEqual(Tag.table, tbl.tag);

    const thead = tbl.first_child.?;
    try std.testing.expectEqual(Tag.table_head, thead.tag);
    const header_row = thead.first_child.?;
    try std.testing.expectEqual(Tag.table_row, header_row.tag);
    // 2 header cells
    const h1 = header_row.first_child.?;
    try std.testing.expectEqual(Tag.table_cell, h1.tag);
    try std.testing.expect(h1.data.table_cell.is_header);
    const h2 = h1.next.?;
    try std.testing.expectEqual(Tag.table_cell, h2.tag);
    try std.testing.expectEqual(null, h2.next);

    const tbody = thead.next.?;
    try std.testing.expectEqual(Tag.table_body, tbody.tag);
    const data_row = tbody.first_child.?;
    try std.testing.expectEqual(Tag.table_row, data_row.tag);
    const d1 = data_row.first_child.?;
    try std.testing.expectEqual(Tag.table_cell, d1.tag);
    try std.testing.expect(!d1.data.table_cell.is_header);
}

test "gfm table — alignment" {
    const allocator = std.testing.allocator;
    var doc = try parseWith(allocator,
        \\| L | C | R |
        \\|:--|:--:|--:|
        \\| a | b | c |
    , .{ .gfm = true });
    defer doc.deinit();

    const tbl = doc.root.first_child.?;
    const header_row = tbl.first_child.?.first_child.?;
    const c1 = header_row.first_child.?;
    try std.testing.expectEqual(ast.Alignment.left, c1.data.table_cell.alignment);
    const c2 = c1.next.?;
    try std.testing.expectEqual(ast.Alignment.center, c2.data.table_cell.alignment);
    const c3 = c2.next.?;
    try std.testing.expectEqual(ast.Alignment.right, c3.data.table_cell.alignment);
}

test "gfm table — not enabled without gfm flag" {
    const allocator = std.testing.allocator;
    var doc = try parse(allocator,
        \\| A | B |
        \\|---|---|
        \\| 1 | 2 |
    );
    defer doc.deinit();

    // Without gfm, this should be a paragraph
    const first = doc.root.first_child.?;
    try std.testing.expectEqual(Tag.paragraph, first.tag);
}

test "gfm table — paragraph before table" {
    const allocator = std.testing.allocator;
    var doc = try parseWith(allocator,
        \\Some text before.
        \\
        \\| A | B |
        \\|---|---|
        \\| 1 | 2 |
    , .{ .gfm = true });
    defer doc.deinit();

    const para = doc.root.first_child.?;
    try std.testing.expectEqual(Tag.paragraph, para.tag);
    const tbl = para.next.?;
    try std.testing.expectEqual(Tag.table, tbl.tag);
}

test "gfm table — multi-row body" {
    const allocator = std.testing.allocator;
    var doc = try parseWith(allocator,
        \\| H |
        \\|---|
        \\| a |
        \\| b |
        \\| c |
    , .{ .gfm = true });
    defer doc.deinit();

    const tbl = doc.root.first_child.?;
    const tbody = tbl.first_child.?.next.?;
    // 3 data rows
    var count: usize = 0;
    var row = tbody.first_child;
    while (row) |r| : (row = r.next) count += 1;
    try std.testing.expectEqual(@as(usize, 3), count);
}

test "gfm table — header only (no body rows)" {
    const allocator = std.testing.allocator;
    var doc = try parseWith(allocator,
        \\| H1 | H2 |
        \\|----|-----|
    , .{ .gfm = true });
    defer doc.deinit();

    const tbl = doc.root.first_child.?;
    try std.testing.expectEqual(Tag.table, tbl.tag);
    const thead = tbl.first_child.?;
    try std.testing.expectEqual(Tag.table_head, thead.tag);
    const tbody = thead.next.?;
    try std.testing.expectEqual(Tag.table_body, tbody.tag);
    // No data rows
    try std.testing.expectEqual(null, tbody.first_child);
}

test "gfm table — no leading/trailing pipes" {
    const allocator = std.testing.allocator;
    var doc = try parseWith(allocator,
        \\A | B
        \\--|--
        \\1 | 2
    , .{ .gfm = true });
    defer doc.deinit();

    const tbl = doc.root.first_child.?;
    try std.testing.expectEqual(Tag.table, tbl.tag);
    // 2 columns
    const header_row = tbl.first_child.?.first_child.?;
    const h1 = header_row.first_child.?;
    try std.testing.expect(h1.data.table_cell.is_header);
    const h2 = h1.next.?;
    try std.testing.expect(h2.data.table_cell.is_header);
    try std.testing.expectEqual(null, h2.next);
}

test "gfm table — fewer data cells than columns padded with empty" {
    const allocator = std.testing.allocator;
    var doc = try parseWith(allocator,
        \\| A | B | C |
        \\|---|---|---|
        \\| 1 |
    , .{ .gfm = true });
    defer doc.deinit();

    const tbl = doc.root.first_child.?;
    const data_row = tbl.first_child.?.next.?.first_child.?;
    // Should have 3 cells even though row only had 1
    var cell_count: usize = 0;
    var cell = data_row.first_child;
    while (cell) |c| : (cell = c.next) cell_count += 1;
    try std.testing.expectEqual(@as(usize, 3), cell_count);
}

test "gfm table — escaped pipe in cell" {
    const allocator = std.testing.allocator;
    var doc = try parseWith(allocator,
        \\| A |
        \\|---|
        \\| a\|b |
    , .{ .gfm = true });
    defer doc.deinit();

    const tbl = doc.root.first_child.?;
    try std.testing.expectEqual(Tag.table, tbl.tag);
    // Should be 1 column (escaped pipe doesn't split)
    const header_row = tbl.first_child.?.first_child.?;
    const h1 = header_row.first_child.?;
    try std.testing.expectEqual(null, h1.next);
}

test "gfm table — blank line terminates table" {
    const allocator = std.testing.allocator;
    var doc = try parseWith(allocator,
        \\| H |
        \\|---|
        \\| 1 |
        \\
        \\After table.
    , .{ .gfm = true });
    defer doc.deinit();

    const tbl = doc.root.first_child.?;
    try std.testing.expectEqual(Tag.table, tbl.tag);
    const para = tbl.next.?;
    try std.testing.expectEqual(Tag.paragraph, para.tag);
}

test "gfm table — separator without pipe is not a table" {
    const allocator = std.testing.allocator;
    // "---" alone is a thematic break or setext, not a table separator
    var doc = try parseWith(allocator,
        \\Header
        \\---
    , .{ .gfm = true });
    defer doc.deinit();

    // Should be a setext heading, not a table
    const first = doc.root.first_child.?;
    try std.testing.expectEqual(Tag.heading, first.tag);
}

test "gfm table — multi-line paragraph then table" {
    const allocator = std.testing.allocator;
    var doc = try parseWith(allocator,
        \\Line one
        \\line two
        \\| H |
        \\|---|
        \\| d |
    , .{ .gfm = true });
    defer doc.deinit();

    // "Line one\nline two" should be a paragraph,
    // "| H |" is the header, table follows
    const para = doc.root.first_child.?;
    try std.testing.expectEqual(Tag.paragraph, para.tag);
    const tbl = para.next.?;
    try std.testing.expectEqual(Tag.table, tbl.tag);
}

test "gfm table — inline formatting in cells" {
    const allocator = std.testing.allocator;
    var doc = try parseWith(allocator,
        \\| **bold** | *italic* |
        \\|----------|---------|
        \\| `code` | normal |
    , .{ .gfm = true });
    defer doc.deinit();

    const tbl = doc.root.first_child.?;
    try std.testing.expectEqual(Tag.table, tbl.tag);
    // Verify header cell has inline children (strong node)
    const h1 = tbl.first_child.?.first_child.?.first_child.?;
    const strong = h1.first_child.?;
    try std.testing.expectEqual(Tag.strong, strong.tag);
}

test "gfm table — paragraph after table" {
    const allocator = std.testing.allocator;
    var doc = try parseWith(allocator,
        \\| H |
        \\|---|
        \\| d |
        \\After.
    , .{ .gfm = true });
    defer doc.deinit();

    const tbl = doc.root.first_child.?;
    try std.testing.expectEqual(Tag.table, tbl.tag);
    // "After." has no pipe, so table closes and it's a paragraph
    const para = tbl.next.?;
    try std.testing.expectEqual(Tag.paragraph, para.tag);
}

// ── Task list edge cases ──────────────────────────────────────────────

test "gfm task list — mixed with normal items" {
    const allocator = std.testing.allocator;
    var doc = try parseWith(allocator, "- [ ] task\n- normal\n- [x] done", .{ .gfm = true });
    defer doc.deinit();

    const list_node = doc.root.first_child.?;
    const item1 = list_node.first_child.?;
    try std.testing.expectEqual(ast.TaskState.unchecked, item1.data.task_state);

    const item2 = item1.next.?;
    // Normal item has .none data
    try std.testing.expectEqual(ast.Data.none, item2.data);

    const item3 = item2.next.?;
    try std.testing.expectEqual(ast.TaskState.checked, item3.data.task_state);
}

test "gfm task list — ordered list" {
    const allocator = std.testing.allocator;
    var doc = try parseWith(allocator, "1. [ ] first\n2. [x] second", .{ .gfm = true });
    defer doc.deinit();

    const list_node = doc.root.first_child.?;
    try std.testing.expect(list_node.data.list.ordered);
    const item1 = list_node.first_child.?;
    try std.testing.expectEqual(ast.TaskState.unchecked, item1.data.task_state);
    const item2 = item1.next.?;
    try std.testing.expectEqual(ast.TaskState.checked, item2.data.task_state);
}

test "gfm task list — invalid markers not parsed" {
    const allocator = std.testing.allocator;
    // [o], [-], [X] without space after ] — should not be tasks
    var doc = try parseWith(allocator, "- [o] nope\n- [-] nope\n- [x]nope", .{ .gfm = true });
    defer doc.deinit();

    const list_node = doc.root.first_child.?;
    var item = list_node.first_child;
    while (item) |i| : (item = i.next) {
        try std.testing.expectEqual(ast.Data.none, i.data);
    }
}

test "gfm task list — text content preserved" {
    const allocator = std.testing.allocator;
    var doc = try parseWith(allocator, "- [ ] buy milk", .{ .gfm = true });
    defer doc.deinit();

    const item = doc.root.first_child.?.first_child.?;
    try std.testing.expectEqual(ast.TaskState.unchecked, item.data.task_state);
    // The paragraph child should contain "buy milk", not "[ ] buy milk"
    const para = item.first_child.?;
    try std.testing.expectEqual(Tag.paragraph, para.tag);
    const text = para.first_child.?;
    try std.testing.expectEqualStrings("buy milk", doc.nodeText(text));
}

// ── Separator parsing edge cases ──────────────────────────────────────

test "tryParseTableSeparator — various valid formats" {
    // Basic
    try std.testing.expect(tryParseTableSeparator("|---|---|") != null);
    // With alignment
    try std.testing.expect(tryParseTableSeparator("|:---|---:|:---:|") != null);
    // No outer pipes
    try std.testing.expect(tryParseTableSeparator("---|---") != null);
    // Single column with pipes
    try std.testing.expect(tryParseTableSeparator("|---|") != null);
    // Spaces around dashes
    try std.testing.expect(tryParseTableSeparator("| --- | --- |") != null);
    // Long dashes
    try std.testing.expect(tryParseTableSeparator("|--------|--------|") != null);
}

test "tryParseTableSeparator — invalid formats" {
    // No pipe at all
    try std.testing.expectEqual(null, tryParseTableSeparator("---"));
    // No dashes
    try std.testing.expectEqual(null, tryParseTableSeparator("|||"));
    // Just spaces and pipes
    try std.testing.expectEqual(null, tryParseTableSeparator("|   |   |"));
    // Letters mixed in
    try std.testing.expectEqual(null, tryParseTableSeparator("|--a--|---|"));
    // Empty
    try std.testing.expectEqual(null, tryParseTableSeparator(""));
}
