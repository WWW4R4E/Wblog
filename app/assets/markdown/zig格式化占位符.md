---
date: "2026-04-10"  
category: "技术"  
read_time: "8分钟阅读"  
title: "Zig 格式化占位符详解"  
excerpt: "全面解析Zig语言的格式化占位符系统，包括基础占位符、高级格式化选项、参数索引与命名、特殊类型格式化等内容。"  
tags: ["Zig", "格式化", "占位符", "笔记"]  
---

# Zig 格式化占位符完整手册

---

## 一、基础占位符速查表

|  占位符  | 说明                                                  | 输入类型                      | 示例                                |
| :------: | ----------------------------------------------------- | ----------------------------- | ----------------------------------- |
|   `{}`   | **万能占位符**（自动选择格式,但是如果不唯一就会报错） | 任意类型                      | `.{42}` → `"42"`                    |
|  `{s}`   | 字符串                                                | `[]const u8`, `[*:0]const u8` | `"hello"`                           |
|  `{d}`   | 十进制整数/浮点数                                     | 整数, 浮点数                  | `3.14` → `"3.14"`                   |
|  `{x}`   | 小写十六进制                                          | 整数                          | `255` → `"ff"`                      |
|  `{X}`   | 大写十六进制                                          | 整数                          | `255` → `"FF"`                      |
|  `{b}`   | 二进制                                                | 整数                          | `10` → `"1010"`                     |
|  `{o}`   | 八进制                                                | 整数                          | `8` → `"10"`                        |
|  `{c}`   | ASCII 字符                                            | `u8`                          | `65` → `'A'`                        |
|  `{e}`   | 科学计数法（小写 e）                                  | 浮点数                        | `3.14` → `"3.14e0"`                 |
|  `{E}`   | 科学计数法（大写 E）                                  | 浮点数                        | `3.14` → `"3.14E0"`                 |
|  `{*}`   | 指针地址                                              | 指针                          | `@ptrFromInt(0xDEAD)` → `"u8@dead"` |
| `{any}`  | 任意类型（包括结构体）                                | 任意                          | `.{"hello", 42}`                    |
|  `{B}`   | 内存大小（十进制单位）                                | 整数                          | `1024` → `"1.024kB"`                |
|  `{Bi}`  | 内存大小（二进制单位）                                | 整数                          | `1024` → `"1KiB"`                   |
| `{d:5}`  | 宽度5，右对齐（默认）                                 | 整数                          | `.{42}` → `"   42"`                 |
| `{d:<5}` | 宽度5，左对齐                                         | 整数                          | `.{42}` → `"42   "`                 |
| `{d:^5}` | 宽度5，居中                                           | 整数                          | `.{42}` → `" 42  "`                 |
| `{0>5}`  | 零填充，宽度5                                         | 整数                          | `.{42}` → `"00042"`                 |
| `{d:.2}` | 浮点数精度2位                                         | 浮点数                        | `.{3.14159}` → `"3.14"`             |

---

## 二、占位符详细说明

### 1. `{}` - 万能占位符

```zig
std.debug.print("{}", .{42});        // "42"
std.debug.print("{}", .{3.14});     // "3.14"
std.debug.print("{}", .{null});     // "null"
std.debug.print("{}", .{true});     // "true"
std.debug.print("{}", .{"hello"});  // "因为推断不唯一, 所以会报错"

const Color = enum { red, green, blue };
const c = Color.red;
std.debug.print("{}", .{c});  // "Color.red"
```

**特性：**
- 自动检测类型，智能选择最合适的格式
- 对自定义类型会调用其 `format` 方法
- 对枚举会打印枚举名称而非值


---

### 2. `{s}` - 字符串专用

```zig
// 标准切片
const name: []const u8 = "Zig";
std.debug.print("{s}", .{name});  // "Zig"

// C 风格空终止字符串
const c_str: [*:0]const u8 = "Hello";
std.debug.print("{s}", .{c_str});  // "Hello"

// 字节切片
const bytes: []const u8 = &[_]u8{ 'A', 'B', 'C' };
std.debug.print("{s}", .{bytes});  // "ABC"
```

**⚠️ 注意：** `{s}` 要求输入必须是合法的 UTF-8 字符串，如果传入二进制数据可能会在终端显示乱码。

---

### 3. `{d}` - 十进制格式

```zig
// 整数
std.debug.print("{d}", .{42});      // "42"
std.debug.print("{d}", .{-100});   // "-100"

// 浮点数
std.debug.print("{d}", .{3.14159}); // "3.14159"

// 大整数（自动处理）
std.debug.print("{d}", .{9223372036854775807});  // "9223372036854775807"
```

---

### 4. 十六进制 `{x}` 和 `{X}`

```zig
// 小写十六进制
std.debug.print("{x}", .{255});  // "ff"
std.debug.print("{x}", .{0xDEADBEEF});  // "deadbeef"

// 大写十六进制
std.debug.print("{X}", .{255});  // "FF"
std.debug.print("{X}", .{0xDEADBEEF});  // "DEADBEEF"

// 字符串转十六进制（需要 std.fmt.fmtSliceHexLower）
std.debug.print("{x}", .{std.fmt.fmtSliceHexLower("ABC")});  // "414243"
std.debug.print("{X}", .{std.fmt.fmtSliceHexUpper("ABC")});  // "414243"
```

---

### 5. 二进制 `{b}` 和八进制 `{o}`

```zig
// 二进制
std.debug.print("{b}", .{10});   // "1010"
std.debug.print("{b}", .{255});  // "11111111"

// 八进制
std.debug.print("{o}", .{8});   // "10"
std.debug.print("{o}", .{64});  // "100"

// 前缀可以自己加
std.debug.print("0b{b}", .{10});  // "0b1010"
std.debug.print("0o{o}", .{64});  // "0o100"
```

---

### 6. ASCII 字符 `{c}`

```zig
// 数字转 ASCII
std.debug.print("{c}", .{65});  // "A"
std.debug.print("{c}", .{97});  // "a"
std.debug.print("{c}", .{48});  // "0"

// 转义字符
std.debug.print("{c}{c}{c}", .{ '\n', '\t', '\r' });  // 换行、制表符、回车

// 警告：超出 0-255 范围会导致编译错误
// std.debug.print("{c}", .{256});  // ❌ 编译错误
```

---

### 7. 科学计数法 `{e}` 和 `{E}`

```zig
// 小写 e
std.debug.print("{e}", .{3.14159});    // "3.14159e0"
std.debug.print("{e}", .{1234.5});     // "1.2345e3"
std.debug.print("{e}", .{0.001234});   // "1.234e-3"

// 大写 E
std.debug.print("{E}", .{3.14159});    // "3.14159E0"
std.debug.print("{E}", .{1234.5});     // "1.2345E3"
```

---

### 8. 指针地址 `{*}`

```zig
var x: u32 = 42;
const ptr = &x;

// 打印指针地址
std.debug.print("{*}", .{ptr});       // "u32@7fffffffd8fc"

// 任意指针
const ptr2: *u8 = @ptrFromInt(0xDEADBEEF);
std.debug.print("{*}", .{ptr2});     // "u8@deadbeef"
```

---

### 9. 内存大小 `{B}` 和 `{Bi}`

```zig
// 十进制单位（1000 进制）
std.debug.print("{B}", .{1});                           // "1B"
std.debug.print("{B}", .{1000});                       // "1kB"
std.debug.print("{B}", .{1000 * 1000});                // "1MB"
std.debug.print("{B}", .{1500});                       // "1.5kB"

// 二进制单位（1024 进制）
std.debug.print("{Bi}", .{1});                          // "1B"
std.debug.print("{Bi}", .{1024});                      // "1KiB"
std.debug.print("{Bi}", .{1024 * 1024});               // "1MiB"
std.debug.print("{Bi}", .{1024 * 1024 * 1024});        // "1GiB"

// 大数值自动选择合适单位
std.debug.print("{B}", .{1234567890});  // "1.234567890GB"
std.debug.print("{Bi}", .{1234567890}); // "1.150057724GiB"
```

**实用场景：**
```zig
const file_size: u64 = 2048;
std.debug.print("File size: {Bi}\n", .{file_size});  // "File size: 2KiB"
```

---

## 三、高级格式化选项

### 宽度、对齐、填充

Zig 的格式化支持类似 Python 的格式化语法：

```
{[width]}
{[alignment]}
{[fill][alignment][width]}
```

#### 1. 固定宽度

```zig
// 右对齐（默认）
std.debug.print("[{d:5}]", .{42}); // "[   42]"
std.debug.print("[{s:5}]", .{"hi"}); // "[   hi]"
// 左对齐
std.debug.print("[{d:<5}]", .{42}); // "[42   ]"
std.debug.print("[{s:<5}]", .{"hi"}); // "[hi   ]"
// 居中对齐
std.debug.print("[{d:^5}]", .{42}); // "[ 42  ]"
std.debug.print("[{s:^6}]", .{"hi"}); // "[  hi  ]"
```

#### 2. 自定义填充字符

```zig
// 用零填充
std.debug.print("[{d:0>5}]", .{42}); // "[00042]"
std.debug.print("[{s:0>10}]", .{"Zig"}); // "[0000000Zig]"
// 用点填充
std.debug.print("[{d:.>5}]", .{42}); // "[...42]"
std.debug.print("[{s:.<5}]", .{"hi"}); // ["hi..."]
// 用星号填充
std.debug.print("[{s:*>10}]", .{"hello"}); // "[*****hello]"
```

#### 3. 浮点数精度

```zig
const pi = 3.14159265359;

// 默认精度
std.debug.print("{}", .{pi});           // "3.14159265359"

// 指定小数位数
std.debug.print("{d:.2}", .{pi});       // "3.14"
std.debug.print("{d:.4}", .{pi});       // "3.1416"
std.debug.print("{d:.0}", .{pi});       // "3"

// 科学计数法精度
std.debug.print("{e:.2}", .{pi});       // "3.14e0"
std.debug.print("{e:.4}", .{pi});       // "3.1416e0"
```
---

### 组合示例

```zig
// 表格格式化
const name = "Zig";
const score = 95;
std.debug.print("| {s:10} | {d:5} |\n", .{name, score});
// "| Zig        |    95 |"

// 对齐数字
const ids = [_]u32{ 1, 2, 10, 100, 1000 };
for (ids) |id| {
    std.debug.print("ID: {d:4}\n", .{id});
}
// ID:    1
// ID:    2
// ID:   10
// ID:  100
// ID: 1000

// 自定义填充 + 对齐 + 宽度
std.debug.print("Header: {s:<=30}\n", .{"Important"});
// "Header: Important====================="
std.debug.print("Header: {s:=>30}\n", .{"Important"});
// "Header: ====================Important"
```

---

## 四、特殊格式化类型

### 数组和切片

```zig
// 整数数组
const arr = [_]i32{ 1, 2, 3, 4, 5 };
std.debug.print("{any}", .{arr});  // "{ 1, 2, 3, 4, 5 }"

// 切片
const slice = arr[1..4];
std.debug.print("{any}", .{slice});  // "{ 2, 3, 4 }"

// 嵌套结构
const matrix = [_][3]i32{
    .{ 1, 2, 3 },
    .{ 4, 5, 6 },
};
std.debug.print("{any}", .{matrix});
// "{ { 1, 2, 3 }, { 4, 5, 6 } }"
```

---

### Optionals（可选值）

```zig
// 有值
const maybe_num: ?i32 = 42;
std.debug.print("{?}", .{maybe_num});  // "Optional(i32){42}"

// 无值
const no_num: ?i32 = null;
std.debug.print("{?}", .{no_num});  // "Optional(i32){null}"

// Union（联合体）
const Value = union(enum) {
    int: i32,
    float: f32,
    text: []const u8,
};

const v = Value{ .float = 3.14 };
std.debug.print("{}", .{v});  // "Value.float(3.14)"
```

---

### Error Sets（错误集合）

```zig
const MyError = error{
    NotFound,
    PermissionDenied,
    InvalidInput,
};

const err = MyError.NotFound;
std.debug.print("{}", .{err});  // "error.NotFound"
```

---

## 六、格式化技巧与魔法

### 技巧 1：转义大括号

```zig
// 在格式化字符串中打印字面量 {}
std.debug.print("{{This is literal braces}}\n", .{});
// "{This is literal braces}"

// 只转义一个
std.debug.print("{{Brace}} and {s}\n", .{"value"});
// "{Brace} and value"
```

---

### 技巧 2：条件格式化

```zig
const mode: bool = true;
std.debug.print(
    "Status: {s}\n",
    .{if (mode) "enabled" else "disabled"},
);
// "Status: enabled"
```

---

### 技巧 3：格式化枚举

```zig
const Status = enum {
    unknown,
    active,
    inactive,

    // 自定义格式化
    pub fn format(
        self: Status,
        writer: anytype,
    ) !void {
        const text = switch (self) {
            .unknown => "❓",
            .active => "✅",
            .inactive => "❌",
        };
        try writer.print("{s}", .{text});
    }
};

const s = Status.active;
std.debug.print("Status: {f}\n", .{s});  // "Status: ✅"
```

---

### 技巧 4：调试友好的格式化

```zig
const Config = struct {
    port: u16,
    debug: bool,
    log_path: []const u8,

    pub fn format(
        self: Config,
        writer: anytype,
    ) !void {
        try writer.print(
            \\Config {{
            \\  port: {d}
            \\  debug: {any}
            \\  log_path: "{s}"
            \\}}
        ,
            .{ self.port, self.debug, self.log_path },
        );
    }
};


const cfg = Config{ .port = 8080, .debug = true, .log_path = "/var/log/zig.log" };
std.debug.print("{f}\n", .{cfg});
// Config {
//   port: 8080
//   debug: true
//   log_path: "/var/log/zig.log"
// }
```
