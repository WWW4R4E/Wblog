---
date: ""
category: "Zig"
read_time: "15分钟阅读"
title: "Zig 0.16 IO 系统笔记"
excerpt: "深入理解 Zig 0.16 的新 IO 系统，包括 Reader、Writer、File 等核心组件的使用方法"
tags: ["Zig", "IO", "笔记"]
---

# Zig 0.16 IO 系统笔记

## 核心架构

Zig 0.16 的 I/O 系统基于 **`std.Io`** 模块，采用 **vtable（虚函数表）** 模式实现跨平台抽象。

```
std.Io          // I/O 上下文（包含 userdata + vtable）
├── Reader      // 通用读取器
├── Writer      // 通用写入器
├── File        // 文件操作
├── Dir         // 目录操作
├── net         // 网络
└── Terminal    // 终端
```

## 关键概念：`std.Io` 不是静态命名空间

在 Zig 0.16 中，`std.Io` 是一个 **struct 类型**，运行时实例通过 `std.process.Init` 传入：

```zig
pub fn main(init: std.process.Init) !void {
    const io = init.io;  // io 是 std.Io 的实例
}
```

这个 `io` 实例包含了当前平台的 I/O 实现（如 io_uring、kqueue、IOCP 等）。

---

## Reader（读取器）

### 创建 Reader

#### 1. 从 stdin 读取（最常用）

```zig
// ❌ 错误：没有提供缓冲区
var input = std.Io.File.stdin().reader(io, &.{});

// ✅ 正确：必须提供缓冲区
var stdin_buf: [4096]u8 = undefined;
var input = std.Io.File.stdin().reader(io, stdin_buf[0..]);
```

**为什么需要缓冲区？**  
Reader 内部使用缓冲区来暂存从底层读取的数据。缓冲区太小或为空会导致 `error.StreamTooLong`（找不到分隔符）。

#### 2. 从字符串创建（用于测试）

```zig
var reader = std.Io.Reader.fixed("hello world");
```

### Reader 核心方法

| 方法 | 说明 | 返回值 |
|------|------|--------|
| `takeByte()` | 读取 1 字节 | `Error!u8` |
| `take(n)` | 读取 n 字节 | `Error![]u8` |
| `peek(n)` | 预览 n 字节（不消耗） | `Error![]u8` |
| `toss(n)` | 跳过 n 字节 | `void` |
| `takeDelimiterExclusive('\n')` | 读取到分隔符（不含分隔符） | `DelimiterError![]u8` |
| `takeDelimiterInclusive('\n')` | 读取到分隔符（含分隔符） | `DelimiterError![]u8` |
| `readSliceAll(buf)` | 填充整个缓冲区 | `Error!void` |
| `readSliceShort(buf)` | 尽可能填充缓冲区 | `ShortError!usize` |
| `discard(n)` | 跳过 n 字节 | `Error!usize` |
| `stream(writer, limit)` | 泵送数据到 Writer | `StreamError!usize` |

### Reader 错误集

```zig
pub const Error = error{
    ReadFailed,    // 读取失败
    EndOfStream,   // 流已结束
};

pub const DelimiterError = error{
    ReadFailed,      // 读取失败
    EndOfStream,     // 流已结束（未找到分隔符）
    StreamTooLong,   // 超过缓冲区容量（分隔符太远）
};
```

### 读取一行文本

```zig
var stdin_buf: [4096]u8 = undefined;
var input = std.Io.File.stdin().reader(io, stdin_buf[0..]);

// 方法 1：不含换行符（不消耗分隔符，适合单次读取）
const line = try input.interface.takeDelimiterExclusive('\n');

// 方法 2：含换行符（消耗分隔符，适合连续读取多行）
const line_with_newline = try input.interface.takeDelimiterInclusive('\n');
```

**重要提示：** `takeDelimiterExclusive()` 不会消耗分隔符，因此不能用于连续读取多行。如果需要逐行读取，请使用 `takeDelimiterInclusive()` 并手动移除末尾的换行符。

### 读取整数

```zig
// 读取指定字节数的整数
const value = try reader.takeInt(u32, .little);

// 读取 LEB128 编码的整数
const leb_value = try reader.takeLeb128(u64);
```

---

## Writer（写入器）

### 创建 Writer

#### 1. 写入 stdout

```zig
var stdout_buf: [4096]u8 = undefined;
var output = std.Io.File.stdout().writer(io, stdout_buf[0..]);
```

#### 2. 写入 stderr

```zig
var stderr_buf: [4096]u8 = undefined;
var err_output = std.Io.File.stderr().writer(io, stderr_buf[0..]);
```

#### 3. 固定缓冲区（用于构建字符串）

```zig
var buf: [256]u8 = undefined;
var writer = std.Io.Writer.fixed(&buf[0..]);
try writer.writeAll("hello");
const result = writer.buffered();  // 获取已写入的内容
```

#### 4. 动态分配（最灵活）

```zig
var writer = std.Io.Writer.Allocating.init(allocator);
defer writer.deinit();

try writer.writer.print("Name: {s}, Age: {d}", .{ "Alice", 25 });
const result = writer.writer.buffered();
```

### Writer 核心方法

| 方法 | 说明 |
|------|------|
| `write(bytes)` | 写入字节（可能部分写入） |
| `writeAll(bytes)` | 写入所有字节 |
| `writeByte(byte)` | 写入单个字节 |
| `print(fmt, args)` | 格式化输出 |
| `flush()` | 刷新缓冲区 |
| `writeInt(T, value, endian)` | 写入整数（指定字节序） |
| `writeStruct(value, endian)` | 写入结构体 |
| `splatByteAll(byte, n)` | 重复写入同一个字节 n 次 |
| `splatBytesAll(bytes, n)` | 重复写入同一段字节 n 次 |

### 格式化输出（print）

```zig
try writer.print("值: {d}", .{42});           // 十进制
try writer.print("十六进制: {x}", .{255});     // 小写十六进制
try writer.print("十六进制: {X}", .{255});     // 大写十六进制
try writer.print("字符串: {s}", .{"hello"});   // 字符串
try writer.print("二进制: {b}", .{10});        // 二进制
try writer.print("八进制: {o}", .{8});         // 八进制
try writer.print("可选: {?}", .{optional_val}); // Optional
try writer.print("错误: {!}", .{error_union});  // Error Union
try writer.print("枚举: {t}", .{.my_tag});      // 标签名
```

### Writer 错误集

```zig
pub const Error = error{
    WriteFailed,  // 写入失败
};
```

---

## File（文件）

### 获取标准流

```zig
const stdin_file = std.Io.File.stdin();   // 标准输入
const stdout_file = std.Io.File.stdout(); // 标准输出
const stderr_file = std.Io.File.stderr(); // 标准错误
```

### File Reader 和 Writer

```zig
// 创建文件 Reader（需要 io 实例和缓冲区）
var file_buf: [8192]u8 = undefined;
var file_reader = file.reader(io, file_buf[0..]);

// 创建文件 Writer
var write_buf: [8192]u8 = undefined;
var file_writer = file.writer(io, write_buf[0..]);
```

### File Reader 的模式

```zig
// 位置读取（默认，线程安全）
var reader = file.reader(io, buffer[0..]);

// 流式读取（适合管道/套接字）
var reader = file.readerStreaming(io, buffer[0..]);
```

---

## 实用示例

### 示例 1：读取用户输入

```zig
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    // 提示用户
    var stderr_buf: [256]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(io, stderr_buf[0..]);
    try stderr.interface.writeAll("请输入你的名字: ");
    try stderr.interface.flush();

    // 读取输入
    var stdin_buf: [1024]u8 = undefined;
    var stdin = std.Io.File.stdin().reader(io, stdin_buf[0..]);
    const name = try stdin.interface.takeDelimiterExclusive('\n');

    // 输出结果
    var stdout_buf: [256]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, stdout_buf[0..]);
    try stdout.interface.print("你好, {s}!\n", .{name});
    try stdout.interface.flush();
}
```

### 示例 2：读取多行

```zig
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var stdin_buf: [4096]u8 = undefined;
    var stdin = std.Io.File.stdin().reader(io, stdin_buf[0..]);

    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, stdout_buf[0..]);

    var line_num: u32 = 1;
    while (true) {
        // 使用 takeDelimiterInclusive 读取包含换行符的行
        const line_with_newline = stdin.interface.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream => {
                // 尝试读取剩余内容（最后一行可能没有换行符）
                const remaining = stdin.interface.takeDelimiterExclusive('\n') catch |err2| switch (err2) {
                    error.EndOfStream => break,
                    else => return err2,
                };
                if (remaining.len > 0) {
                    try stdout.interface.print("第{d}行: {s}\n", .{ line_num, remaining });
                    line_num += 1;
                }
                break;
            },
            else => return err,
        };
        // 去掉末尾的换行符
        const line = if (line_with_newline.len > 0 and line_with_newline[line_with_newline.len - 1] == '\n')
            line_with_newline[0 .. line_with_newline.len - 1]
        else
            line_with_newline;
        try stdout.interface.print("第{d}行: {s}\n", .{ line_num, line });
        line_num += 1;
    }
    try stdout.interface.flush();
}
```

### 示例 3：构建字符串

```zig
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = std.heap.page_allocator;

    // 使用 Allocating Writer 构建字符串
    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();

    try aw.writer.writeAll("Hello, ");
    try aw.writer.writeAll("World!");
    try aw.writer.print(" 数字: {d}", .{42});

    const result = aw.writer.buffered();

    // 输出
    var stdout_buf: [256]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, stdout_buf[0..]);
    try stdout.interface.writeAll(result);
    try stdout.interface.writeByte('\n');
    try stdout.interface.flush();
}
```

### 示例 4：读取文件内容

```zig
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const cwd = std.fs.cwd();

    // 打开文件
    const file = try cwd.openFile(io, "test.txt", .{});
    defer file.close(&io, .{&file});

    // 创建带缓冲的 Reader
    var buf: [4096]u8 = undefined;
    var reader = file.reader(io, buf[0..]);

    // 读取并输出
    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, stdout_buf[0..]);

    while (reader.interface.takeDelimiterInclusive('\n')) |line_with_newline| {
        // 去掉末尾的换行符
        const line = if (line_with_newline.len > 0 and line_with_newline[line_with_newline.len - 1] == '\n')
            line_with_newline[0 .. line_with_newline.len - 1]
        else
            line_with_newline;
        try stdout.interface.writeAll(line);
        try stdout.interface.writeByte('\n');
    } else |err| switch (err) {
        error.EndOfStream => {
            // 尝试读取剩余内容（最后一行可能没有换行符）
            const remaining = reader.interface.takeDelimiterExclusive('\n') catch |err2| switch (err2) {
                error.EndOfStream => {},
                else => return err2,
            };
            if (remaining.len > 0) {
                try stdout.interface.writeAll(remaining);
                try stdout.interface.writeByte('\n');
            }
        },
        else => return err,
    }
    try stdout.interface.flush();
}
```

---

## 常见陷阱与解决方案

### 1. `error.StreamTooLong` 错误

**原因：** 缓冲区太小，找不到分隔符。

```zig
// ❌ 错误
var input = std.Io.File.stdin().reader(io, &.{});  // 缓冲区为空

// ✅ 正确
var stdin_buf: [4096]u8 = undefined;
var input = std.Io.File.stdin().reader(io, stdin_buf[0..]);
```

### 2. 忘记 flush

Writer 内部有缓冲区，必须调用 `flush()` 确保数据写出：

```zig
// 对于 File.Writer（通过 file.writer() 创建）
try writer.interface.writeAll("hello");
try writer.interface.flush();  // 必须！

// 对于固定缓冲区 Writer（通过 std.Io.Writer.fixed() 创建）
var fixed_writer = std.Io.Writer.fixed(&buf);
try fixed_writer.writeAll("hello");
try fixed_writer.flush();  // 必须！
```

### 3. 缓冲区大小选择

- **stdin/stdout：** 通常 1024-4096 字节足够
- **文件 I/O：** 4096-8192 字节较好
- **网络 I/O：** 根据 MTU 选择（通常 1500-8192）

### 4. Reader 接口访问

File.Reader 包装了 `interface` 字段，实际读取操作通过 `.interface` 访问：

```zig
var file_reader = file.reader(io, buffer[0..]);
// 使用 file_reader.interface 进行读取
const data = try file_reader.interface.take(10);
```

---

## 类型关系图

```
std.Io                    // I/O 上下文（运行时多态）
│
├── Io.Reader             // 通用读取器接口
│   ├── .vtable           // 虚函数表
│   ├── .buffer           // 缓冲区
│   ├── .seek             // 当前位置
│   └── .end              // 有效数据结束位置
│
├── Io.Writer             // 通用写入器接口
│   ├── .vtable           // 虚函数表
│   ├── .buffer           // 缓冲区
│   └── .end              // 已写入数据结束位置
│
├── Io.File               // 文件句柄
│   ├── .reader() → File.Reader
│   └── .writer() → File.Writer
│
├── Io.File.Reader        // 文件读取器（包装 Io.Reader）
│   ├── .io               // I/O 上下文
│   ├── .file             // 文件句柄
│   └── .interface        // Io.Reader（实际读取接口）
│
└── Io.Writer.Allocating  // 动态分配写入器
    ├── .allocator        // 分配器
    └── .writer           // Writer 接口
```

---

## 从 Zig 0.13/0.14 迁移要点

| 旧版本 | Zig 0.16 |
|--------|----------|
| `std.io.getStdIn().reader()` | `std.Io.File.stdin().reader(io, buf[0..])` |
| `std.io.getStdOut().writer()` | `std.Io.File.stdout().writer(io, buf[0..])` |
| `std.io.getStdErr().writer()` | `std.Io.File.stderr().writer(io, buf[0..])` |
| `reader.readUntilDelimiterAlloc()` | `reader.interface.takeDelimiterExclusive()` |
| `reader.readUntilDelimiter()` | `reader.interface.takeDelimiterInclusive()` |
| `std.ArrayListWriter` | `std.Io.Writer.Allocating` |

**核心变化：**
1. 所有 I/O 操作都需要 `io` 实例
2. 必须显式提供缓冲区
3. 使用 vtable 实现跨平台抽象
4. Reader/Writer 接口更加统一
