---
date: "2026-10-22"
category: "Zig"
read_time: "25分钟阅读"
title: "Zig 标准库 HTTP 客户端解析"
excerpt: "基于 Zig 标准库 std/http/Client.zig 的源码解析，涵盖连接池、TLS、代理、重定向与压缩等机制。"
tags: ["Zig", "HTTP", "标准库"]
---

# Zig 标准库 HTTP 客户端 (`std.http.Client`) 解析

> 基于 Zig 标准库 `std/http/Client.zig` 分析，提供了完整的 HTTP(S) 客户端实现，支持连接池、TLS、代理、重定向、压缩等特性。

***

## 目录

- [架构概览](#架构概览)
- [核心类型](#核心类型)
- [连接管理](#连接管理)
- [请求生命周期](#请求生命周期)
- [高级功能](#高级功能)
- [API 参考](#api-参考)

***

## 架构概览

```
Client
 ├── ConnectionPool          ← 连接池（LRU 缓存）
 │    ├── used               ← 正在使用的连接
 │    └── free               ← 空闲可复用的连接
 ├── ca_bundle               ← TLS 根证书
 ├── http_proxy / https_proxy ← 代理配置
 │
 ├── connect()               ← 连接（自动复用/代理）
 ├── request()               ← 创建请求
 └── fetch()                 ← 一键请求
```

### 设计原则

- **连接复用**：通过 `ConnectionPool` 实现 LRU 缓存，相同 host:port:protocol 复用 TCP/TLS 连接
- **线程安全**：连接池操作使用 `Mutex/RwLock` 保护，但单个 `Request` 不是线程安全的
- **零拷贝设计**：读写缓冲区与连接对象在单次分配中连续布局
- **TLS 可选**：通过 `std.options.http_disable_tls` 编译时禁用

***

## 核心类型

### `Client`

```zig
pub const Client = struct {
    allocator: Allocator,
    io: Io,

    ca_bundle: std.crypto.Certificate.Bundle,
    tls_buffer_size: usize,
    ssl_key_log: ?*std.crypto.tls.Client.SslKeyLog,
    now: ?Io.Timestamp,

    connection_pool: ConnectionPool,
    read_buffer_size: usize,   // 默认 8192
    write_buffer_size: usize,  // 默认 1024

    http_proxy: ?*Proxy,
    https_proxy: ?*Proxy,
};
```

| 字段                  | 说明                  |
| ------------------- | ------------------- |
| `allocator`         | 所有分配使用的分配器，必须线程安全   |
| `io`                | I/O 抽象层，用于打开 TCP 连接 |
| `ca_bundle`         | TLS 根证书存储           |
| `tls_buffer_size`   | TLS 读写缓冲区大小         |
| `ssl_key_log`       | SSL 密钥日志（调试用，可解密流量） |
| `now`               | 证书过期判断的时间戳          |
| `connection_pool`   | 连接池                 |
| `read_buffer_size`  | 每个连接的读缓冲区           |
| `write_buffer_size` | 每个连接的写缓冲区           |
| `http_proxy`        | HTTP 代理（指向外部内存）     |
| `https_proxy`       | HTTPS 代理（指向外部内存）    |

### `Protocol`

```zig
pub const Protocol = enum {
    plain,  // HTTP, WS
    tls,    // HTTPS, WSS
};
```

`fromScheme` 支持 `http`、`ws` → `plain`，`https`、`wss` → `tls`。

### `Connection`

表示一个 TCP/TLS 连接，内部有两种变体：

| 变体                 | 说明                                  |
| ------------------ | ----------------------------------- |
| `Connection.Plain` | 纯文本 HTTP 连接                         |
| `Connection.Tls`   | TLS 加密连接，内含 `std.crypto.tls.Client` |

连接的内存布局是**连续分配**的：对象头 + host 缓冲 + 读写缓冲。

关键方法：

```zig
pub fn writer(c: *Connection) *Writer    // HTTP 协议写入端
pub fn reader(c: *Connection) *Reader    // HTTP 协议读取端
pub fn flush(c: *Connection) void        // 刷新缓冲区
pub fn end(c: *Connection) void          // 发送 close_notify（TLS）
pub fn destroy(c: *Connection, io: Io)   // 关闭 socket 并释放内存
pub fn host(c: *Connection) HostName     // 获取主机名
```

### `Response`

```zig
pub const Response = struct {
    request: *Request,
    head: Head,
};
```

`Response.Head` 负责解析 HTTP 响应头：

| 字段                    | 说明                    |
| --------------------- | --------------------- |
| `bytes`               | 原始响应头字节               |
| `version`             | HTTP 版本（1.0/1.1）      |
| `status`              | 状态码（`http.Status` 枚举） |
| `reason`              | 原因短语                  |
| `location`            | 重定向 URL               |
| `content_type`        | Content-Type          |
| `content_disposition` | Content-Disposition   |
| `keep_alive`          | 是否保持连接                |
| `content_length`      | 内容长度                  |
| `transfer_encoding`   | 传输编码                  |
| `content_encoding`    | 内容编码（压缩方式）            |

方法：

```zig
pub fn reader(response, transfer_buffer) *Reader            // 获取响应体读取器
pub fn readerDecompressing(response, tb, decompress, db) *Reader  // 解压缩读取器
pub fn bodyErr(response) ?http.Reader.BodyError              // 获取读取错误
pub fn iterateTrailers(response) http.HeaderIterator         // 遍历尾部头
```

### `Request`

```zig
pub const Request = struct {
    uri: Uri,
    client: *Client,
    connection: ?*Connection,
    reader: http.Reader,
    keep_alive: bool,
    method: http.Method,
    version: http.Version,
    transfer_encoding: TransferEncoding,
    redirect_behavior: RedirectBehavior,
    handle_continue: bool,
    headers: Headers,
    extra_headers: []const http.Header,
    privileged_headers: []const http.Header,
};
```

***

## 连接管理

### `ConnectionPool`

LRU 缓存，管理可复用的 TCP/TLS 连接：

```zig
pub const ConnectionPool = struct {
    used: std.DoublyLinkedList,   // 使用中的连接
    free: std.DoublyLinkedList,   // 空闲连接
    free_len: usize,
    free_size: usize,             // 默认 32
};
```

匹配条件（`Criteria`）：`host` + `port` + `protocol`。

关键行为：

- **查找**：从 `free` 尾部遍历，匹配协议→端口→主机名（域名不区分大小写）
- **释放**：若连接标记 `closing` 或池满则销毁；代理连接插入头部（优先使用直连）
- **调整大小**：`resize()` 可缩小空闲池

### 连接生命周期

```
connect() → findConnection() 命中? → 返回已有连接
                                     ↓ 未命中
                        TCP connect → TLS handshake → addUsed()
                                     ↓
                        使用中 (used)
                                     ↓
                        release() → 空闲 (free) 或 销毁
```

### 代理支持

```zig
pub const Proxy = struct {
    protocol: Protocol,
    host: HostName,
    authorization: ?[]const u8,
    port: u16,
    supports_connect: bool,
};
```

- **HTTP 代理**：`http_proxy` 环境变量
- **HTTPS 代理**：`https_proxy` 环境变量
- **CONNECT 隧道**：通过 `connectProxied()` 建立
- **自动回退**：CONNECT 失败后降级为普通 HTTP 代理

`initDefaultProxies()` 从环境变量自动加载代理配置：

```
http_proxy / HTTP_PROXY / all_proxy / ALL_PROXY  → http_proxy
https_proxy / HTTPS_PROXY / all_proxy / ALL_PROXY → https_proxy
```

### ⚠️ Zig 0.16 CONNECT 隧道 + TLS 缺陷（重要）

这是 Zig 0.16 `std.http.Client` 的一个确认缺陷，花了一天时间排查。

#### 问题描述

当 `Proxy.supports_connect = true` 时，`connect()` 调用 `connectProxied()` 建立 CONNECT 隧道。但 `connectProxied()` 的实现有缺陷：

```zig
// connectProxied 的简化流程
fn connectProxied(client, proxy, host, port) !*Connection {
    // 1. 用 .plain 协议连接代理（正确）
    const connection = client.connectTcpOptions(.{
        .host = proxy.host,    // 127.0.0.1
        .port = proxy.port,    // 7897
        .protocol = .plain,    // HTTP 明文
    });

    // 2. 发送 CONNECT 请求（正确）
    request(.CONNECT, ...);
    sendBodiless();
    const response = receiveHead(...);
    if (response.head.status != .ok) return error.ConnectionRefused;

    // 3. 返回连接 ← 🐛 BUG 就在这里！
    return connection;
    // connection.protocol == .plain
    // 没有 TLS 包裹！
}
```

返回的连接 `protocol = .plain`，意味着 `Connection.writer()` / `Connection.reader()` 返回的是**原始 TCP 流**的读写器，不经过 TLS 加解密。

后续 `sendBodiless()` 写入的 HTTP 请求被**以明文形式**通过 CONNECT 隧道发送到 GitHub。GitHub 期望的是 TLS 握手，收到明文后直接关闭连接（`CONNECTION_RESET`）。

#### 错误表现

```
error.Unexpected NTSTATUS=0xc000020d (CONNECTION_RESET)
在 std.crypto.tls.Client.init 中 peek TLS record header 失败
```

代理本身是通的（`curl -x` 正常），但 Zig 的 HTTPS 请求总是被 reset。

#### 正确的行为应该是什么

```
[Client] --明文CONNECT--> [Proxy] --TCP tunnel--> [GitHub:443]
[Client] --TLS握手通过隧道--> [Proxy] --TCP tunnel--> [GitHub:443]    ← 缺少这一步
[Client] --加密HTTP--> [Proxy] --TCP tunnel--> [GitHub:443]
```

CONNECT 隧道建立后，客户端**必须在隧道上主动发起 TLS 握手**（通过 `Connection.Tls.create`），但 `connectProxied` 没做这个步骤就直接返回了。

#### 解决办法

设置 `supports_connect = false`，强迫 Zig 走 HTTP 代理模式。

```
[Client] --"GET https://api.github.com/user HTTP/1.1"--> [Proxy] --TLS--> [GitHub]
```

此时请求行包含完整 URI，代理收到后自己处理 TLS 连接目标，返回明文响应给客户端。绕过 Zig 的 TLS 包裹步骤。

要求代理支持 HTTP 绝对 URI 转发（现代代理软件如 Clash、v2ray 都支持）。

### `initDefaultProxies` 的注意事项

`initDefaultProxies` 内部读取环境变量时按固定顺序检查：

```zig
// HTTPS 代理检查顺序：
"https_proxy" → "HTTPS_PROXY" → "all_proxy" → "ALL_PROXY"

// HTTP 代理检查顺序：
"http_proxy" → "HTTP_PROXY" → "all_proxy" → "ALL_PROXY"
```

在 Windows 上，`std.process.Environ.Map` 是大小写敏感的。如果用户设的是 `$env:HTTPS_PROXY`（大写），且 Zig 内部先查小写 `"https_proxy"` 不匹配，理论上会继续查大写 `"HTTPS_PROXY"`，但实测有时会跳过所有大写变体。

**本项目实现：** 在 `GitHubClient.initProxies` 中手动解析，大写变体放前面优先匹配，明确绕过 `initDefaultProxies`。

***

## 请求生命周期

### 完整示例

```zig
const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client: std.http.Client = .{
        .allocator = allocator,
        .io = .{ .mode = .evented },  // 或 .blocking
    };
    defer client.deinit();

    // 1. 解析 URI
    const uri = try std.Uri.parse("https://httpbin.org/post");

    // 2. 创建请求
    var req = try client.request(.POST, uri, .{});
    defer req.deinit();

    // 3. 发送请求体
    req.transfer_encoding = .{ .content_length = "hello".len };
    var body = try req.sendBodyUnflushed(&.{});
    try body.writer.writeAll("hello");
    try body.end();
    try req.connection.?.flush();

    // 4. 接收响应头
    var redirect_buffer: [8192]u8 = undefined;
    var response = try req.receiveHead(&redirect_buffer);

    // 5. 读取响应体
    var transfer_buf: [1024]u8 = undefined;
    const reader = response.reader(&transfer_buf);
    const body_data = try reader.readAllAlloc(allocator, 1024 * 1024);
    defer allocator.free(body_data);

    std.debug.print("status: {}\n", .{response.head.status});
    std.debug.print("body: {s}\n", .{body_data});
}
```

### 分步说明

#### 1. 发送请求头

```zig
// 无请求体（GET/HEAD/DELETE 等）
try req.sendBodiless();

// 有请求体（POST/PUT 等）
req.transfer_encoding = .{ .content_length = body.len };
var bw = try req.sendBodyUnflushed(body, buffer);
try bw.writer.writeAll(body);
try bw.end();
try req.connection.?.flush();

// 或一步到位
try req.sendBodyComplete(body);
```

发送请求头时自动处理：

- 请求行（方法 + URI + 版本）
- `Host`、`Authorization`、`User-Agent`、`Connection`、`Accept-Encoding`、`Content-Type`
- `extra_headers` 自定义头
- `Proxy-Authorization`（代理场景）
- 传输编码（`chunked` / `content-length`）

#### 2. 接收响应

```zig
var redirect_buffer: [8192]u8 = undefined;
var response = try req.receiveHead(&redirect_buffer);
```

`receiveHead` 自动处理：

- 100 Continue（如果 `handle_continue` 为 true）
- 重定向（根据 `redirect_behavior` 配置自动跟随）
- 连接的 `keep-alive` 状态

#### 3. 读取响应体

```zig
// 原始读取
const reader = response.reader(&transfer_buffer);

// 自动解压缩
var decompress: http.Decompress = undefined;
const reader = response.readerDecompressing(
    &transfer_buffer,
    &decompress,
    decompress_buffer,
);

// 流式写入
_ = reader.streamRemaining(writer);
```

***

## 高级功能

### 一键请求 (`fetch`)

```zig
const result = try client.fetch(.{
    .location = .{ .url = "https://api.example.com/data" },
    .method = .GET,
    .response_writer = &writer,  // 可选：写入响应体
});
```

自动处理：连接复用、TLS、代理、重定向、解压缩。

### 自定义请求头

```zig
var req = try client.request(.GET, uri, .{
    .headers = .{
        .host = .{ .override = "example.com" },
        .user_agent = .{ .override = "MyApp/1.0" },
        .authorization = .{ .override = "Bearer token123" },
        .accept_encoding = .omit,
        .connection = .{ .override = "close" },
    },
    .extra_headers = &.{
        .{ .name = "x-custom", .value = "value" },
    },
});
```

### 重定向控制

```zig
// 自动跟随最多 5 次重定向
const options = .{ .redirect_behavior = @enumFromInt(5) };

// 禁止重定向
const options = .{ .redirect_behavior = .not_allowed };

// 手动处理重定向
const options = .{ .redirect_behavior = .unhandled };
```

### 连接池调优

```zig
client.read_buffer_size = 16384;
client.write_buffer_size = 4096;
client.connection_pool.free_size = 64;
client.tls_buffer_size = 32768;
```

### 代理配置

```zig
// 手动设置
var proxy = Proxy{
    .protocol = .plain,
    .host = .{ .bytes = "proxy.example.com" },
    .port = 8080,
    .authorization = null,
    .supports_connect = true,
};
client.http_proxy = &proxy;

// 环境变量自动加载
try client.initDefaultProxies(arena, &env_map);
```

### 基本认证

```zig
// URI 中包含认证信息
const uri = try Uri.parse("https://user:pass@api.example.com/data");
// 请求会自动发送 Authorization: Basic <base64>

// 或使用 basic_authorization 工具函数
const encoded = basic_authorization.value(uri, buffer);
```

***

## API 参考

### Client 方法

| 方法                                  | 说明                | 线程安全 |
| ----------------------------------- | ----------------- | ---- |
| `deinit()`                          | 释放所有资源            | 是    |
| `connectTcp(host, port, protocol)`  | 建立 TCP/TLS 连接     | 是    |
| `connectTcpOptions(options)`        | 带选项的连接            | 是    |
| `connectUnix(path)`                 | 连接 Unix 域套接字      | 是    |
| `connectProxied(proxy, host, port)` | 通过代理 CONNECT 隧道连接 | 是    |
| `connect(host, port, protocol)`     | 自动选择直连/代理         | 是    |
| `request(method, uri, options)`     | 创建 HTTP 请求        | 是    |
| `fetch(options)`                    | 一键 HTTP 请求        | 是    |
| `initDefaultProxies(arena, env)`    | 从环境变量加载代理         | 否    |

### Request 方法

| 方法                             | 说明                 |
| ------------------------------ | ------------------ |
| `deinit()`                     | 释放请求并将连接归还池        |
| `sendBodiless()`               | 发送无体请求并刷新          |
| `sendBodilessUnflushed()`      | 发送无体请求不刷新          |
| `sendBody(buffer)`             | 发送请求头和体并刷新         |
| `sendBodyComplete(body)`       | 发送完整请求（头+体）        |
| `sendBodyUnflushed(buffer)`    | 发送请求头返回 BodyWriter |
| `receiveHead(redirect_buffer)` | 接收响应头              |

### Response 方法

| 方法                                        | 说明       |
| ----------------------------------------- | -------- |
| `reader(transfer_buffer)`                 | 获取响应体读取器 |
| `readerDecompressing(tb, decompress, db)` | 获取解压缩读取器 |
| `bodyErr()`                               | 获取读取错误   |
| `iterateTrailers()`                       | 遍历尾部头    |

### 错误处理

```
Client 相关: OutOfMemory, TlsInitializationFailed
Request 相关: HttpHeadersInvalid, HttpHeadersOversize, HttpChunkInvalid,
              HttpRedirectLocationMissing, HttpContentEncodingUnsupported,
              TooManyHttpRedirects, RedirectRequiresResend
读取错误: 通过 Connection.getReadError() 获取详细错误
```

注意：`receiveHead` 失败时连接标记为 `closing`，不会归还连接池。

***

## 内部实现细节

### 内存布局

连接对象采用**连续分配**策略，单次 `alignedAlloc` 分配完整内存块：

```
Plain: [Plain 对象头][host 缓冲][读缓冲][写缓冲]
Tls:   [Tls 对象头][host 缓冲][TLS 读缓冲][TLS 写缓冲][Socket 写缓冲][Socket 读缓冲]
```

这种设计减少了分配次数和指针追踪，提高了缓存局部性。

### 协议协商

`Connection.writer()` 和 `Connection.reader()` 根据协议类型返回不同的 I/O 接口：

- `plain` → 直接使用 `stream_writer` / `stream_reader`
- `tls` → 通过 TLS client 的加密/解密层

### 解压缩支持

`Response.Head.parse` 解析 `Transfer-Encoding` 和 `Content-Encoding` 时支持：

- 传输编码：`chunked`
- 内容编码：`gzip`、`deflate`、`zstd`、`compress`、`identity`

`Content-Encoding` 和 `Transfer-Encoding` 可以在同一行以逗号分隔（如 `deflate, chunked`）。

### 连接释放策略

`Request.deinit()` 根据 `reader.state` 决定连接行为：

| 状态              | 行为                |
| --------------- | ----------------- |
| `ready`         | 连接可复用             |
| `received_head` | 尝试丢弃剩余响应体，成功则可复用  |
| 其他              | 标记 `closing`，销毁连接 |

