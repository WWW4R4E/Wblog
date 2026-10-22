---
date: "2026-10-22"
category: "Zig"
read_time: "5分钟阅读"
title: "Zig std.http.Client 代理异常排查"
excerpt: "Zig 0.16 std.http.Client 通过 CONNECT 隧道后缺少 TLS 包裹导致请求被重置的排查记录。"
tags: ["Zig", "HTTP", "代理", "排错"]
---

\#### 🕳 坑3（最要命）：Zig 0.16 CONNECT 隧道后缺少 TLS 包裹



这是最难排查的。`std.http.Client` 的 `connectProxied()` 在建立 CONNECT 隧道后\*\*直接返回 `.plain` 连接的原始 TCP 流\*\*，没有做 TLS 包裹。导致后续 `sendBodiless()` 通过 `connection.writer()`（对 `.plain` 返回原始流写入器）把 HTTP 请求以明文发进隧道，GitHub 收到非 TLS 数据直接 `CONNECTION\_RESET`。



而 `curl.exe` 正常工作，是因为 curl 在 CONNECT 隧道建立后\*\*正确地在隧道上做了 TLS 握手\*\*。



\*\*解决：\*\* 在 `initProxies()` 中强制设置 `.supports\_connect = false`，让 Zig 改用 HTTP 代理模式（发送绝对 URI 请求，代理自己处理 TLS）：



```zig

proxy.\* = .{

&#x20;   .protocol = .plain,

&#x20;   .host = host,

&#x20;   .port = port,

&#x20;   .supports\_connect = false,  // ← 关键！绕过 Zig 0.16 的 CONNECT 隧道 bug

};

```



此时请求行变成 `GET https://api.github.com/user HTTP/1.1`（而非 `GET /user HTTP/1.1`），代理收到后自己去连 GitHub 443 端口做 TLS 并转发。



\#### 🕳 坑4：Debug 模式必然打印 Zig 错误栈



Zig 0.16 Debug 模式下，所有 `try` 的 error return trace 都会打印到 stderr，无法从代码层面屏蔽。我们的 `requestBytes` 中所有 `catch { return error.NetworkError; }` 只能确保\*\*应用层的返回码是友好的\*\*，但不阻止 std 库内部的 trace 输出。



```bash

\# 解决方案：用 ReleaseSafe 模式编译

zig build run -Doptimize=ReleaseSafe



\# ReleaseSafe 仍保留边界检查但不会打印 error return trace

```



\#### 🕳 坑5：`$env` 只影响当前终端



```powershell

\# 这个命令把脚本写入 $PROFILE，但当前终端不会生效：

Add-Content $PROFILE "`$env:ALL\_PROXY='http://127.0.0.1:7897'"



\# 必须：

\#   1. 关掉终端重开（$PROFILE 自动执行），或

\#   2. 直接在当前终端手打一遍

$env:ALL\_PROXY="http://127.0.0.1:7897"

```



\#### 🕳 坑6：Windows 上 `STATUS\_CONNECTION\_RESET` 映射为 `error.Unexpected`



Zig 0.16 的 Windows I/O 层将 `NTSTATUS=0xc000020d (CONNECTION\_RESET)` 映射为 `error.Unexpected` 而非 `error.ConnectionResetByPeer`。所以 `friendlyError` 中需要同时覆盖 `error.Unexpected`。



