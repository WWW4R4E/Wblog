---
date: "2026-10-22"
category: "Zig"
read_time: "8分钟阅读"
title: "API 文档生成指南"
excerpt: "Zig 内置文档生成系统，从源码中的 /// 注释自动提取 API 文档并生成 HTML 页面。"
tags: ["Zig", "文档", "工具"]
---

# API 文档生成指南

Zig 内置文档生成系统，从源码中的 `///` 注释自动提取 API 文档，生成 HTML 页面。

---

## 生成文档

```bash
zig build docs
```

输出位置：`zig-out/doc/`

```
zig-out/doc/
├── index.html      ← 入口页面
├── main.js         ← 交互逻辑
├── main.wasm       ← 搜索等功能的 WebAssembly
└── sources.tar     ← 源码归档（用于跳转到源码）
```

用浏览器打开 `zig-out/doc/index.html` 即可查看。

---

## 写文档注释

### 文件级注释（`//!`）

文件顶部的 `//!` 注释会成为文档的模块概述：

```zig
//! # StarSorter 核心库
//!
//! 基于 Zig 的 GitHub REST API v3 封装库，支持 C ABI 导出。
//!
//! ## Zig 用法
//! ```
//! const core = @import("core");
//! var gh = core.github.Client.init(allocator, io, token);
//! ```
//!
//! ## C / FFI 用法
//! ```c
//! gh_client_t* client = gh_init("token", "http://127.0.0.1:7897");
//! ```
```

支持 Markdown 语法：
- 标题 `#` / `##` / `###`
- 代码块 ` ```zig ... ``` `
- 列表、表格、链接、粗体、斜体

### 类型/函数注释（`///`）

每个 `pub` 类型、enum、函数、const 前面加 `///`：

```zig
/// GitHub 用户账号信息。
pub const GitHubUser = struct {
    login: []const u8,
    /// 用户全名，可能为 null。
    name: ?[]const u8 = null,
};

/// 创建 GitHub 客户端实例。
/// `token` — GitHub Personal Access Token（必填）。
/// `proxy_url` — 可选代理地址，传 null 为直连。
export fn gh_init(token: [*:0]const u8, proxy_url: ?[*:0]const u8) ?*ClientWrapper {
```

### 结构体字段注释

在字段行上方加 `///` 即可：

```zig
pub const RateLimitItem = struct {
    /// 每小时总限额（如 5000）。
    limit: u32,
    /// 当前剩余请求数。
    remaining: u32,
    /// 重置时间的 Unix 时间戳（秒）。
    reset: u64,
    /// 本小时内已使用的请求数。
    used: u32,
};
```

### 枚举变体注释

```zig
/// C ABI 函数返回的错误码。
pub const GhError = enum(c_int) {
    /// 成功。
    success = 0,
    /// 网络连接失败，请检查网络/代理。
    network_error = -1,
    /// 认证失败，请检查 GITHUB_TOKEN。
    unauthorized = -2,
    /// 资源不存在（404）。
    not_found = -3,
};
```

---

## build.zig 配置说明

```zig
// 创建一个编译对象用于文档生成
const docs_obj = b.addObject(.{
    .name = "github_stars_docs",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    }),
});

// 将生成的文档安装到 zig-out/doc/
const docs_install = b.addInstallDirectory(.{
    .source_dir = docs_obj.getEmittedDocs(),
    .install_dir = .prefix,
    .install_subdir = "doc",
});

// 注册 docs 命令
const docs_step = b.step("docs", "Generate API documentation");
docs_step.dependOn(&docs_install.step);
```

关键点：
- `addObject` 创建编译对象，**不链接成可执行文件**，但会运行编译和文档生成
- `getEmittedDocs()` 返回编译过程中生成的文档目录
- `addInstallDirectory` 把文档目录复制到 `zig-out/doc/`
- 文档入口是 `src/root.zig`，它递归包含所有 `pub` 导出

---

## 哪些内容出现在文档中

| 可见性 | 是否出现在文档 |
|--------|---------------|
| `pub` | ✅ 是 |
| `pub const` / `pub fn` / `pub struct` | ✅ 是 |
| 无 `pub`（模块内部） | ❌ 否 |
| `export` 函数 | ✅ 是（C ABI 导出也会显示） |

文档会展示：
- 类型定义（struct / enum / union）
- 函数签名（包括 `export fn`）
- 泛型参数（如 `SearchResults(T)`）
- 字段和变体注释
- 源码跳转链接

---

## 注意事项

1. **注释必须紧挨着被注释项**，中间不能有空行
2. **第一句最好简短**（在概览中会截断展示）
3. **Markdown 代码块指定语言**（` ```zig ` 或 ` ```c `）
4. **参数说明**用反引号包裹参数名：`` `token` — 描述 ``
5. **文档只在 Debug 模式编译时生成**（Release 模式也会，但格式略有不同）
6. **中英文皆可**，本项目使用中文以便目标用户阅读
