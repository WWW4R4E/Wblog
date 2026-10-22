const std = @import("std");
const ast = @import("ast.zig");
const entities = @import("entities.zig");
const case_fold = @import("case_fold.zig");
const Node = ast.Node;
const Tag = ast.Tag;
const Data = ast.Data;
const Document = ast.Document;
const SourceSpan = ast.SourceSpan;

/// Parse inline content and append child nodes to parent.
pub fn parseInlines(doc: *Document, parent: *Node, input: []const u8) !void {
    if (input.len == 0) return;

    const arena = doc.arena.allocator();
    var delimiters: std.ArrayListUnmanaged(Delimiter) = .empty;
    var brackets: std.ArrayListUnmanaged(Bracket) = .empty;
    try delimiters.ensureTotalCapacity(arena, @min(input.len / 16, 256));
    try brackets.ensureTotalCapacity(arena, 16);

    var parser = InlineParser{
        .doc = doc,
        .arena = arena,
        .input = input,
        .pos = 0,
        .parent = parent,
        .delimiters = delimiters,
        .brackets = brackets,
    };

    try parser.scan();
}

const Delimiter = struct {
    text_node: *Node,
    count: usize,
    original_count: usize,
    char: u8, // '*' or '_'
    can_open: bool,
    can_close: bool,
    active: bool,
};

const Bracket = struct {
    text_node: *Node,
    delimiter_bottom: usize,
    is_image: bool,
    active: bool,
    input_pos: usize, // position after the [ or ![ in the input
};

const InlineParser = struct {
    doc: *Document,
    arena: std.mem.Allocator,
    input: []const u8,
    pos: usize,
    parent: *Node,
    delimiters: std.ArrayListUnmanaged(Delimiter),
    brackets: std.ArrayListUnmanaged(Bracket),
    /// Backtick exhaustion cache: if backtick_max[n] > 0, no closing backtick
    /// sequence of length n+1 exists at or after that position in the input.
    backtick_max: [63]usize = @splat(0),

    const special_chars = [_]u8{ '`', '\\', '\n', '*', '_', '[', ']', '!', '<', '&', '{', '#' };

    fn scan(self: *InlineParser) !void {
        var text_start: usize = 0;

        while (self.pos < self.input.len) {
            // Skip plain text in bulk using SIMD-accelerated search
            if (std.mem.indexOfAnyPos(u8, self.input, self.pos, &special_chars)) |special_pos| {
                self.pos = special_pos;
            } else {
                self.pos = self.input.len;
                break;
            }

            const c = self.input[self.pos];
            switch (c) {
                '`' => {
                    if (self.pos > text_start) try self.flushText(text_start);
                    try self.handleBackticks();
                    text_start = self.pos;
                },
                '\\' => {
                    if (self.pos > text_start) try self.flushText(text_start);
                    try self.handleBackslash();
                    text_start = self.pos;
                },
                '\n' => {
                    if (self.pos > text_start) try self.flushText(text_start);
                    try self.handleNewline();
                    text_start = self.pos;
                },
                '*', '_' => {
                    if (self.pos > text_start) try self.flushText(text_start);
                    try self.handleDelimiterChar();
                    text_start = self.pos;
                },
                '[' => {
                    if (self.doc.extensions.obsidian and
                        self.pos + 1 < self.input.len and self.input[self.pos + 1] == '[')
                    {
                        if (self.pos > text_start) try self.flushText(text_start);
                        if (try self.tryWikiLink()) {
                            text_start = self.pos;
                        } else {
                            try self.handleOpenBracket();
                            text_start = self.pos;
                        }
                    } else {
                        if (self.pos > text_start) try self.flushText(text_start);
                        try self.handleOpenBracket();
                        text_start = self.pos;
                    }
                },
                '!' => {
                    if (self.pos + 1 < self.input.len and self.input[self.pos + 1] == '[') {
                        if (self.pos > text_start) try self.flushText(text_start);
                        try self.handleBang();
                        text_start = self.pos;
                    } else {
                        self.pos += 1;
                    }
                },
                ']' => {
                    if (self.pos > text_start) try self.flushText(text_start);
                    try self.handleCloseBracket();
                    text_start = self.pos;
                },
                '<' => {
                    if (self.pos > text_start) try self.flushText(text_start);
                    try self.handleLessThan();
                    text_start = self.pos;
                },
                '&' => {
                    if (self.pos > text_start) try self.flushText(text_start);
                    try self.handleAmpersand();
                    text_start = self.pos;
                },
                '{' => {
                    if (self.doc.extensions.critic_markup and try self.tryCriticMarkup(&text_start)) {
                        // handled — text_start updated
                    } else {
                        self.pos += 1;
                    }
                },
                '#' => {
                    if (self.doc.extensions.obsidian) {
                        if (self.pos > text_start) try self.flushText(text_start);
                        if (try self.tryObsidianTag()) {
                            text_start = self.pos;
                        } else {
                            text_start = self.pos;
                            self.pos += 1;
                        }
                    } else {
                        self.pos += 1;
                    }
                },
                else => {
                    self.pos += 1;
                },
            }
        }

        // Flush remaining text
        if (self.pos > text_start) {
            try self.flushText(text_start);
        }

        // Process remaining emphasis delimiters
        try self.processEmphasis(0);

        // Merge adjacent text nodes
        try self.mergeAdjacentText();
    }

    fn mergeAdjacentText(self: *InlineParser) !void {
        var node = self.parent.first_child;
        while (node) |n| {
            if (n.tag == .text and n.next != null and n.next.?.tag == .text) {
                const a = self.doc.nodeText(n);
                const b = self.doc.nodeText(n.next.?);
                // Check if the two text slices are contiguous in memory
                if (a.ptr + a.len == b.ptr) {
                    // Zero-alloc merge: extend the first slice
                    n.data = .{ .literal = a.ptr[0 .. a.len + b.len] };
                } else {
                    // Non-contiguous: allocate and copy
                    const buf = try self.arena.alloc(u8, a.len + b.len);
                    @memcpy(buf[0..a.len], a);
                    @memcpy(buf[a.len..], b);
                    n.data = .{ .literal = buf };
                }
                const to_remove = n.next.?;
                to_remove.detach();
                // Don't advance — check if next is also text
            } else {
                node = n.next;
            }
        }
    }

    fn flushText(self: *InlineParser, start: usize) !void {
        const text = self.input[start..self.pos];
        if (text.len == 0) return;
        const node = try self.makeTextNode(text);
        self.parent.appendChild(node);
    }

    fn makeTextNode(self: *InlineParser, text: []const u8) !*Node {
        return self.doc.createNode(.text, .{ .literal = text }, SourceSpan.empty);
    }

    // ── Code spans ────────────────────────────────────────────────────

    fn handleBackticks(self: *InlineParser) !void {
        // Count opening backticks
        const start = self.pos;
        while (self.pos < self.input.len and self.input[self.pos] == '`') {
            self.pos += 1;
        }
        const open_len = self.pos - start;

        // Check exhaustion cache: if we already know no match of this length
        // exists at or after this position, skip the scan entirely
        if (open_len <= self.backtick_max.len) {
            const cached = self.backtick_max[open_len - 1];
            if (cached > 0 and self.pos >= cached) {
                const node = try self.makeTextNode(self.input[start..self.pos]);
                self.parent.appendChild(node);
                return;
            }
        }

        // Scan for matching closing backtick string
        var search = self.pos;
        while (search < self.input.len) {
            if (self.input[search] == '`') {
                const close_start = search;
                while (search < self.input.len and self.input[search] == '`') {
                    search += 1;
                }
                const close_len = search - close_start;
                if (close_len == open_len) {
                    // Found matching close — extract content
                    var content = self.input[self.pos..close_start];

                    // Collapse internal newlines to spaces
                    var buf = try self.arena.alloc(u8, content.len);
                    for (content, 0..) |ch, i| {
                        buf[i] = if (ch == '\n') ' ' else ch;
                    }
                    content = buf;

                    // Strip one leading and one trailing space if both present
                    // and content is not all spaces
                    if (content.len >= 2 and content[0] == ' ' and content[content.len - 1] == ' ') {
                        const all_spaces = for (content) |ch| {
                            if (ch != ' ') break false;
                        } else true;
                        if (!all_spaces) {
                            content = content[1 .. content.len - 1];
                        }
                    }

                    const node = try self.doc.createNode(.code_span, .{ .literal = content }, SourceSpan.empty);
                    self.parent.appendChild(node);
                    self.pos = search;
                    return;
                }
            } else {
                search += 1;
            }
        }

        // No matching close found — cache this for future lookups
        if (open_len <= self.backtick_max.len) {
            self.backtick_max[open_len - 1] = self.pos;
        }

        // Emit opening backticks as text
        const node = try self.makeTextNode(self.input[start..self.pos]);
        self.parent.appendChild(node);
    }

    // ── Backslash escapes ─────────────────────────────────────────────

    fn handleBackslash(self: *InlineParser) !void {
        if (self.pos + 1 >= self.input.len) {
            // Backslash at end of input — emit as text
            const node = try self.makeTextNode("\\");
            self.parent.appendChild(node);
            self.pos += 1;
            return;
        }

        const next = self.input[self.pos + 1];
        if (next == '\n') {
            // Hard break
            const node = try self.doc.createNode(.hard_break, .{ .none = {} }, SourceSpan.empty);
            self.parent.appendChild(node);
            self.pos += 2;
            // Skip leading spaces on next line
            while (self.pos < self.input.len and self.input[self.pos] == ' ') {
                self.pos += 1;
            }
        } else if (isAsciiPunctuation(next)) {
            // Escaped character
            const node = try self.makeTextNode(self.input[self.pos + 1 .. self.pos + 2]);
            self.parent.appendChild(node);
            self.pos += 2;
        } else {
            // Not a valid escape — emit backslash as text
            const node = try self.makeTextNode("\\");
            self.parent.appendChild(node);
            self.pos += 1;
        }
    }

    // ── Line breaks ───────────────────────────────────────────────────

    fn handleNewline(self: *InlineParser) !void {
        // Check for hard break: 2+ trailing spaces before newline
        var hard = false;
        if (self.parent.last_child) |last| {
            if (last.tag == .text) {
                const text = switch (last.data) {
                    .literal => |s| s,
                    else => "",
                };
                if (text.len >= 2 and text[text.len - 1] == ' ' and text[text.len - 2] == ' ') {
                    hard = true;
                }
                // Trim trailing spaces from the text node (both hard and soft breaks)
                if (text.len > 0 and text[text.len - 1] == ' ') {
                    var end = text.len;
                    while (end > 0 and text[end - 1] == ' ') {
                        end -= 1;
                    }
                    last.data = .{ .literal = text[0..end] };
                }
            }
        }

        if (hard) {
            const node = try self.doc.createNode(.hard_break, .{ .none = {} }, SourceSpan.empty);
            self.parent.appendChild(node);
        } else {
            const node = try self.doc.createNode(.soft_break, .{ .none = {} }, SourceSpan.empty);
            self.parent.appendChild(node);
        }

        self.pos += 1;
        // Skip leading spaces on next line
        while (self.pos < self.input.len and self.input[self.pos] == ' ') {
            self.pos += 1;
        }
    }

    // ── Emphasis delimiters ───────────────────────────────────────────

    fn handleDelimiterChar(self: *InlineParser) !void {
        const char = self.input[self.pos];
        const run_start = self.pos;

        // Count run length
        while (self.pos < self.input.len and self.input[self.pos] == char) {
            self.pos += 1;
        }
        const run_len = self.pos - run_start;

        // Classify flanking using Unicode codepoints
        const before_cp = codepointBefore(self.input, run_start);
        const after_cp = codepointAfter(self.input, self.pos);

        const before_ws = isUnicodeWhitespaceCp(before_cp);
        const after_ws = isUnicodeWhitespaceCp(after_cp);
        const before_punct = isUnicodePunctuationCp(before_cp);
        const after_punct = isUnicodePunctuationCp(after_cp);

        const left_flanking = !after_ws and (!after_punct or before_ws or before_punct);
        const right_flanking = !before_ws and (!before_punct or after_ws or after_punct);

        var can_open: bool = undefined;
        var can_close: bool = undefined;

        if (char == '*') {
            can_open = left_flanking;
            can_close = right_flanking;
        } else {
            // underscore
            can_open = left_flanking and (!right_flanking or before_punct);
            can_close = right_flanking and (!left_flanking or after_punct);
        }

        // Create text node for the delimiter characters
        const text = self.input[run_start..self.pos];
        const node = try self.makeTextNode(text);
        self.parent.appendChild(node);

        // Push to delimiter stack if it can open or close
        if (can_open or can_close) {
            try self.delimiters.append(self.arena, .{
                .text_node = node,
                .count = run_len,
                .original_count = run_len,
                .char = char,
                .can_open = can_open,
                .can_close = can_close,
                .active = true,
            });
        }
    }

    // ── Emphasis processing ───────────────────────────────────────────

    fn processEmphasis(self: *InlineParser, stack_bottom: usize) !void {
        // openers_bottom[char_idx][original_count % 3]
        // char_idx: 0 = '*', 1 = '_'
        var openers_bottom = [2][3]usize{
            .{ stack_bottom, stack_bottom, stack_bottom },
            .{ stack_bottom, stack_bottom, stack_bottom },
        };

        var current: usize = stack_bottom;
        while (current < self.delimiters.items.len) {
            const closer = &self.delimiters.items[current];
            if (!closer.can_close or !closer.active) {
                current += 1;
                continue;
            }

            const char_idx: usize = if (closer.char == '*') 0 else 1;
            const bottom = openers_bottom[char_idx][closer.original_count % 3];

            // Search backward for opener
            var found_opener = false;
            var opener_idx: usize = current;
            while (opener_idx > bottom) {
                opener_idx -= 1;
                const opener = &self.delimiters.items[opener_idx];
                if (opener.char == closer.char and opener.can_open and opener.active) {
                    // Multiple of 3 rule
                    if ((opener.can_open and opener.can_close) or (closer.can_open and closer.can_close)) {
                        if ((opener.original_count + closer.original_count) % 3 == 0) {
                            if (opener.original_count % 3 != 0 or closer.original_count % 3 != 0) {
                                continue; // skip this opener
                            }
                        }
                    }
                    found_opener = true;
                    break;
                }
            }

            if (!found_opener) {
                openers_bottom[char_idx][closer.original_count % 3] = current;
                if (!closer.can_open) {
                    closer.active = false;
                }
                current += 1;
                continue;
            }

            const opener = &self.delimiters.items[opener_idx];

            // Determine emphasis or strong
            const use_count: usize = if (opener.count >= 2 and closer.count >= 2) 2 else 1;
            const tag: Tag = if (use_count == 2) .strong else .emphasis;

            const em_node = try self.doc.createNode(tag, .{ .none = {} }, SourceSpan.empty);

            // Move all nodes between opener.text_node and closer.text_node into em_node
            var node = opener.text_node.next;
            while (node != null and node != closer.text_node) {
                const next = node.?.next;
                node.?.detach();
                em_node.appendChild(node.?);
                node = next;
            }

            // Insert em_node after opener text node
            opener.text_node.insertAfter(em_node);

            // Trim opener
            opener.count -= use_count;
            if (opener.count == 0) {
                opener.text_node.detach();
                opener.active = false;
            } else {
                const lit = switch (opener.text_node.data) {
                    .literal => |s| s,
                    else => "",
                };
                opener.text_node.data = .{ .literal = lit[0..opener.count] };
            }

            // Trim closer
            closer.count -= use_count;
            if (closer.count == 0) {
                closer.text_node.detach();
                closer.active = false;
            } else {
                const lit = switch (closer.text_node.data) {
                    .literal => |s| s,
                    else => "",
                };
                closer.text_node.data = .{ .literal = lit[lit.len - closer.count ..] };
            }

            // Deactivate delimiters between opener and closer
            var i = opener_idx + 1;
            while (i < current) : (i += 1) {
                self.delimiters.items[i].active = false;
            }

            // If closer was fully consumed, move past it; otherwise re-process it
            if (closer.count == 0) {
                current += 1;
            }
            // If opener still has count, don't advance current (closer may match again)
        }

        // Clean up: deactivate all delimiters above stack_bottom
        for (self.delimiters.items[stack_bottom..]) |*d| {
            d.active = false;
        }
    }

    // ── Brackets (links/images) ───────────────────────────────────────

    fn handleOpenBracket(self: *InlineParser) !void {
        const node = try self.makeTextNode("[");
        self.parent.appendChild(node);

        self.pos += 1;
        try self.brackets.append(self.arena, .{
            .text_node = node,
            .delimiter_bottom = self.delimiters.items.len,
            .is_image = false,
            .active = true,
            .input_pos = self.pos,
        });
    }

    fn handleBang(self: *InlineParser) !void {
        const node = try self.makeTextNode("![");
        self.parent.appendChild(node);

        self.pos += 2;
        try self.brackets.append(self.arena, .{
            .text_node = node,
            .delimiter_bottom = self.delimiters.items.len,
            .is_image = true,
            .active = true,
            .input_pos = self.pos,
        });
    }

    fn handleCloseBracket(self: *InlineParser) !void {
        // Find most recent bracket (active or not) per CommonMark spec algorithm
        if (self.brackets.items.len == 0) {
            // No opener — emit ] as text
            const node = try self.makeTextNode("]");
            self.parent.appendChild(node);
            self.pos += 1;
            return;
        }

        const bracket_idx = self.brackets.items.len - 1;
        const bracket = self.brackets.items[bracket_idx];

        // If bracket is inactive (deactivated by link formation), remove and emit ]
        if (!bracket.active) {
            self.brackets.items.len = bracket_idx;
            const node = try self.makeTextNode("]");
            self.parent.appendChild(node);
            self.pos += 1;
            return;
        }

        self.pos += 1; // skip ]

        // Try inline link: (destination "title")
        var link_data: ?ast.LinkData = null;
        if (self.pos < self.input.len and self.input[self.pos] == '(') {
            link_data = try self.tryParseInlineLink();
        }

        // Try reference link
        if (link_data == null) {
            link_data = try self.tryParseRefLink(bracket);
        }

        if (link_data) |ld| {
            // Process emphasis within bracket scope
            try self.processEmphasis(bracket.delimiter_bottom);

            // Create link/image node
            const tag: Tag = if (bracket.is_image) .image else .link;
            const idx = try self.doc.storeLinkData(ld);
            const data: Data = if (bracket.is_image) .{ .image = idx } else .{ .link = idx };
            const link_node = try self.doc.createNode(tag, data, SourceSpan.empty);

            // Move nodes between bracket opener and current position into link
            var node = bracket.text_node.next;
            while (node != null) {
                const next = node.?.next;
                node.?.detach();
                link_node.appendChild(node.?);
                node = next;
            }

            // Replace bracket text node with link node
            bracket.text_node.insertAfter(link_node);
            bracket.text_node.detach();

            // For links (not images), deactivate all earlier [ openers
            if (!bracket.is_image) {
                for (self.brackets.items[0..bracket_idx]) |*b| {
                    if (!b.is_image) {
                        b.active = false;
                    }
                }
            }

            // Remove this bracket and all later ones from the stack
            self.brackets.items.len = bracket_idx;
        } else {
            // No match — remove bracket from stack, emit ] as text
            self.brackets.items.len = bracket_idx;
            const node = try self.makeTextNode("]");
            self.parent.appendChild(node);
        }
    }

    fn tryParseInlineLink(self: *InlineParser) !?ast.LinkData {
        if (self.pos >= self.input.len or self.input[self.pos] != '(') return null;
        var pos = self.pos + 1;

        // Skip whitespace
        pos = skipInlineWhitespace(self.input, pos);

        // Parse destination
        const dest = parseLinkDestination(self.input, pos) orelse return null;
        pos = dest.end;

        // Skip whitespace
        const ws_pos = pos;
        pos = skipInlineWhitespace(self.input, pos);

        // Optional title
        var title: []const u8 = "";
        if (pos < self.input.len and (self.input[pos] == '"' or self.input[pos] == '\'' or self.input[pos] == '(')) {
            if (parseLinkTitle(self.input, pos)) |t| {
                title = t.value;
                pos = t.end;
                pos = skipInlineWhitespace(self.input, pos);
            } else if (ws_pos == pos) {
                // No whitespace before non-title — invalid
                return null;
            }
        }

        // Expect )
        if (pos >= self.input.len or self.input[pos] != ')') return null;
        pos += 1;

        const destination = try processEscapes(self.arena, dest.value);
        const title_duped = if (title.len > 0) try processEscapes(self.arena, title) else @as([]const u8, "");

        self.pos = pos;
        return .{ .destination = destination, .title = title_duped };
    }

    fn tryParseRefLink(self: *InlineParser, bracket: Bracket) !?ast.LinkData {
        const saved_pos = self.pos;

        // Try full reference: [label]
        if (self.pos < self.input.len and self.input[self.pos] == '[') {
            const label_start = self.pos + 1;
            var p = label_start;
            while (p < self.input.len) {
                if (self.input[p] == '\\' and p + 1 < self.input.len) {
                    p += 2; // skip escaped char
                    continue;
                }
                if (self.input[p] == ']' or self.input[p] == '[') break;
                p += 1;
            }
            if (p < self.input.len and self.input[p] == ']') {
                const label = self.input[label_start..p];
                if (label.len > 0) {
                    const normalized = try normalizeLabel(self.arena, label);
                    if (self.doc.ref_map.get(normalized)) |ref| {
                        self.pos = p + 1;
                        return .{ .destination = ref.destination, .title = ref.title };
                    }
                }
            }
        }

        // Try collapsed reference: []
        if (self.pos + 1 < self.input.len and self.input[self.pos] == '[' and self.input[self.pos + 1] == ']') {
            const bracket_content = self.getBracketContent(bracket);
            const normalized = try normalizeLabel(self.arena, bracket_content);
            if (self.doc.ref_map.get(normalized)) |ref| {
                self.pos += 2;
                return .{ .destination = ref.destination, .title = ref.title };
            }
        }

        // Try shortcut reference (only when ] is NOT followed by [label])
        if (saved_pos >= self.input.len or self.input[saved_pos] != '[') {
            const bracket_content = self.getBracketContent(bracket);
            if (bracket_content.len > 0) {
                const normalized = try normalizeLabel(self.arena, bracket_content);
                if (self.doc.ref_map.get(normalized)) |ref| {
                    // Don't advance pos — shortcut doesn't consume anything after ]
                    return .{ .destination = ref.destination, .title = ref.title };
                }
            }
        }

        self.pos = saved_pos;
        return null;
    }

    /// Extract raw text content between bracket opener position and current position.
    /// Returns the raw input slice (not processed) for label matching.
    fn getBracketContent(self: *InlineParser, bracket: Bracket) []const u8 {
        // Use raw input text for label matching (backslash escapes preserved)
        // self.pos - 1 because we already advanced past the ] character
        const end = self.pos - 1;
        if (bracket.input_pos <= end) {
            return self.input[bracket.input_pos..end];
        }
        return "";
    }


    // ── Autolinks and HTML inline ─────────────────────────────────────

    fn handleAmpersand(self: *InlineParser) !void {
        if (tryParseEntityRef(self.input, self.pos)) |result| {
            // Entity values may reference temporary stack buffers (numeric refs),
            // so dupe into arena to ensure lifetime.
            const value = try self.arena.dupe(u8, result.value);
            const node = try self.makeTextNode(value);
            self.parent.appendChild(node);
            self.pos = result.end;
            return;
        }
        // Not a valid entity reference, emit the & as text
        const node = try self.makeTextNode("&");
        self.parent.appendChild(node);
        self.pos += 1;
    }

    fn handleLessThan(self: *InlineParser) !void {
        // Try URI autolink: <scheme:...>
        if (tryParseUriAutolink(self.input, self.pos)) |result| {
            const content = try self.arena.dupe(u8, result.value);
            const node = try self.doc.createNode(.autolink, .{ .literal = content }, SourceSpan.empty);
            self.parent.appendChild(node);
            self.pos = result.end;
            return;
        }

        // Try email autolink: <user@domain>
        if (tryParseEmailAutolink(self.input, self.pos)) |result| {
            const content = try self.arena.dupe(u8, result.value);
            const node = try self.doc.createNode(.autolink, .{ .literal = content }, SourceSpan.empty);
            self.parent.appendChild(node);
            self.pos = result.end;
            return;
        }

        // Try HTML inline tag
        if (tryParseHtmlInline(self.input, self.pos)) |result| {
            const content = try self.arena.dupe(u8, result.value);
            const node = try self.doc.createNode(.html_inline, .{ .literal = content }, SourceSpan.empty);
            self.parent.appendChild(node);
            self.pos = result.end;
            return;
        }

        // Not a special sequence — emit < as text
        const node = try self.makeTextNode("<");
        self.parent.appendChild(node);
        self.pos += 1;
    }

    // ── CriticMarkup ─────────────────────────────────────────────────

    /// Try to parse a CriticMarkup construct at current position.
    /// On success, flushes pending text, creates AST nodes, advances pos, updates text_start.
    fn tryCriticMarkup(self: *InlineParser, text_start: *usize) !bool {
        if (self.pos + 2 >= self.input.len) return false;

        const second = self.input[self.pos + 1];
        const third = self.input[self.pos + 2];

        const CritType = enum { insertion, deletion, substitution, comment, highlight };
        const crit_type: CritType = switch (second) {
            '+' => if (third == '+') .insertion else return false,
            '-' => if (third == '-') .deletion else return false,
            '~' => if (third == '~') .substitution else return false,
            '>' => if (third == '>') .comment else return false,
            '=' => if (third == '=') .highlight else return false,
            else => return false,
        };

        const close_delim: []const u8 = switch (crit_type) {
            .insertion => "++}",
            .deletion => "--}",
            .substitution => "~~}",
            .comment => "<<}",
            .highlight => "==}",
        };

        const content_start = self.pos + 3;

        // Scan for closing delimiter
        var search = content_start;
        while (search + close_delim.len <= self.input.len) {
            if (std.mem.startsWith(u8, self.input[search..], close_delim)) {
                // Found closing delimiter — flush pending text and create nodes
                if (self.pos > text_start.*) try self.flushText(text_start.*);
                const content = self.input[content_start..search];

                switch (crit_type) {
                    .insertion, .deletion, .highlight => {
                        const tag: Tag = switch (crit_type) {
                            .insertion => .critic_insertion,
                            .deletion => .critic_deletion,
                            .highlight => .critic_highlight,
                            else => unreachable,
                        };
                        const container = try self.doc.createNode(tag, .{ .none = {} }, SourceSpan.empty);
                        self.parent.appendChild(container);
                        if (content.len > 0) {
                            const text_node = try self.makeTextNode(content);
                            container.appendChild(text_node);
                        }
                    },
                    .comment => {
                        const node = try self.doc.createNode(.critic_comment, .{ .literal = content }, SourceSpan.empty);
                        self.parent.appendChild(node);
                    },
                    .substitution => {
                        if (std.mem.indexOf(u8, content, "~>")) |sep_pos| {
                            const old_text = content[0..sep_pos];
                            const new_text = content[sep_pos + 2 ..];
                            const sub = try self.doc.createNode(.critic_substitution, .{ .none = {} }, SourceSpan.empty);
                            self.parent.appendChild(sub);

                            const del = try self.doc.createNode(.critic_deletion, .{ .none = {} }, SourceSpan.empty);
                            sub.appendChild(del);
                            if (old_text.len > 0) {
                                del.appendChild(try self.makeTextNode(old_text));
                            }

                            const ins = try self.doc.createNode(.critic_insertion, .{ .none = {} }, SourceSpan.empty);
                            sub.appendChild(ins);
                            if (new_text.len > 0) {
                                ins.appendChild(try self.makeTextNode(new_text));
                            }
                        } else {
                            // No ~> separator — not valid substitution
                            return false;
                        }
                    },
                }

                self.pos = search + close_delim.len;
                text_start.* = self.pos;
                return true;
            }
            search += 1;
        }

        return false; // no closing delimiter
    }

    // ── Obsidian wiki links ────────────────────────────────────────

    /// Try to parse [[target]] or [[target|display]] at current position.
    /// self.pos must be at the first [.
    fn tryWikiLink(self: *InlineParser) !bool {
        if (self.pos + 1 >= self.input.len) return false;
        if (self.input[self.pos] != '[' or self.input[self.pos + 1] != '[') return false;

        const content_start = self.pos + 2;
        var search = content_start;
        var pipe_pos: ?usize = null;

        while (search + 1 < self.input.len) {
            if (self.input[search] == ']' and self.input[search + 1] == ']') {
                // Found closing ]]
                const target_end = pipe_pos orelse search;
                const target = self.input[content_start..target_end];
                if (target.len == 0) return false;

                const has_display = pipe_pos != null;
                const wl_idx = try self.doc.storeWikiLinkData(.{
                    .target = target,
                    .has_display = has_display,
                });
                const node = try self.doc.createNode(.wiki_link, .{ .wiki_link = wl_idx }, SourceSpan.empty);
                self.parent.appendChild(node);

                if (pipe_pos) |pp| {
                    const display = self.input[pp + 1 .. search];
                    if (display.len > 0) {
                        node.appendChild(try self.makeTextNode(display));
                    }
                } else {
                    node.appendChild(try self.makeTextNode(target));
                }

                self.pos = search + 2;
                return true;
            }
            if (self.input[search] == '|' and pipe_pos == null) {
                pipe_pos = search;
            }
            if (self.input[search] == '\n') return false; // wiki links don't span lines
            search += 1;
        }

        return false;
    }

    // ── Obsidian tags ────────────────────────────────────────────────

    /// Try to parse #tag at current position. pos must be at #.
    fn tryObsidianTag(self: *InlineParser) !bool {
        if (self.pos >= self.input.len or self.input[self.pos] != '#') return false;

        // Word boundary before #: must be start of input, or preceded by whitespace/punctuation
        if (self.pos > 0) {
            const before = self.input[self.pos - 1];
            if (!isUnicodeWhitespace(before) and !isAsciiPunctuation(before)) return false;
        }

        const tag_start = self.pos + 1;
        if (tag_start >= self.input.len) return false;

        // Must start with a letter or _
        const first = self.input[tag_start];
        if (!isAlpha(first) and first != '_') return false;

        var tag_end = tag_start + 1;
        while (tag_end < self.input.len) {
            const ch = self.input[tag_end];
            if (isAlphaNum(ch) or ch == '-' or ch == '_' or ch == '/') {
                tag_end += 1;
            } else {
                break;
            }
        }

        // Must not end with / or -
        if (self.input[tag_end - 1] == '/' or self.input[tag_end - 1] == '-') return false;

        const tag_text = self.input[self.pos..tag_end]; // includes the #
        const node = try self.doc.createNode(.obsidian_tag, .{ .literal = tag_text }, SourceSpan.empty);
        self.parent.appendChild(node);
        self.pos = tag_end;
        return true;
    }
};

fn isAlpha(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

fn isAlphaNum(c: u8) bool {
    return isAlpha(c) or (c >= '0' and c <= '9');
}

// ── Character classification ──────────────────────────────────────────

fn isAsciiPunctuation(c: u8) bool {
    return switch (c) {
        '!', '"', '#', '$', '%', '&', '\'', '(', ')', '*', '+', ',', '-', '.', '/' => true,
        ':', ';', '<', '=', '>', '?', '@' => true,
        '[', '\\', ']', '^', '_', '`' => true,
        '{', '|', '}', '~' => true,
        else => false,
    };
}

fn isUnicodeWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0C;
}

fn isUnicodePunctuation(c: u8) bool {
    return isAsciiPunctuation(c);
}

/// Decode the Unicode codepoint before position `pos` in a UTF-8 string.
/// Returns ' ' (space) if at start of string.
fn codepointBefore(input: []const u8, pos: usize) u21 {
    if (pos == 0) return ' ';
    // Walk back over UTF-8 continuation bytes
    var i = pos - 1;
    while (i > 0 and (input[i] & 0xC0) == 0x80) : (i -= 1) {}
    const len = std.unicode.utf8ByteSequenceLength(input[i]) catch return input[i];
    return std.unicode.utf8Decode(input[i..][0..len]) catch input[i];
}

/// Decode the Unicode codepoint at position `pos` in a UTF-8 string.
/// Returns ' ' (space) if at end of string.
fn codepointAfter(input: []const u8, pos: usize) u21 {
    if (pos >= input.len) return ' ';
    const len = std.unicode.utf8ByteSequenceLength(input[pos]) catch return input[pos];
    if (pos + len > input.len) return input[pos];
    return std.unicode.utf8Decode(input[pos..][0..len]) catch input[pos];
}

/// Check if a Unicode codepoint is whitespace (Zs category + ASCII whitespace).
fn isUnicodeWhitespaceCp(cp: u21) bool {
    if (cp <= 0x7F) return isUnicodeWhitespace(@intCast(cp));
    return switch (cp) {
        0x00A0, // non-breaking space
        0x1680, // ogham space mark
        0x2000...0x200A, // various spaces (en quad through hair space)
        0x202F, // narrow no-break space
        0x205F, // medium mathematical space
        0x3000, // ideographic space
        => true,
        else => false,
    };
}

/// Check if a Unicode codepoint is punctuation (P* + S* categories + ASCII punct).
fn isUnicodePunctuationCp(cp: u21) bool {
    if (cp <= 0x7F) return isAsciiPunctuation(@intCast(cp));
    // General categories: Pc, Pd, Pe, Pf, Pi, Po, Ps, Sc, Sk, Sm, So
    return switch (cp) {
        // Common Unicode punctuation ranges
        0x00A1...0x00BF, // inverted !, cent, pound, currency, yen, etc.
        0x00D7, // multiplication sign
        0x00F7, // division sign
        0x2010...0x2027, // dashes, quotation marks, bullets, leaders
        0x2030...0x203E, // per mille, prime, guillemets, overline
        0x2041...0x2053, // various punctuation
        0x2055...0x205E, // various punctuation
        0x2190...0x2BFF, // arrows, math operators, misc symbols
        0x3001...0x3003, // CJK punctuation
        0x3008...0x3011, // CJK brackets
        0x3014...0x301F, // CJK brackets
        0xFE50...0xFE6F, // small form variants
        0xFF01...0xFF0F, // fullwidth punctuation
        0xFF1A...0xFF20, // fullwidth punctuation
        0xFF3B...0xFF40, // fullwidth brackets
        0xFF5B...0xFF65, // fullwidth brackets
        0x20A0...0x20CF, // currency symbols
        => true,
        else => false,
    };
}

fn isAsciiAlpha(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

fn isAsciiAlphaNum(c: u8) bool {
    return isAsciiAlpha(c) or (c >= '0' and c <= '9');
}

// ── Shared inline parsing utilities ───────────────────────────────────

fn skipInlineWhitespace(text: []const u8, start: usize) usize {
    var pos = start;
    while (pos < text.len and (text[pos] == ' ' or text[pos] == '\t' or text[pos] == '\n')) : (pos += 1) {}
    return pos;
}

/// Try to parse an entity or numeric character reference at the given position.
/// Returns the decoded UTF-8 value and the end position (past the ';').
pub fn tryParseEntityRef(text: []const u8, pos: usize) ?LinkPart {
    if (pos >= text.len or text[pos] != '&') return null;
    const after_amp = pos + 1;
    if (after_amp >= text.len) return null;

    if (text[after_amp] == '#') {
        // Numeric character reference
        const after_hash = after_amp + 1;
        if (after_hash >= text.len) return null;

        if (text[after_hash] == 'x' or text[after_hash] == 'X') {
            // Hex: &#xHHHH; or &#XHHHH;
            var p = after_hash + 1;
            const digit_start = p;
            while (p < text.len and p - digit_start < 8) : (p += 1) {
                if (!std.ascii.isHex(text[p])) break;
            }
            if (p == digit_start or p >= text.len or text[p] != ';') return null;
            const codepoint = std.fmt.parseInt(u21, text[digit_start..p], 16) catch return null;
            const result = entities.decodeNumericRefLen(codepoint);
            return .{ .value = result.bytes[0..result.len], .end = p + 1 };
        } else {
            // Decimal: &#DDDD;
            var p = after_hash;
            const digit_start = p;
            while (p < text.len and p - digit_start < 8) : (p += 1) {
                if (!std.ascii.isDigit(text[p])) break;
            }
            if (p == digit_start or p >= text.len or text[p] != ';') return null;
            const codepoint = std.fmt.parseInt(u21, text[digit_start..p], 10) catch return null;
            const result = entities.decodeNumericRefLen(codepoint);
            return .{ .value = result.bytes[0..result.len], .end = p + 1 };
        }
    } else {
        // Named entity reference: &name;
        var p = after_amp;
        if (p >= text.len or !std.ascii.isAlphabetic(text[p])) return null;
        p += 1;
        while (p < text.len and (std.ascii.isAlphanumeric(text[p]) or text[p] == ';')) {
            if (text[p] == ';') {
                const name = text[after_amp..p];
                if (entities.lookup(name)) |value| {
                    return .{ .value = value, .end = p + 1 };
                }
                return null;
            }
            p += 1;
        }
        return null;
    }
}

const LinkPart = struct {
    value: []const u8,
    end: usize,
};

fn parseLinkDestination(text: []const u8, pos: usize) ?LinkPart {
    if (pos >= text.len) return null;

    if (text[pos] == '<') {
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
        var p = pos;
        var paren_depth: usize = 0;
        while (p < text.len) {
            if (text[p] == '\\' and p + 1 < text.len) {
                p += 2;
                continue;
            }
            if (text[p] <= ' ') break;
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
        if (open == '(' and text[p] == '(') return null;
        p += 1;
    }
    return null;
}

/// Process backslash escapes and entity references in link destinations/titles.
fn processEscapes(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    // Quick check: if no backslash or ampersand, return as-is
    if (std.mem.indexOfScalar(u8, text, '\\') == null and
        std.mem.indexOfScalar(u8, text, '&') == null) return text;

    var result: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '\\' and i + 1 < text.len and isAsciiPunctuation(text[i + 1])) {
            try result.append(arena, text[i + 1]);
            i += 2;
        } else if (text[i] == '&') {
            if (tryParseEntityRef(text, i)) |ref| {
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

const normalizeLabel = case_fold.normalizeLabel;

// ── Autolink parsing ──────────────────────────────────────────────────

fn tryParseUriAutolink(text: []const u8, pos: usize) ?LinkPart {
    if (pos >= text.len or text[pos] != '<') return null;
    var p = pos + 1;

    // Scheme: [a-zA-Z][a-zA-Z0-9+.-]{1,31}:
    if (p >= text.len or !isAsciiAlpha(text[p])) return null;
    p += 1;
    const scheme_start = p;
    while (p < text.len and (isAsciiAlphaNum(text[p]) or text[p] == '+' or text[p] == '-' or text[p] == '.')) : (p += 1) {}
    if (p - scheme_start < 1 or p - scheme_start > 31) return null;
    if (p >= text.len or text[p] != ':') return null;
    p += 1;

    // URI chars until >
    while (p < text.len) {
        if (text[p] == '>') {
            return .{ .value = text[pos + 1 .. p], .end = p + 1 };
        }
        if (text[p] <= ' ') return null; // whitespace or control char
        p += 1;
    }
    return null;
}

fn tryParseEmailAutolink(text: []const u8, pos: usize) ?LinkPart {
    if (pos >= text.len or text[pos] != '<') return null;
    var p = pos + 1;

    // Local part
    const local_start = p;
    while (p < text.len and (isAsciiAlphaNum(text[p]) or
        text[p] == '.' or text[p] == '!' or text[p] == '#' or
        text[p] == '$' or text[p] == '%' or text[p] == '&' or
        text[p] == '\'' or text[p] == '*' or text[p] == '+' or
        text[p] == '/' or text[p] == '=' or text[p] == '?' or
        text[p] == '^' or text[p] == '_' or text[p] == '`' or
        text[p] == '{' or text[p] == '|' or text[p] == '}' or
        text[p] == '~' or text[p] == '-')) : (p += 1)
    {}
    if (p == local_start) return null;
    if (p >= text.len or text[p] != '@') return null;
    p += 1;

    // Domain
    const domain_start = p;
    var last_dot: ?usize = null;
    while (p < text.len and (isAsciiAlphaNum(text[p]) or text[p] == '-' or text[p] == '.')) {
        if (text[p] == '.') last_dot = p;
        p += 1;
    }
    if (p == domain_start) return null;
    if (last_dot == null) return null; // need at least one dot

    if (p >= text.len or text[p] != '>') return null;
    return .{ .value = text[pos + 1 .. p], .end = p + 1 };
}

// ── HTML inline parsing ───────────────────────────────────────────────

fn tryParseHtmlInline(text: []const u8, pos: usize) ?LinkPart {
    if (pos >= text.len or text[pos] != '<') return null;
    if (pos + 1 >= text.len) return null;

    // HTML comment: <!-- ... -->
    // Also accepts <!-->  and <!---> per HTML5 spec
    if (text.len > pos + 3 and text[pos + 1] == '!' and text[pos + 2] == '-' and text[pos + 3] == '-') {
        // <!-->  is a valid (empty) comment
        if (pos + 4 < text.len and text[pos + 4] == '>') {
            return .{ .value = text[pos .. pos + 5], .end = pos + 5 };
        }
        // <!---> is a valid comment
        if (pos + 5 < text.len and text[pos + 4] == '-' and text[pos + 5] == '>') {
            return .{ .value = text[pos .. pos + 6], .end = pos + 6 };
        }
        var p = pos + 4;
        while (p + 2 < text.len) {
            if (text[p] == '-' and text[p + 1] == '-' and text[p + 2] == '>') {
                return .{ .value = text[pos .. p + 3], .end = p + 3 };
            }
            p += 1;
        }
        return null;
    }

    // Processing instruction: <?...?>
    if (text[pos + 1] == '?') {
        var p = pos + 2;
        while (p + 1 < text.len) {
            if (text[p] == '?' and text[p + 1] == '>') {
                return .{ .value = text[pos .. p + 2], .end = p + 2 };
            }
            p += 1;
        }
        return null;
    }

    // CDATA: <![CDATA[...]]>
    if (text.len > pos + 8 and std.mem.eql(u8, text[pos + 1 .. pos + 9], "![CDATA[")) {
        var p = pos + 9;
        while (p + 2 < text.len) {
            if (text[p] == ']' and text[p + 1] == ']' and text[p + 2] == '>') {
                return .{ .value = text[pos .. p + 3], .end = p + 3 };
            }
            p += 1;
        }
        return null;
    }

    // Declaration: <!LETTER...>
    if (text[pos + 1] == '!' and pos + 2 < text.len and isAsciiAlpha(text[pos + 2])) {
        var p = pos + 3;
        while (p < text.len and text[p] != '>') : (p += 1) {}
        if (p < text.len and text[p] == '>') {
            return .{ .value = text[pos .. p + 1], .end = p + 1 };
        }
        return null;
    }

    // Closing tag: </tagname>
    if (text[pos + 1] == '/') {
        if (pos + 2 >= text.len or !isAsciiAlpha(text[pos + 2])) return null;
        var p = pos + 3;
        while (p < text.len and (isAsciiAlphaNum(text[p]) or text[p] == '-')) : (p += 1) {}
        while (p < text.len and (text[p] == ' ' or text[p] == '\t' or text[p] == '\n')) : (p += 1) {}
        if (p < text.len and text[p] == '>') {
            return .{ .value = text[pos .. p + 1], .end = p + 1 };
        }
        return null;
    }

    // Open tag: <tagname attrs> or <tagname attrs/>
    if (isAsciiAlpha(text[pos + 1])) {
        var p = pos + 2;
        while (p < text.len and (isAsciiAlphaNum(text[p]) or text[p] == '-')) : (p += 1) {}

        // Parse attributes (proper validation)
        while (p < text.len) {
            // Skip whitespace
            const ws_start = p;
            while (p < text.len and (text[p] == ' ' or text[p] == '\t' or text[p] == '\n')) : (p += 1) {}

            // Check for end of tag
            if (p < text.len and text[p] == '>') {
                return .{ .value = text[pos .. p + 1], .end = p + 1 };
            }
            if (p < text.len and text[p] == '/' and p + 1 < text.len and text[p + 1] == '>') {
                return .{ .value = text[pos .. p + 2], .end = p + 2 };
            }

            // Must have whitespace before attribute
            if (p == ws_start) return null;

            // Don't allow < inside tag
            if (p < text.len and text[p] == '<') return null;

            // Parse attribute name: [a-zA-Z_:][a-zA-Z0-9_.:-]*
            if (p >= text.len) return null;
            if (!isAsciiAlpha(text[p]) and text[p] != '_' and text[p] != ':') return null;
            p += 1;
            while (p < text.len and (isAsciiAlphaNum(text[p]) or text[p] == '_' or text[p] == '.' or text[p] == ':' or text[p] == '-')) : (p += 1) {}

            // Optional: attribute value
            // Skip whitespace around =
            const before_eq = p;
            while (p < text.len and (text[p] == ' ' or text[p] == '\t' or text[p] == '\n')) : (p += 1) {}
            if (p < text.len and text[p] == '=') {
                p += 1;
                while (p < text.len and (text[p] == ' ' or text[p] == '\t' or text[p] == '\n')) : (p += 1) {}
                if (p >= text.len) return null;
                if (text[p] == '"') {
                    // Double-quoted value
                    p += 1;
                    while (p < text.len and text[p] != '"') : (p += 1) {}
                    if (p >= text.len) return null;
                    p += 1;
                } else if (text[p] == '\'') {
                    // Single-quoted value
                    p += 1;
                    while (p < text.len and text[p] != '\'') : (p += 1) {}
                    if (p >= text.len) return null;
                    p += 1;
                } else {
                    // Unquoted value
                    if (text[p] == ' ' or text[p] == '"' or text[p] == '\'' or text[p] == '=' or text[p] == '<' or text[p] == '>' or text[p] == '`') return null;
                    while (p < text.len and text[p] != ' ' and text[p] != '\t' and text[p] != '\n' and text[p] != '"' and text[p] != '\'' and text[p] != '=' and text[p] != '<' and text[p] != '>' and text[p] != '`') : (p += 1) {}
                }
            } else {
                p = before_eq; // no =, just a boolean attribute
            }
        }
        return null;
    }

    return null;
}

// ── Tests ──────────────────────────────────────────────────────────────

fn testParseInline(input: []const u8) !Document {
    var doc = try Document.init(std.testing.allocator, input, .{});
    errdefer doc.deinit();
    const p = try doc.createNode(.paragraph, .{ .none = {} }, .{ .start = 0, .end = input.len });
    doc.root.appendChild(p);
    try parseInlines(&doc, p, input);
    return doc;
}

/// Helper: get first child of the paragraph node.
fn firstInline(doc: *Document) *Node {
    return doc.root.first_child.?.first_child.?;
}

test "inline: plain text" {
    var doc = try testParseInline("Hello, world!");
    defer doc.deinit();

    const text = firstInline(&doc);
    try std.testing.expectEqual(Tag.text, text.tag);
    try std.testing.expectEqualStrings("Hello, world!", doc.nodeText(text));
    try std.testing.expectEqual(null, text.next);
}

test "inline: empty input" {
    var doc = try Document.init(std.testing.allocator, "", .{});
    defer doc.deinit();
    const p = try doc.createNode(.paragraph, .{ .none = {} }, SourceSpan.empty);
    doc.root.appendChild(p);
    try parseInlines(&doc, p, "");
    try std.testing.expectEqual(null, p.first_child);
}

test "inline: code span" {
    var doc = try testParseInline("`code`");
    defer doc.deinit();

    const cs = firstInline(&doc);
    try std.testing.expectEqual(Tag.code_span, cs.tag);
    try std.testing.expectEqualStrings("code", doc.nodeText(cs));
}

test "inline: code span with surrounding text" {
    var doc = try testParseInline("before `code` after");
    defer doc.deinit();

    const before = firstInline(&doc);
    try std.testing.expectEqualStrings("before ", doc.nodeText(before));

    const cs = before.next.?;
    try std.testing.expectEqual(Tag.code_span, cs.tag);
    try std.testing.expectEqualStrings("code", doc.nodeText(cs));

    const after = cs.next.?;
    try std.testing.expectEqualStrings(" after", doc.nodeText(after));
}

test "inline: double-backtick code span" {
    var doc = try testParseInline("`` code `here` ``");
    defer doc.deinit();

    const cs = firstInline(&doc);
    try std.testing.expectEqual(Tag.code_span, cs.tag);
    try std.testing.expectEqualStrings("code `here`", doc.nodeText(cs));
}

test "inline: code span strips leading/trailing space" {
    var doc = try testParseInline("` code `");
    defer doc.deinit();

    const cs = firstInline(&doc);
    try std.testing.expectEqual(Tag.code_span, cs.tag);
    try std.testing.expectEqualStrings("code", doc.nodeText(cs));
}

test "inline: unmatched backticks remain as text" {
    var doc = try testParseInline("`unmatched");
    defer doc.deinit();

    const t1 = firstInline(&doc);
    try std.testing.expectEqual(Tag.text, t1.tag);
    try std.testing.expectEqualStrings("`unmatched", doc.nodeText(t1));
}

test "inline: backslash escape" {
    var doc = try testParseInline("\\*not emphasis\\*");
    defer doc.deinit();

    const t1 = firstInline(&doc);
    try std.testing.expectEqual(Tag.text, t1.tag);
    try std.testing.expectEqualStrings("*not emphasis*", doc.nodeText(t1));
}

test "inline: hard break via backslash" {
    var doc = try testParseInline("hello\\\nworld");
    defer doc.deinit();

    const t1 = firstInline(&doc);
    try std.testing.expectEqualStrings("hello", doc.nodeText(t1));

    const hb = t1.next.?;
    try std.testing.expectEqual(Tag.hard_break, hb.tag);

    const t2 = hb.next.?;
    try std.testing.expectEqualStrings("world", doc.nodeText(t2));
}

test "inline: hard break via trailing spaces" {
    var doc = try testParseInline("hello  \nworld");
    defer doc.deinit();

    const t1 = firstInline(&doc);
    try std.testing.expectEqualStrings("hello", doc.nodeText(t1));

    const hb = t1.next.?;
    try std.testing.expectEqual(Tag.hard_break, hb.tag);

    const t2 = hb.next.?;
    try std.testing.expectEqualStrings("world", doc.nodeText(t2));
}

test "inline: soft break" {
    var doc = try testParseInline("hello\nworld");
    defer doc.deinit();

    const t1 = firstInline(&doc);
    try std.testing.expectEqualStrings("hello", doc.nodeText(t1));

    const sb = t1.next.?;
    try std.testing.expectEqual(Tag.soft_break, sb.tag);

    const t2 = sb.next.?;
    try std.testing.expectEqualStrings("world", doc.nodeText(t2));
}

test "inline: emphasis with asterisks" {
    var doc = try testParseInline("*hello*");
    defer doc.deinit();

    const em = firstInline(&doc);
    try std.testing.expectEqual(Tag.emphasis, em.tag);
    const text = em.first_child.?;
    try std.testing.expectEqualStrings("hello", doc.nodeText(text));
}

test "inline: strong emphasis" {
    var doc = try testParseInline("**hello**");
    defer doc.deinit();

    const strong = firstInline(&doc);
    try std.testing.expectEqual(Tag.strong, strong.tag);
    const text = strong.first_child.?;
    try std.testing.expectEqualStrings("hello", doc.nodeText(text));
}

test "inline: underscore emphasis" {
    var doc = try testParseInline("_hello_");
    defer doc.deinit();

    const em = firstInline(&doc);
    try std.testing.expectEqual(Tag.emphasis, em.tag);
    const text = em.first_child.?;
    try std.testing.expectEqualStrings("hello", doc.nodeText(text));
}

test "inline: nested emphasis ***bold italic***" {
    var doc = try testParseInline("***hello***");
    defer doc.deinit();

    const em = firstInline(&doc);
    try std.testing.expectEqual(Tag.emphasis, em.tag);
    const strong = em.first_child.?;
    try std.testing.expectEqual(Tag.strong, strong.tag);
    const text = strong.first_child.?;
    try std.testing.expectEqualStrings("hello", doc.nodeText(text));
}

test "inline: intraword underscore no emphasis" {
    var doc = try testParseInline("foo_bar_baz");
    defer doc.deinit();

    // Should be a single text node (underscores are intraword, can't open/close)
    const text = firstInline(&doc);
    try std.testing.expectEqual(Tag.text, text.tag);
    try std.testing.expectEqualStrings("foo_bar_baz", doc.nodeText(text));
}

test "inline: intraword asterisk emphasis" {
    var doc = try testParseInline("foo*bar*baz");
    defer doc.deinit();

    const t1 = firstInline(&doc);
    try std.testing.expectEqualStrings("foo", doc.nodeText(t1));

    const em = t1.next.?;
    try std.testing.expectEqual(Tag.emphasis, em.tag);
    const text = em.first_child.?;
    try std.testing.expectEqualStrings("bar", doc.nodeText(text));

    const t2 = em.next.?;
    try std.testing.expectEqualStrings("baz", doc.nodeText(t2));
}

test "inline: unmatched delimiter remains as text" {
    var doc = try testParseInline("*hello");
    defer doc.deinit();

    const t1 = firstInline(&doc);
    try std.testing.expectEqual(Tag.text, t1.tag);
    try std.testing.expectEqualStrings("*hello", doc.nodeText(t1));
}

test "inline: URI autolink" {
    var doc = try testParseInline("<http://example.com>");
    defer doc.deinit();

    const al = firstInline(&doc);
    try std.testing.expectEqual(Tag.autolink, al.tag);
    try std.testing.expectEqualStrings("http://example.com", doc.nodeText(al));
}

test "inline: email autolink" {
    var doc = try testParseInline("<user@example.com>");
    defer doc.deinit();

    const al = firstInline(&doc);
    try std.testing.expectEqual(Tag.autolink, al.tag);
    try std.testing.expectEqualStrings("user@example.com", doc.nodeText(al));
}

test "inline: inline link" {
    var doc = try testParseInline("[text](/url)");
    defer doc.deinit();

    const link = firstInline(&doc);
    try std.testing.expectEqual(Tag.link, link.tag);
    const ld = doc.getLinkData(link.data.link);
    try std.testing.expectEqualStrings("/url", ld.destination);
    try std.testing.expectEqualStrings("", ld.title);

    const text = link.first_child.?;
    try std.testing.expectEqualStrings("text", doc.nodeText(text));
}

test "inline: inline link with title" {
    var doc = try testParseInline(
        \\[text](/url "title")
    );
    defer doc.deinit();

    const link = firstInline(&doc);
    try std.testing.expectEqual(Tag.link, link.tag);
    const ld = doc.getLinkData(link.data.link);
    try std.testing.expectEqualStrings("/url", ld.destination);
    try std.testing.expectEqualStrings("title", ld.title);
}

test "inline: image" {
    var doc = try testParseInline("![alt](/img.png)");
    defer doc.deinit();

    const img = firstInline(&doc);
    try std.testing.expectEqual(Tag.image, img.tag);
    try std.testing.expectEqualStrings("/img.png", doc.getLinkData(img.data.image).destination);

    const alt = img.first_child.?;
    try std.testing.expectEqualStrings("alt", doc.nodeText(alt));
}

test "inline: reference link (full)" {
    var doc = try Document.init(std.testing.allocator, "", .{});
    defer doc.deinit();
    const arena = doc.arena.allocator();

    // Pre-populate ref_map
    try doc.ref_map.put(arena, "ref", .{ .destination = "/url", .title = "" });

    const p = try doc.createNode(.paragraph, .{ .none = {} }, SourceSpan.empty);
    doc.root.appendChild(p);
    try parseInlines(&doc, p, "[text][ref]");

    const link = p.first_child.?;
    try std.testing.expectEqual(Tag.link, link.tag);
    try std.testing.expectEqualStrings("/url", doc.getLinkData(link.data.link).destination);
    const text = link.first_child.?;
    try std.testing.expectEqualStrings("text", doc.nodeText(text));
}

test "inline: reference link (shortcut)" {
    var doc = try Document.init(std.testing.allocator, "", .{});
    defer doc.deinit();
    const arena = doc.arena.allocator();

    try doc.ref_map.put(arena, "foo", .{ .destination = "/url", .title = "" });

    const p = try doc.createNode(.paragraph, .{ .none = {} }, SourceSpan.empty);
    doc.root.appendChild(p);
    try parseInlines(&doc, p, "[foo]");

    const link = p.first_child.?;
    try std.testing.expectEqual(Tag.link, link.tag);
    try std.testing.expectEqualStrings("/url", doc.getLinkData(link.data.link).destination);
}

test "inline: HTML inline tag" {
    var doc = try testParseInline("before <em> after");
    defer doc.deinit();

    const t1 = firstInline(&doc);
    try std.testing.expectEqualStrings("before ", doc.nodeText(t1));

    const html = t1.next.?;
    try std.testing.expectEqual(Tag.html_inline, html.tag);
    try std.testing.expectEqualStrings("<em>", doc.nodeText(html));

    const t2 = html.next.?;
    try std.testing.expectEqualStrings(" after", doc.nodeText(t2));
}

// ── Extension tests ───────────────────────────────────────────────────

fn testParseInlineExt(input: []const u8, extensions: ast.Extensions) !Document {
    var doc = try Document.init(std.testing.allocator, input, extensions);
    errdefer doc.deinit();
    const p = try doc.createNode(.paragraph, .{ .none = {} }, .{ .start = 0, .end = input.len });
    doc.root.appendChild(p);
    try parseInlines(&doc, p, input);
    return doc;
}

// CriticMarkup tests

test "critic: insertion" {
    var doc = try testParseInlineExt("before {++added++} after", .{ .critic_markup = true });
    defer doc.deinit();

    const t1 = firstInline(&doc);
    try std.testing.expectEqualStrings("before ", doc.nodeText(t1));

    const ins = t1.next.?;
    try std.testing.expectEqual(Tag.critic_insertion, ins.tag);
    try std.testing.expectEqualStrings("added", doc.nodeText(ins.first_child.?));

    const t2 = ins.next.?;
    try std.testing.expectEqualStrings(" after", doc.nodeText(t2));
}

test "critic: deletion" {
    var doc = try testParseInlineExt("{--removed--}", .{ .critic_markup = true });
    defer doc.deinit();

    const del = firstInline(&doc);
    try std.testing.expectEqual(Tag.critic_deletion, del.tag);
    try std.testing.expectEqualStrings("removed", doc.nodeText(del.first_child.?));
}

test "critic: highlight" {
    var doc = try testParseInlineExt("{==important==}", .{ .critic_markup = true });
    defer doc.deinit();

    const hl = firstInline(&doc);
    try std.testing.expectEqual(Tag.critic_highlight, hl.tag);
    try std.testing.expectEqualStrings("important", doc.nodeText(hl.first_child.?));
}

test "critic: comment" {
    var doc = try testParseInlineExt("{>>a note<<}", .{ .critic_markup = true });
    defer doc.deinit();

    const comment = firstInline(&doc);
    try std.testing.expectEqual(Tag.critic_comment, comment.tag);
    try std.testing.expectEqualStrings("a note", doc.nodeText(comment));
}

test "critic: substitution" {
    var doc = try testParseInlineExt("{~~old~>new~~}", .{ .critic_markup = true });
    defer doc.deinit();

    const sub = firstInline(&doc);
    try std.testing.expectEqual(Tag.critic_substitution, sub.tag);

    const del = sub.first_child.?;
    try std.testing.expectEqual(Tag.critic_deletion, del.tag);
    try std.testing.expectEqualStrings("old", doc.nodeText(del.first_child.?));

    const ins = del.next.?;
    try std.testing.expectEqual(Tag.critic_insertion, ins.tag);
    try std.testing.expectEqualStrings("new", doc.nodeText(ins.first_child.?));
}

test "critic: substitution without ~> is not valid" {
    var doc = try testParseInlineExt("{~~nosep~~}", .{ .critic_markup = true });
    defer doc.deinit();

    // Should be plain text, not a substitution
    const t = firstInline(&doc);
    try std.testing.expectEqual(Tag.text, t.tag);
}

test "critic: unmatched delimiter is plain text" {
    var doc = try testParseInlineExt("{++no close", .{ .critic_markup = true });
    defer doc.deinit();

    const t = firstInline(&doc);
    try std.testing.expectEqual(Tag.text, t.tag);
    try std.testing.expectEqualStrings("{++no close", doc.nodeText(t));
}

test "critic: extensions off — plain text" {
    var doc = try testParseInline("{++added++}");
    defer doc.deinit();

    const t = firstInline(&doc);
    try std.testing.expectEqual(Tag.text, t.tag);
}

test "critic: multiple on same line" {
    var doc = try testParseInlineExt("{++a++} and {--b--}", .{ .critic_markup = true });
    defer doc.deinit();

    const ins = firstInline(&doc);
    try std.testing.expectEqual(Tag.critic_insertion, ins.tag);

    const mid = ins.next.?;
    try std.testing.expectEqualStrings(" and ", doc.nodeText(mid));

    const del = mid.next.?;
    try std.testing.expectEqual(Tag.critic_deletion, del.tag);
}

test "critic: empty content" {
    var doc = try testParseInlineExt("{++++}", .{ .critic_markup = true });
    defer doc.deinit();

    const ins = firstInline(&doc);
    try std.testing.expectEqual(Tag.critic_insertion, ins.tag);
    try std.testing.expectEqual(null, ins.first_child);
}

// Wiki link tests

test "wikilink: basic" {
    var doc = try testParseInlineExt("see [[page]]", .{ .obsidian = true });
    defer doc.deinit();

    const t1 = firstInline(&doc);
    try std.testing.expectEqualStrings("see ", doc.nodeText(t1));

    const wl = t1.next.?;
    try std.testing.expectEqual(Tag.wiki_link, wl.tag);
    const wld = doc.getWikiLinkData(wl.data.wiki_link);
    try std.testing.expectEqualStrings("page", wld.target);
    try std.testing.expect(!wld.has_display);
    try std.testing.expectEqualStrings("page", doc.nodeText(wl.first_child.?));
}

test "wikilink: with display text" {
    var doc = try testParseInlineExt("[[page|shown text]]", .{ .obsidian = true });
    defer doc.deinit();

    const wl = firstInline(&doc);
    try std.testing.expectEqual(Tag.wiki_link, wl.tag);
    const wld = doc.getWikiLinkData(wl.data.wiki_link);
    try std.testing.expectEqualStrings("page", wld.target);
    try std.testing.expect(wld.has_display);
    try std.testing.expectEqualStrings("shown text", doc.nodeText(wl.first_child.?));
}

test "wikilink: empty target is not valid" {
    var doc = try testParseInlineExt("[[]]", .{ .obsidian = true });
    defer doc.deinit();

    // Should fall through to normal bracket handling, not be a wiki link
    const first = firstInline(&doc);
    try std.testing.expect(first.tag != .wiki_link);
}

test "wikilink: unclosed is not valid" {
    var doc = try testParseInlineExt("[[unclosed", .{ .obsidian = true });
    defer doc.deinit();

    const first = firstInline(&doc);
    try std.testing.expect(first.tag != .wiki_link);
}

test "wikilink: extensions off — normal brackets" {
    var doc = try testParseInline("[[page]]");
    defer doc.deinit();

    const first = firstInline(&doc);
    try std.testing.expect(first.tag != .wiki_link);
}

// Obsidian tag tests

test "obsidian tag: basic" {
    var doc = try testParseInlineExt("hello #tag world", .{ .obsidian = true });
    defer doc.deinit();

    const t1 = firstInline(&doc);
    try std.testing.expectEqualStrings("hello ", doc.nodeText(t1));

    const tag = t1.next.?;
    try std.testing.expectEqual(Tag.obsidian_tag, tag.tag);
    try std.testing.expectEqualStrings("#tag", doc.nodeText(tag));

    const t2 = tag.next.?;
    try std.testing.expectEqualStrings(" world", doc.nodeText(t2));
}

test "obsidian tag: with path separator" {
    var doc = try testParseInlineExt("#project/subtag", .{ .obsidian = true });
    defer doc.deinit();

    const tag = firstInline(&doc);
    try std.testing.expectEqual(Tag.obsidian_tag, tag.tag);
    try std.testing.expectEqualStrings("#project/subtag", doc.nodeText(tag));
}

test "obsidian tag: at start of input" {
    var doc = try testParseInlineExt("#first rest", .{ .obsidian = true });
    defer doc.deinit();

    const tag = firstInline(&doc);
    try std.testing.expectEqual(Tag.obsidian_tag, tag.tag);
    try std.testing.expectEqualStrings("#first", doc.nodeText(tag));
}

test "obsidian tag: not at word boundary" {
    var doc = try testParseInlineExt("foo#bar", .{ .obsidian = true });
    defer doc.deinit();

    // #bar is not a tag because foo precedes it without whitespace/punctuation
    const t = firstInline(&doc);
    try std.testing.expectEqual(Tag.text, t.tag);
    try std.testing.expectEqualStrings("foo#bar", doc.nodeText(t));
}

test "obsidian tag: after punctuation" {
    var doc = try testParseInlineExt("(#tag)", .{ .obsidian = true });
    defer doc.deinit();

    const t1 = firstInline(&doc);
    try std.testing.expectEqualStrings("(", doc.nodeText(t1));

    const tag = t1.next.?;
    try std.testing.expectEqual(Tag.obsidian_tag, tag.tag);
    try std.testing.expectEqualStrings("#tag", doc.nodeText(tag));
}

test "obsidian tag: # alone is not a tag" {
    var doc = try testParseInlineExt("# heading", .{ .obsidian = true });
    defer doc.deinit();

    // # followed by space — not a valid tag (must start with letter/_)
    const t = firstInline(&doc);
    try std.testing.expectEqual(Tag.text, t.tag);
}

test "obsidian tag: extensions off — plain text" {
    var doc = try testParseInline("hello #tag world");
    defer doc.deinit();

    const t = firstInline(&doc);
    try std.testing.expectEqual(Tag.text, t.tag);
    try std.testing.expectEqualStrings("hello #tag world", doc.nodeText(t));
}
