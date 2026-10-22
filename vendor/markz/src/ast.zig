const std = @import("std");

/// Source location in the original markdown input.
pub const SourceSpan = struct {
    start: usize,
    end: usize,

    pub const empty: SourceSpan = .{ .start = 0, .end = 0 };

    pub fn len(self: SourceSpan) usize {
        return self.end - self.start;
    }

    pub fn slice(self: SourceSpan, source: []const u8) []const u8 {
        return source[self.start..self.end];
    }
};

/// Precomputed line start offsets for O(log n) byte-offset-to-line lookup.
pub const LineIndex = struct {
    /// Byte offset of the start of each line (line_starts[0] == 0 always).
    line_starts: []const usize,

    pub fn build(allocator: std.mem.Allocator, source: []const u8) !LineIndex {
        var starts: std.ArrayListUnmanaged(usize) = .empty;
        try starts.append(allocator, 0);
        for (source, 0..) |c, i| {
            if (c == '\n' and i + 1 <= source.len) {
                try starts.append(allocator, i + 1);
            }
        }
        return .{ .line_starts = try starts.toOwnedSlice(allocator) };
    }

    /// Return 0-based line number for a byte offset.
    pub fn lineAt(self: LineIndex, offset: usize) usize {
        // Binary search: find the last line_start <= offset
        var lo: usize = 0;
        var hi: usize = self.line_starts.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.line_starts[mid] <= offset) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        return lo - 1;
    }

    /// Return 0-based column (byte offset within line) for a byte offset.
    pub fn colAt(self: LineIndex, offset: usize) usize {
        const line = self.lineAt(offset);
        return offset - self.line_starts[line];
    }

    /// Return line and column as a struct.
    pub fn lineCol(self: LineIndex, offset: usize) struct { line: usize, col: usize } {
        const line = self.lineAt(offset);
        return .{ .line = line, .col = offset - self.line_starts[line] };
    }

    pub fn lineCount(self: LineIndex) usize {
        return self.line_starts.len;
    }
};

/// Toggleable markdown extensions. Each flag enables parsing/serialization
/// of the corresponding syntax. Default: all off (pure CommonMark).
pub const Extensions = struct {
    critic_markup: bool = false,
    obsidian: bool = false,
    gfm: bool = false,
};

/// Node type tag.
pub const Tag = enum {
    // Block-level
    document,
    block_quote,
    list,
    list_item,
    heading,
    code_block,
    html_block,
    paragraph,
    thematic_break,

    // Inline
    text,
    emphasis,
    strong,
    code_span,
    link,
    image,
    autolink,
    html_inline,
    soft_break,
    hard_break,

    // CriticMarkup (inline)
    critic_insertion, // {++text++} — container with inline children
    critic_deletion, // {--text--} — container with inline children
    critic_substitution, // {~~old~>new~~} — container: [critic_deletion, critic_insertion]
    critic_comment, // {>>text<<} — leaf, data = .literal
    critic_highlight, // {==text==} — container with inline children

    // GFM
    table, // container: [table_head, table_body]
    table_head, // container: [table_row]
    table_body, // container: [table_row...]
    table_row, // container: [table_cell...]
    table_cell, // container with inline children, data = .table_cell

    // Obsidian
    wiki_link, // [[target]] or [[target|display]] — container, data = .wiki_link
    obsidian_tag, // #tag — leaf, data = .literal
    frontmatter, // YAML frontmatter block — leaf, data = .content

    pub fn isBlock(self: Tag) bool {
        return switch (self) {
            .document, .block_quote, .list, .list_item, .heading, .code_block, .html_block, .paragraph, .thematic_break, .frontmatter, .table, .table_head, .table_body, .table_row, .table_cell => true,
            else => false,
        };
    }

    pub fn isInline(self: Tag) bool {
        return !self.isBlock();
    }

    /// Can this node have children? Block containers (document, blockquote, list, list_item)
    /// hold block children. Leaf blocks with inlines (heading, paragraph) hold inline children.
    /// Inline containers (emphasis, strong, link, image) hold inline children.
    pub fn isContainer(self: Tag) bool {
        return switch (self) {
            .document, .block_quote, .list, .list_item, .heading, .paragraph, .emphasis, .strong, .link, .image,
            .critic_insertion, .critic_deletion, .critic_highlight, .critic_substitution, .wiki_link,
            .table, .table_head, .table_body, .table_row, .table_cell,
            => true,
            else => false,
        };
    }

    pub fn isLeaf(self: Tag) bool {
        return !self.isContainer();
    }
};

pub const HeadingData = struct {
    level: u3, // 1-6
    setext: bool, // true = setext style, false = ATX
};

pub const CodeBlockData = struct {
    info: []const u8, // info string (language), empty if none
    fenced: bool,
    fence_char: u8, // '`' or '~'
    fence_len: u8, // number of fence chars
    indent: u3, // opening fence indentation (0-3), for content stripping
};

pub const ListData = struct {
    ordered: bool,
    start: u32, // starting number for ordered lists
    marker: u8, // '-', '*', '+', ')', '.'
    tight: bool,
};

pub const LinkData = struct {
    destination: []const u8,
    title: []const u8, // empty if no title
};

pub const WikiLinkData = struct {
    target: []const u8,
    has_display: bool, // true if [[target|display]] syntax was used
};

pub const Alignment = enum(u2) {
    none,
    left,
    center,
    right,
};

pub const TableCellData = struct {
    alignment: Alignment,
    is_header: bool,
};

pub const TaskState = enum(u2) {
    none,
    unchecked,
    checked,
};

pub const RefDef = struct {
    destination: []const u8,
    title: []const u8, // empty if none
};

/// Per-tag associated data.
/// Large variants (LinkData, CodeBlockData, WikiLinkData) are stored in
/// Document side arrays; the union holds a u32 index into those arrays.
pub const Data = union(enum) {
    heading: HeadingData,
    code_block: u32, // index into Document.code_block_data
    list: ListData,
    link: u32, // index into Document.link_data
    image: u32, // index into Document.link_data
    wiki_link: u32, // index into Document.wiki_link_data
    /// Source span for text content — zero-copy reference into original source.
    /// Used by: text, code_span, html_block, html_inline, autolink, frontmatter (at document level).
    content: SourceSpan,
    /// Arena-allocated text content for cases where content isn't contiguous
    /// in the source (e.g. text inside blockquotes/lists where `>` markers are stripped).
    literal: []const u8,
    table_cell: TableCellData,
    task_state: TaskState, // list_item task checkbox state
    none: void, // document, block_quote, paragraph, thematic_break, soft_break, hard_break, emphasis, strong, critic containers
};

/// AST node. Linked into a tree via parent/child/sibling pointers.
pub const Node = struct {
    tag: Tag,
    data: Data,
    source: SourceSpan,

    parent: ?*Node = null,
    first_child: ?*Node = null,
    last_child: ?*Node = null,
    next: ?*Node = null,
    prev: ?*Node = null,

    /// Get the text content of a text/code_span node.
    pub fn textContent(self: *const Node, source: []const u8) []const u8 {
        return switch (self.data) {
            .content => |span| span.slice(source),
            .literal => |s| s,
            else => "",
        };
    }

    /// Append a child node.
    pub fn appendChild(self: *Node, child: *Node) void {
        child.parent = self;
        child.prev = self.last_child;
        child.next = null;
        if (self.last_child) |last| {
            last.next = child;
        } else {
            self.first_child = child;
        }
        self.last_child = child;
    }

    /// Insert a sibling after this node.
    pub fn insertAfter(self: *Node, sibling: *Node) void {
        sibling.parent = self.parent;
        sibling.prev = self;
        sibling.next = self.next;
        if (self.next) |n| {
            n.prev = sibling;
        } else if (self.parent) |p| {
            p.last_child = sibling;
        }
        self.next = sibling;
    }

    /// Detach this node from its parent.
    pub fn detach(self: *Node) void {
        if (self.prev) |p| {
            p.next = self.next;
        } else if (self.parent) |p| {
            p.first_child = self.next;
        }
        if (self.next) |n| {
            n.prev = self.prev;
        } else if (self.parent) |p| {
            p.last_child = self.prev;
        }
        self.parent = null;
        self.prev = null;
        self.next = null;
    }

    /// Iterate children.
    pub fn children(self: *const Node) ChildIterator {
        return .{ .current = self.first_child };
    }

    pub const ChildIterator = struct {
        current: ?*Node,

        pub fn next(self: *ChildIterator) ?*Node {
            const node = self.current orelse return null;
            self.current = node.next;
            return node;
        }
    };
};

/// Event-based iterator for walking the AST (enter/exit pairs for containers).
pub const Event = union(enum) {
    enter: *Node,
    exit: *Node,
    leaf: *Node,
};

pub const TreeIterator = struct {
    current: ?*Node,
    entering: bool,

    pub fn init(root: *Node) TreeIterator {
        return .{ .current = root, .entering = true };
    }

    pub fn next(self: *TreeIterator) ?Event {
        const node = self.current orelse return null;

        if (self.entering) {
            if (node.tag.isContainer()) {
                if (node.first_child) |child| {
                    self.current = child;
                    self.entering = true;
                    return .{ .enter = node };
                } else {
                    self.entering = false;
                    return .{ .enter = node };
                }
            } else {
                self.advancePastLeaf(node);
                return .{ .leaf = node };
            }
        } else {
            const exit_event: Event = .{ .exit = node };
            if (node.next) |sibling| {
                self.current = sibling;
                self.entering = true;
            } else if (node.parent) |parent| {
                self.current = parent;
                self.entering = false;
            } else {
                self.current = null;
            }
            return exit_event;
        }
    }

    fn advancePastLeaf(self: *TreeIterator, node: *Node) void {
        if (node.next) |sibling| {
            self.current = sibling;
            self.entering = true;
        } else if (node.parent) |parent| {
            self.current = parent;
            self.entering = false;
        } else {
            self.current = null;
        }
    }
};

/// Bump-allocated pool for Node structs.
/// Nodes are stored in contiguous pages for cache-friendly tree walks.
pub const NodePool = struct {
    pages: std.ArrayListUnmanaged([*]Node),
    index: usize,
    page_size: usize,

    const DEFAULT_PAGE_SIZE = 4096; // ~360KB per page at 88 bytes/node

    pub fn init() NodePool {
        return .{
            .pages = .empty,
            .index = DEFAULT_PAGE_SIZE, // Start full to trigger first allocation
            .page_size = DEFAULT_PAGE_SIZE,
        };
    }

    pub fn create(self: *NodePool, allocator: std.mem.Allocator) !*Node {
        if (self.index >= self.page_size) {
            const page = try allocator.alloc(Node, self.page_size);
            try self.pages.append(allocator, page.ptr);
            self.index = 0;
        }
        const node = &self.pages.items[self.pages.items.len - 1][self.index];
        self.index += 1;
        return node;
    }
};

/// Arena-based document that owns all nodes.
/// Stores a reference to the original source for zero-copy text access.
pub const Document = struct {
    arena: std.heap.ArenaAllocator,
    node_pool: NodePool,
    root: *Node,
    source: []const u8,
    line_index: LineIndex,
    ref_map: std.StringHashMapUnmanaged(RefDef),
    extensions: Extensions,
    // Side arrays for externalized node data (saves ~16 bytes per Node)
    link_data: std.ArrayListUnmanaged(LinkData),
    code_block_data: std.ArrayListUnmanaged(CodeBlockData),
    wiki_link_data: std.ArrayListUnmanaged(WikiLinkData),

    pub fn init(allocator: std.mem.Allocator, source: []const u8, extensions: Extensions) !Document {
        var arena = std.heap.ArenaAllocator.init(allocator);
        var pool = NodePool.init();
        const root = try pool.create(arena.allocator());
        root.* = .{
            .tag = .document,
            .data = .{ .none = {} },
            .source = .{ .start = 0, .end = source.len },
        };
        const line_index = try LineIndex.build(arena.allocator(), source);
        return .{
            .arena = arena,
            .node_pool = pool,
            .root = root,
            .source = source,
            .line_index = line_index,
            .ref_map = .empty,
            .extensions = extensions,
            .link_data = .empty,
            .code_block_data = .empty,
            .wiki_link_data = .empty,
        };
    }

    pub fn deinit(self: *Document) void {
        self.arena.deinit();
    }

    pub fn createNode(self: *Document, tag: Tag, data: Data, source: SourceSpan) !*Node {
        const node = try self.node_pool.create(self.arena.allocator());
        node.* = .{
            .tag = tag,
            .data = data,
            .source = source,
        };
        return node;
    }

    /// Allocate a string in the document arena (for computed content that
    /// doesn't directly reference the source, e.g. decoded entities).
    pub fn allocString(self: *Document, s: []const u8) ![]const u8 {
        return self.arena.allocator().dupe(u8, s);
    }

    pub fn iterator(self: *const Document) TreeIterator {
        return TreeIterator.init(self.root);
    }

    /// Get the text content of a text/code_span node.
    pub fn nodeText(self: *const Document, node: *const Node) []const u8 {
        return switch (node.data) {
            .content => |span| span.slice(self.source),
            .literal => |s| s,
            else => "",
        };
    }

    /// Look up a link reference definition by normalized label.
    pub fn lookupRef(self: *const Document, label: []const u8) ?RefDef {
        return self.ref_map.get(label);
    }

    // ── Side-table accessors for externalized data ───────────────────

    pub fn storeLinkData(self: *Document, ld: LinkData) !u32 {
        try self.link_data.append(self.arena.allocator(), ld);
        return @intCast(self.link_data.items.len - 1);
    }

    pub fn getLinkData(self: *const Document, idx: u32) LinkData {
        return self.link_data.items[idx];
    }

    pub fn storeCodeBlockData(self: *Document, cbd: CodeBlockData) !u32 {
        try self.code_block_data.append(self.arena.allocator(), cbd);
        return @intCast(self.code_block_data.items.len - 1);
    }

    pub fn getCodeBlockData(self: *const Document, idx: u32) CodeBlockData {
        return self.code_block_data.items[idx];
    }

    pub fn storeWikiLinkData(self: *Document, wld: WikiLinkData) !u32 {
        try self.wiki_link_data.append(self.arena.allocator(), wld);
        return @intCast(self.wiki_link_data.items.len - 1);
    }

    pub fn getWikiLinkData(self: *const Document, idx: u32) WikiLinkData {
        return self.wiki_link_data.items[idx];
    }

    comptime {
        // Ensure the Data union stayed small after externalization.
        // If a new large variant is added, this will catch it.
        std.debug.assert(@sizeOf(Data) <= 24);
    }
};

// ── Tests ──────────────────────────────────────────────────────────────

test "create document with children" {
    const allocator = std.testing.allocator;
    const source = "# Hello\n\nWorld";
    var doc = try Document.init(allocator, source, .{});
    defer doc.deinit();

    const h = try doc.createNode(.heading, .{ .heading = .{ .level = 1, .setext = false } }, SourceSpan.empty);
    const p = try doc.createNode(.paragraph, .{ .none = {} }, SourceSpan.empty);

    doc.root.appendChild(h);
    doc.root.appendChild(p);

    try std.testing.expectEqual(h, doc.root.first_child.?);
    try std.testing.expectEqual(p, doc.root.last_child.?);
    try std.testing.expectEqual(h.next.?, p);
    try std.testing.expectEqual(p.prev.?, h);
}

test "tree iterator" {
    const allocator = std.testing.allocator;
    const source = "";
    var doc = try Document.init(allocator, source, .{});
    defer doc.deinit();

    const h = try doc.createNode(.heading, .{ .heading = .{ .level = 1, .setext = false } }, SourceSpan.empty);
    const text = try doc.createNode(.text, .{ .content = .{ .start = 0, .end = 0 } }, SourceSpan.empty);
    h.appendChild(text);

    const p = try doc.createNode(.paragraph, .{ .none = {} }, SourceSpan.empty);
    const ptext = try doc.createNode(.text, .{ .content = .{ .start = 0, .end = 0 } }, SourceSpan.empty);
    p.appendChild(ptext);

    doc.root.appendChild(h);
    doc.root.appendChild(p);

    var iter = doc.iterator();

    try std.testing.expectEqual(Tag.document, iter.next().?.enter.tag);
    try std.testing.expectEqual(Tag.heading, iter.next().?.enter.tag);
    try std.testing.expectEqual(Tag.text, iter.next().?.leaf.tag);
    try std.testing.expectEqual(Tag.heading, iter.next().?.exit.tag);
    try std.testing.expectEqual(Tag.paragraph, iter.next().?.enter.tag);
    try std.testing.expectEqual(Tag.text, iter.next().?.leaf.tag);
    try std.testing.expectEqual(Tag.paragraph, iter.next().?.exit.tag);
    try std.testing.expectEqual(Tag.document, iter.next().?.exit.tag);
    try std.testing.expectEqual(null, iter.next());
}

test "line index" {
    const allocator = std.testing.allocator;
    const source = "line one\nline two\nline three";
    var doc = try Document.init(allocator, source, .{});
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 3), doc.line_index.lineCount());
    // "line one" is line 0
    try std.testing.expectEqual(@as(usize, 0), doc.line_index.lineAt(0));
    try std.testing.expectEqual(@as(usize, 0), doc.line_index.lineAt(4));
    // "line two" is line 1
    try std.testing.expectEqual(@as(usize, 1), doc.line_index.lineAt(9));
    // "line three" is line 2
    try std.testing.expectEqual(@as(usize, 2), doc.line_index.lineAt(18));
    // Column check
    const lc = doc.line_index.lineCol(13); // 'w' in "two"
    try std.testing.expectEqual(@as(usize, 1), lc.line);
    try std.testing.expectEqual(@as(usize, 4), lc.col);
}

test "line index — single line" {
    const allocator = std.testing.allocator;
    var doc = try Document.init(allocator, "no newlines here", .{});
    defer doc.deinit();
    try std.testing.expectEqual(@as(usize, 1), doc.line_index.lineCount());
    try std.testing.expectEqual(@as(usize, 0), doc.line_index.lineAt(0));
    try std.testing.expectEqual(@as(usize, 0), doc.line_index.lineAt(10));
    try std.testing.expectEqual(@as(usize, 10), doc.line_index.colAt(10));
}

test "line index — empty source" {
    const allocator = std.testing.allocator;
    var doc = try Document.init(allocator, "", .{});
    defer doc.deinit();
    try std.testing.expectEqual(@as(usize, 1), doc.line_index.lineCount());
    try std.testing.expectEqual(@as(usize, 0), doc.line_index.lineAt(0));
}

test "line index — colAt" {
    const allocator = std.testing.allocator;
    var doc = try Document.init(allocator, "abc\ndef\nghi", .{});
    defer doc.deinit();
    // 'd' is at offset 4, col 0 of line 1
    try std.testing.expectEqual(@as(usize, 0), doc.line_index.colAt(4));
    // 'f' is at offset 6, col 2 of line 1
    try std.testing.expectEqual(@as(usize, 2), doc.line_index.colAt(6));
    // 'g' is at offset 8, col 0 of line 2
    try std.testing.expectEqual(@as(usize, 0), doc.line_index.colAt(8));
}

test "node — appendChild multiple children" {
    const allocator = std.testing.allocator;
    var doc = try Document.init(allocator, "", .{});
    defer doc.deinit();

    const a = try doc.createNode(.text, .{ .none = {} }, SourceSpan.empty);
    const b = try doc.createNode(.text, .{ .none = {} }, SourceSpan.empty);
    const c = try doc.createNode(.text, .{ .none = {} }, SourceSpan.empty);
    doc.root.appendChild(a);
    doc.root.appendChild(b);
    doc.root.appendChild(c);

    // first/last
    try std.testing.expectEqual(a, doc.root.first_child.?);
    try std.testing.expectEqual(c, doc.root.last_child.?);
    // chain
    try std.testing.expectEqual(b, a.next.?);
    try std.testing.expectEqual(c, b.next.?);
    try std.testing.expectEqual(@as(?*Node, null), c.next);
    // prev links
    try std.testing.expectEqual(@as(?*Node, null), a.prev);
    try std.testing.expectEqual(a, b.prev.?);
    try std.testing.expectEqual(b, c.prev.?);
    // parent
    try std.testing.expectEqual(doc.root, a.parent.?);
    try std.testing.expectEqual(doc.root, c.parent.?);
}

test "node — insertAfter" {
    const allocator = std.testing.allocator;
    var doc = try Document.init(allocator, "", .{});
    defer doc.deinit();

    const a = try doc.createNode(.text, .{ .none = {} }, SourceSpan.empty);
    const c = try doc.createNode(.text, .{ .none = {} }, SourceSpan.empty);
    doc.root.appendChild(a);
    doc.root.appendChild(c);

    // Insert b between a and c
    const b = try doc.createNode(.emphasis, .{ .none = {} }, SourceSpan.empty);
    a.insertAfter(b);

    try std.testing.expectEqual(b, a.next.?);
    try std.testing.expectEqual(c, b.next.?);
    try std.testing.expectEqual(a, b.prev.?);
    try std.testing.expectEqual(b, c.prev.?);
    try std.testing.expectEqual(doc.root, b.parent.?);
}

test "node — insertAfter at end updates parent last_child" {
    const allocator = std.testing.allocator;
    var doc = try Document.init(allocator, "", .{});
    defer doc.deinit();

    const a = try doc.createNode(.text, .{ .none = {} }, SourceSpan.empty);
    doc.root.appendChild(a);
    try std.testing.expectEqual(a, doc.root.last_child.?);

    const b = try doc.createNode(.text, .{ .none = {} }, SourceSpan.empty);
    a.insertAfter(b);
    try std.testing.expectEqual(b, doc.root.last_child.?);
}

test "node — detach middle child" {
    const allocator = std.testing.allocator;
    var doc = try Document.init(allocator, "", .{});
    defer doc.deinit();

    const a = try doc.createNode(.text, .{ .none = {} }, SourceSpan.empty);
    const b = try doc.createNode(.text, .{ .none = {} }, SourceSpan.empty);
    const c = try doc.createNode(.text, .{ .none = {} }, SourceSpan.empty);
    doc.root.appendChild(a);
    doc.root.appendChild(b);
    doc.root.appendChild(c);

    b.detach();

    // a→c, c←a
    try std.testing.expectEqual(c, a.next.?);
    try std.testing.expectEqual(a, c.prev.?);
    // b is fully detached
    try std.testing.expectEqual(@as(?*Node, null), b.parent);
    try std.testing.expectEqual(@as(?*Node, null), b.prev);
    try std.testing.expectEqual(@as(?*Node, null), b.next);
    // first/last unchanged
    try std.testing.expectEqual(a, doc.root.first_child.?);
    try std.testing.expectEqual(c, doc.root.last_child.?);
}

test "node — detach first child" {
    const allocator = std.testing.allocator;
    var doc = try Document.init(allocator, "", .{});
    defer doc.deinit();

    const a = try doc.createNode(.text, .{ .none = {} }, SourceSpan.empty);
    const b = try doc.createNode(.text, .{ .none = {} }, SourceSpan.empty);
    doc.root.appendChild(a);
    doc.root.appendChild(b);

    a.detach();

    try std.testing.expectEqual(b, doc.root.first_child.?);
    try std.testing.expectEqual(b, doc.root.last_child.?);
    try std.testing.expectEqual(@as(?*Node, null), b.prev);
}

test "node — detach last child" {
    const allocator = std.testing.allocator;
    var doc = try Document.init(allocator, "", .{});
    defer doc.deinit();

    const a = try doc.createNode(.text, .{ .none = {} }, SourceSpan.empty);
    const b = try doc.createNode(.text, .{ .none = {} }, SourceSpan.empty);
    doc.root.appendChild(a);
    doc.root.appendChild(b);

    b.detach();

    try std.testing.expectEqual(a, doc.root.first_child.?);
    try std.testing.expectEqual(a, doc.root.last_child.?);
    try std.testing.expectEqual(@as(?*Node, null), a.next);
}

test "node — detach only child" {
    const allocator = std.testing.allocator;
    var doc = try Document.init(allocator, "", .{});
    defer doc.deinit();

    const a = try doc.createNode(.text, .{ .none = {} }, SourceSpan.empty);
    doc.root.appendChild(a);
    a.detach();

    try std.testing.expectEqual(@as(?*Node, null), doc.root.first_child);
    try std.testing.expectEqual(@as(?*Node, null), doc.root.last_child);
}

test "node — children iterator" {
    const allocator = std.testing.allocator;
    var doc = try Document.init(allocator, "", .{});
    defer doc.deinit();

    const a = try doc.createNode(.paragraph, .{ .none = {} }, SourceSpan.empty);
    const b = try doc.createNode(.heading, .{ .heading = .{ .level = 2, .setext = false } }, SourceSpan.empty);
    const c = try doc.createNode(.thematic_break, .{ .none = {} }, SourceSpan.empty);
    doc.root.appendChild(a);
    doc.root.appendChild(b);
    doc.root.appendChild(c);

    var iter = doc.root.children();
    try std.testing.expectEqual(Tag.paragraph, iter.next().?.tag);
    try std.testing.expectEqual(Tag.heading, iter.next().?.tag);
    try std.testing.expectEqual(Tag.thematic_break, iter.next().?.tag);
    try std.testing.expectEqual(@as(?*Node, null), iter.next());
}

test "node — children iterator empty" {
    const allocator = std.testing.allocator;
    var doc = try Document.init(allocator, "", .{});
    defer doc.deinit();

    var iter = doc.root.children();
    try std.testing.expectEqual(@as(?*Node, null), iter.next());
}

test "node — textContent with content span" {
    const allocator = std.testing.allocator;
    const source = "hello world";
    var doc = try Document.init(allocator, source, .{});
    defer doc.deinit();

    const node = try doc.createNode(.text, .{ .content = .{ .start = 6, .end = 11 } }, SourceSpan.empty);
    try std.testing.expectEqualStrings("world", node.textContent(source));
}

test "node — textContent with literal" {
    const allocator = std.testing.allocator;
    var doc = try Document.init(allocator, "", .{});
    defer doc.deinit();

    const s = try doc.allocString("computed");
    const node = try doc.createNode(.text, .{ .literal = s }, SourceSpan.empty);
    try std.testing.expectEqualStrings("computed", node.textContent(""));
}

test "node — textContent with non-text data returns empty" {
    const allocator = std.testing.allocator;
    var doc = try Document.init(allocator, "", .{});
    defer doc.deinit();

    const node = try doc.createNode(.paragraph, .{ .none = {} }, SourceSpan.empty);
    try std.testing.expectEqualStrings("", node.textContent(""));
}

test "document — nodeText" {
    const allocator = std.testing.allocator;
    const source = "hello world";
    var doc = try Document.init(allocator, source, .{});
    defer doc.deinit();

    const node = try doc.createNode(.text, .{ .content = .{ .start = 0, .end = 5 } }, SourceSpan.empty);
    try std.testing.expectEqualStrings("hello", doc.nodeText(node));
}

test "document — side arrays store and retrieve" {
    const allocator = std.testing.allocator;
    var doc = try Document.init(allocator, "", .{});
    defer doc.deinit();

    // LinkData
    const ld_idx = try doc.storeLinkData(.{ .destination = "/url", .title = "t" });
    const ld = doc.getLinkData(ld_idx);
    try std.testing.expectEqualStrings("/url", ld.destination);
    try std.testing.expectEqualStrings("t", ld.title);

    // CodeBlockData
    const cbd_idx = try doc.storeCodeBlockData(.{
        .info = "zig",
        .fenced = true,
        .fence_char = '`',
        .fence_len = 3,
        .indent = 0,
    });
    const cbd = doc.getCodeBlockData(cbd_idx);
    try std.testing.expectEqualStrings("zig", cbd.info);
    try std.testing.expect(cbd.fenced);
    try std.testing.expectEqual(@as(u8, '`'), cbd.fence_char);

    // WikiLinkData
    const wld_idx = try doc.storeWikiLinkData(.{ .target = "page", .has_display = true });
    const wld = doc.getWikiLinkData(wld_idx);
    try std.testing.expectEqualStrings("page", wld.target);
    try std.testing.expect(wld.has_display);
}

test "document — multiple side array entries" {
    const allocator = std.testing.allocator;
    var doc = try Document.init(allocator, "", .{});
    defer doc.deinit();

    const idx0 = try doc.storeLinkData(.{ .destination = "/a", .title = "" });
    const idx1 = try doc.storeLinkData(.{ .destination = "/b", .title = "B" });

    try std.testing.expectEqual(@as(u32, 0), idx0);
    try std.testing.expectEqual(@as(u32, 1), idx1);
    try std.testing.expectEqualStrings("/a", doc.getLinkData(idx0).destination);
    try std.testing.expectEqualStrings("/b", doc.getLinkData(idx1).destination);
}

test "tree iterator — empty container" {
    const allocator = std.testing.allocator;
    var doc = try Document.init(allocator, "", .{});
    defer doc.deinit();

    // Add an empty blockquote (container with no children)
    const bq = try doc.createNode(.block_quote, .{ .none = {} }, SourceSpan.empty);
    doc.root.appendChild(bq);

    var iter = doc.iterator();
    try std.testing.expectEqual(Tag.document, iter.next().?.enter.tag);
    try std.testing.expectEqual(Tag.block_quote, iter.next().?.enter.tag);
    try std.testing.expectEqual(Tag.block_quote, iter.next().?.exit.tag);
    try std.testing.expectEqual(Tag.document, iter.next().?.exit.tag);
    try std.testing.expectEqual(@as(?Event, null), iter.next());
}

test "tag — isBlock and isInline" {
    try std.testing.expect(Tag.paragraph.isBlock());
    try std.testing.expect(Tag.heading.isBlock());
    try std.testing.expect(Tag.table.isBlock());
    try std.testing.expect(!Tag.text.isBlock());
    try std.testing.expect(!Tag.emphasis.isBlock());

    try std.testing.expect(Tag.text.isInline());
    try std.testing.expect(Tag.emphasis.isInline());
    try std.testing.expect(Tag.code_span.isInline());
    try std.testing.expect(!Tag.paragraph.isInline());
}

test "tag — isContainer and isLeaf" {
    try std.testing.expect(Tag.document.isContainer());
    try std.testing.expect(Tag.block_quote.isContainer());
    try std.testing.expect(Tag.list.isContainer());
    try std.testing.expect(Tag.emphasis.isContainer());
    try std.testing.expect(Tag.table.isContainer());
    try std.testing.expect(!Tag.text.isContainer());
    try std.testing.expect(!Tag.thematic_break.isContainer());

    try std.testing.expect(Tag.text.isLeaf());
    try std.testing.expect(Tag.code_span.isLeaf());
    try std.testing.expect(Tag.thematic_break.isLeaf());
    try std.testing.expect(!Tag.document.isLeaf());
    try std.testing.expect(!Tag.emphasis.isLeaf());
}

test "source span — len and slice" {
    const source = "hello world";
    const span = SourceSpan{ .start = 6, .end = 11 };
    try std.testing.expectEqual(@as(usize, 5), span.len());
    try std.testing.expectEqualStrings("world", span.slice(source));

    const empty = SourceSpan.empty;
    try std.testing.expectEqual(@as(usize, 0), empty.len());
    try std.testing.expectEqualStrings("", empty.slice(source));
}
