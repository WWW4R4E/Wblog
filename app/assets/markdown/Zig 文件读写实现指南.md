---
date: ""
category: "Zig"
read_time: "10分钟阅读"
title: "Zig 文件读写实现指南"
excerpt: "Zig 新 IO 系统下文件读取和创建操作的完整实现指南"
tags: ["Zig", "文件操作", "笔记"]
---

# Zig 文件读写实现指南

本文介绍 Zig 新 IO 系统（`std.Io`）下如何进行文件的读取和创建操作。

## 核心概念

Zig 的新 IO 系统通过 `std.Io` 提供统一的异步文件操作接口，所有 IO 操作都需要传入 `std.Io` 实例。

### 主要组件

- **`std.Io`**：IO 上下文，提供平台相关的 IO 能力
- **`std.Io.Dir`**：目录操作接口
- **`std.Io.File`**：文件操作接口
- **`std.Io.Writer`**：写入器接口

### 获取 `std.Io` 和 `Allocator` 实例

**注意**：`std.Io` 没有 `init()` 方法，且 `std.process.Init` 已提供分配器，不需要手动创建。

| 场景 | 获取方式 |
|------|----------|
| `main()` 函数 | `std.Io` 从 `init.io` 获取，`Allocator` 从 `init.gpa` 获取 |
| 测试环境 | `std.Io` 使用 `std.testing.io`，`Allocator` 使用 `std.testing.allocator` |
| 不需要实际 IO | 使用 `std.Io.failing`（会使所有 IO 操作失败） |

## 读取文件

### 基本用法

```zig
const std = @import("std");

pub fn readFileExample(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    // 从当前工作目录读取文件，无大小限制
    const bytes = try std.Io.Dir.readFileAlloc(.cwd(), io, path, allocator, .unlimited);
    return bytes; // 调用方负责释放内存
}
```

### 带大小限制的读取

```zig
const limit: usize = 1024 * 1024; // 1MB 限制
const bytes = try std.Io.Dir.readFileAlloc(.cwd(), io, path, allocator, .{ .limit = limit });
```

### 错误处理示例

```zig
const bytes = std.Io.Dir.readFileAlloc(.cwd(), io, path, allocator, .unlimited) catch |err| {
    switch (err) {
        error.FileNotFound => return error.CustomFileNotFound,
        else => return err,
    }
};
defer allocator.free(bytes);
```

### 逐行读取文件

在 Zig 新 IO 系统中，有两种主要的逐行读取方式：

#### 方式一：先读取全部内容再分割（适用于小文件）

```zig
const std = @import("std");

pub fn readLinesAllAtOnce(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]const []u8 {
    // 先读取整个文件
    const content = try std.Io.Dir.readFileAlloc(.cwd(), io, path, allocator, .unlimited);
    errdefer allocator.free(content);
    
    // 使用 splitScalar 按换行符分割
    var lines = std.ArrayList([]const u8).empty;
    errdefer {
        for (lines.items) |line| allocator.free(line);
        lines.deinit(allocator);
    }
    
    var iterator = std.mem.splitScalar(u8, content, '\n');
    while (iterator.next()) |line| {
        try lines.append(allocator, try allocator.dupe(u8, line));
    }
    
    allocator.free(content);
    return lines.toOwnedSlice(allocator);
}
```

#### 方式二：流式逐行读取（适用于大文件）

```zig
const std = @import("std");

pub fn readLinesStreaming(allocator: std.mem.Allocator, io: std.Io, path: []const u8, callback: fn (line: []const u8) !void) !void {
    // 打开文件
    const file = try std.Io.Dir.openFile(.cwd(), io, path, .{});
    defer file.close(io);
    
    // 创建 reader
    var read_buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buffer);
    
    // 逐行读取
    var line = std.ArrayList(u8).empty;
    defer line.deinit(allocator);
    
    while (true) {
        const byte = reader.interface.takeByte() catch |err| switch (err) {
            error.EndOfStream => break,
            error.ReadFailed => return reader.err.?,
            else => return err,
        };
        
        if (byte == '\n') {
            try callback(line.items);
            line.clearRetainingCapacity();
        } else {
            try line.append(allocator, byte);
        }
    }
    
    // 处理最后一行（如果文件不以换行符结尾）
    if (line.items.len > 0) {
        try callback(line.items);
    }
}
```

#### 使用示例

```zig
// 方式一：一次性读取所有行
const lines = try readLinesAllAtOnce(allocator, io, "example.txt");
defer {
    for (lines) |line| allocator.free(line);
    allocator.free(lines);
}

for (lines, 0..) |line, index| {
    std.debug.print("Line {}: {s}\n", .{index + 1, line});
}

// 方式二：流式读取并处理
try readLinesStreaming(allocator, io, "large_file.txt", struct {
    fn handleLine(line: []const u8) !void {
        std.debug.print("Line: {s}\n", .{line});
    }
}.handleLine);
```

## 创建/写入文件

### 原子写入（推荐方式）

原子写入确保写入成功后才替换原文件，避免数据损坏。

```zig
const std = @import("std");

pub fn writeFileExample(io: std.Io, path: []const u8, data: []const u8) !void {
    // 创建原子文件写入器
    var atomic_file = try std.Io.Dir.createFileAtomic(.cwd(), io, path, .{
        .make_path = true,  // 自动创建不存在的父目录
        .replace = true,    // 覆盖已存在的文件
        .mode = 0o644,      // 文件权限（可选）
    });
    defer atomic_file.deinit(io);

    // 创建写入缓冲区
    var buffer: [1024]u8 = undefined;
    var file_writer = atomic_file.file.writer(io, &buffer);
    
    // 写入数据
    try file_writer.interface.writeAll(data);
    try file_writer.flush();
    
    // 原子替换原文件
    try atomic_file.replace(io);
}
```

### 创建新文件（不覆盖）

```zig
var file = try std.Io.Dir.createFile(.cwd(), io, path, .{
    .make_path = true,
    .exclusive = true, // 文件已存在时返回错误
});
defer file.close(io);
```

## 完整示例程序

### 在 main() 函数中使用

```zig
const std = @import("std");

// main 函数接收 std.process.Init 参数
pub fn main(init: std.process.Init) !void {
    // 从 init 参数获取 IO 上下文和分配器（这是正确的方式）
    const io = init.io;
    const allocator = init.gpa; // 直接使用 init.gpa，不需要自己创建

    // 写入文件
    const content = "Hello, Zig IO!";
    try writeFile(io, "example.txt", content);
    
    // 使用标准输出（必须调用 flush 才能看到输出）
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    try stdout_writer.interface.print("Written: {s}\n", .{content});
    try stdout_writer.flush(); // 关键：刷新缓冲区到 stdout

    // 读取文件
    const read_content = try readFile(allocator, io, "example.txt");
    defer allocator.free(read_content);
    try stdout_writer.interface.print("Read: {s}\n", .{read_content});
    try stdout_writer.flush(); // 关键：刷新缓冲区到 stdout
}

fn readFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    return std.Io.Dir.readFileAlloc(.cwd(), io, path, allocator, .unlimited);
}

fn writeFile(io: std.Io, path: []const u8, data: []const u8) !void {
    var atomic_file = try std.Io.Dir.createFileAtomic(.cwd(), io, path, .{
        .make_path = true,
        .replace = true,
    });
    defer atomic_file.deinit(io);

    var buffer: [1024]u8 = undefined;
    var writer = atomic_file.file.writer(io, &buffer);
    try writer.interface.writeAll(data);
    try writer.flush();
    try atomic_file.replace(io);
}
```

### 在函数中使用（传递 io 和 allocator 参数）

```zig
const std = @import("std");

pub fn processFiles(allocator: std.mem.Allocator, io: std.Io) !void {
    // 读取配置文件
    const config = try std.Io.Dir.readFileAlloc(.cwd(), io, "config.json", allocator, .unlimited);
    defer allocator.free(config);
    
    // 处理并写入结果
    const result = try processConfig(allocator, config);
    defer allocator.free(result);
    
    try writeFile(io, "output.json", result);
}

fn writeFile(io: std.Io, path: []const u8, data: []const u8) !void {
    var atomic_file = try std.Io.Dir.createFileAtomic(.cwd(), io, path, .{
        .make_path = true,
        .replace = true,
    });
    defer atomic_file.deinit(io);

    var buffer: [1024]u8 = undefined;
    var writer = atomic_file.file.writer(io, &buffer);
    try writer.interface.writeAll(data);
    try writer.flush();
    try atomic_file.replace(io);
}
```

## 常用 API 汇总

| 操作 | API | 说明 |
|------|-----|------|
| 读取文件 | `std.Io.Dir.readFileAlloc(.cwd(), io, path, allocator, limit)` | 读取文件内容到分配的内存 |
| 原子创建 | `std.Io.Dir.createFileAtomic(.cwd(), io, path, options)` | 安全创建/覆盖文件 |
| 创建文件 | `std.Io.Dir.createFile(.cwd(), io, path, options)` | 创建新文件 |
| 删除文件 | `std.Io.Dir.deleteFile(.cwd(), io, path)` | 删除文件 |
| 重命名 | `std.Io.Dir.rename(.cwd(), io, old_path, new_path)` | 重命名文件 |
| 标准输出 | `std.Io.File.stdout().writer(io, &buffer)` | 获取标准输出 writer |
| 标准错误 | `std.Io.File.stderr().writer(io, &buffer)` | 获取标准错误 writer |

## 测试中的使用

在测试中使用 `std.testing.io` 和 `std.testing.allocator`：

```zig
test "file operations" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // 写入临时文件
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "test.txt",
        .data = "test content",
    });

    // 读取临时文件
    const content = try tmp.dir.readFileAlloc(std.testing.io, "test.txt", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(content);
    
    try std.testing.expectEqualStrings("test content", content);
}
```

## 使用失败 IO（无实际操作）

当不需要实际 IO 操作时，可以使用 `std.Io.failing`：

```zig
// 用于不需要实际 IO 的场景
const io = std.Io.failing;

// 所有 IO 操作都会失败
const result = std.Io.Dir.readFileAlloc(.cwd(), io, "file.txt", allocator, .unlimited);
// result 将是 error.FailingIo
```

## 最佳实践

1. **使用原子写入**：优先使用 `createFileAtomic` 确保数据完整性
2. **及时释放资源**：使用 `defer` 确保文件句柄和内存被正确释放
3. **错误处理**：始终处理 IO 操作可能产生的错误
4. **缓冲区写入**：使用 writer 和缓冲区提高写入效率
5. **路径处理**：使用 `std.fs.path` 工具函数处理路径
6. **传递参数**：将 `std.Io` 和 `Allocator` 作为参数传递给需要的函数，而不是全局变量
7. **测试使用测试工具**：测试代码中统一使用 `std.testing.io` 和 `std.testing.allocator`
8. **直接使用 init 参数**：在 main 函数中直接使用 `init.io` 和 `init.gpa`，不要自己创建