---
date: "2026-04-10"  
category: "技术"  
read_time: "2分钟阅读"  
title: "Zig CLI 基本命令"  
excerpt: "介绍了zig最常用的基本命令，并且补充了使用fetch的常见问题及解决方案"  
tags: ["Zig", "构建系统", "教程", "笔记"]  
---



# Zig CLI 基本命令

## 概述

Zig 的命令行接口设计简洁而强大，通过 `zig --help` 可以查看所有可用命令。

```bash
zig --help
```

### Zig 命令分类

| 类别   | 命令                              |
| ------ | --------------------------------- |
| 构建   | `build`, `test`, `run`            |
| 开发   | `fmt`, `ast-check`, `translate-c` |
| 工具   | `ar`, `objcopy`, `ld`             |
| 信息   | `version`, `env`, `targets`       |
| 包管理 | `fetch`, `init`                   |

## 基本命令

### `zig build`

构建项目，支持多种步骤和选项。

**可用步骤：**
- `install` (默认): 将构建产物复制到前缀路径
- `uninstall`: 从前缀路径移除构建产物
- `run`: 运行应用程序
- `dll`: 构建 DLL 并复制到目标路径
- `test`: 运行库测试
- `test-exe`: 运行可执行文件测试

**项目特定选项：**
- `-Dtarget=[string]`: 目标 CPU 架构、OS 和 ABI
- `-Dcpu=[string]`: 目标 CPU 特性
- `-Dofmt=[string]`: 目标对象格式
- `-Ddynamic-linker=[string]`: 目标系统解释器路径
- `-Doptimize=[enum]`: 优化模式（Debug、ReleaseSafe、ReleaseFast、ReleaseSmall）

**优化级别：**

| 模式           | 说明            | 调试信息 | 优化 |
| -------------- | --------------- | -------- | ---- |
| `Debug`        | 默认，快速编译  | ✅        | ❌    |
| `ReleaseFast`  | 最大性能优化    | ❌        | ✅✅✅  |
| `ReleaseSafe`  | 安全运行 + 性能 | ❌        | ✅✅   |
| `ReleaseSmall` | 最小二进制体积  | ❌        | ✅    |

### `zig fetch`

获取远程依赖并添加到项目。该命令支持三种使用方式，在来源类型、版本锁定精度和项目配置影响上有显著区别。

#### `zig fetch --save https://.../v1.0.0.tar.gz`

**类型**：HTTP 归档下载

**锁定方式**：通过标签（Tag）锁定版本。`v1.0.0` 是语义化版本标签，Zig 会下载该标签对应的源码压缩包。

**--save 作用**：下载后自动将依赖信息写入 `build.zig.zon` 文件。

**特点**：获取项目发布的正式稳定版本，由于写入配置文件，团队协作或 CI/CD 构建时能确保获取一致的依赖。

#### `zig fetch --save git+https://.../repo.git#abc123`

**类型**：Git 仓库克隆

**锁定方式**：通过提交哈希（Commit Hash）锁定版本。`git+` 前缀显式指明这是 Git 协议，`#abc123` 是具体的 Git 提交哈希值，能锁定到代码库的某一次具体提交。

**--save 作用**：将 Git 依赖记录到 `build.zig.zon` 中。

**特点**：最精确的锁定方式，确保获取的代码字节级一致。适用于需要依赖某个库的特定补丁或最新开发状态时使用。

#### `zig fetch https://.../v1.0.0.tar.gz`

**类型**：HTTP 归档下载

**锁定方式**：通过标签（Tag）锁定版本（如 `v1.0.0`）。

**缺少 --save**：仅会下载依赖并缓存，但不会修改 `build.zig.zon` 文件。

**风险**：不可重现——分享项目或在另一台机器上构建时，由于 `build.zig.zon` 中没有记录该依赖，构建可能失败。**仅建议临时测试使用**。

**总结对比**：

| 命令                                         | 来源协议 | 锁定粒度 | 是否写入配置 | 推荐场景               |
| -------------------------------------------- | -------- | -------- | ------------ | ---------------------- |
| `zig fetch --save https://.../v1.0.0.tar.gz` | HTTP     | 版本标签 | ✅ 是         | 获取正式发布的稳定版本 |
| `zig fetch --save git+https://...#abc123`    | Git      | 提交哈希 | ✅ 是         | 需要锁定到特定代码提交 |
| `zig fetch https://.../v1.0.0.tar.gz`        | HTTP     | 版本标签 | ❌ 否         | 不推荐，仅临时测试     |

**最佳实践**：首选使用 `--save` 和版本标签的方式；仅在需要特定提交时使用 Git 方式；避免省略 `--save`。

### `zig init`

创建新项目。

```bash
# 创建可执行项目
zig init myproject

# 创建库项目
zig init-lib mylib

# 创建 exe 和 lib 混合项目
zig init-exe-lib myproject
```

## 编译选项

### 优化选项

```bash
-O Debug         # 默认，快速编译，保留调试信息
-O ReleaseFast   # 最大性能
-O ReleaseSafe   # 安全优化 + 运行时检查
-O ReleaseSmall  # 最小体积
```

### 目标平台

**目标三元组格式：**
```
<arch>-<os>-<abi>
```

**常见目标示例：**

```bash
# 本机目标
-target native-native-gnu

# Linux x86_64
-target x86_64-linux-gnu

# macOS ARM64
-target aarch64-macos-none

# Windows x64
-target x86_64-windows-msvc

# WebAssembly
-target wasm32-wasi-musl

# 树莓派
-target aarch64-linux-gnu
```


## 包管理与构建

### build.zig.zon 示例

```zig
.{
    .name = "myproject",
    .version = "0.1.0",
    .dependencies = .{
        .dep1 = .{
            .url = "https://github.com/user/repo/archive/refs/tags/v1.0.0.tar.gz",
            .hash = "1220...",
        },
        .dep2 = .{
            .path = "./local/path",
        },
    },
    .paths = .{
        "",
    },
}
```

### 常见问题及解决方案

#### 依赖下载失败（代理问题）
**根本原因：**
Zig 的 HTTP 客户端在通过代理连接 HTTPS 服务器时存在 bug（issue #19878），没有正确设置 TLS 隧道，导致向 HTTPS 服务器发送纯 HTTP 请求。错误信息：`Client sent an HTTP request to an HTTPS server`。此问题计划在 0.16.0 版本修复。

**解决方案：**

1. **清除代理环境变量（最简单）：**
   ```bash
   env -u https_proxy -u http_proxy -u HTTP_PROXY -u HTTPS_PROXY zig build
   ```

2. **使用 graftcp 强制 TCP 转发：**
   ```bash
   # 安装 graftcp
   graftcp -p 3333 zig build
   ```

3. **使用 zigfetch（推荐）：**
   社区工具 [zigfetch](https://github.com/jiacai2050/zigcli) 基于 libcurl，修复了代理问题。
   ```bash
   # 下载或编译 zigfetch，然后使用
   zigfetch https://github.com/ziex-dev/ziex#ce728232ad9e40ddddc590d07a043fe506cb9ad5
   ```

**其他方法：**
- 手动获取依赖：`zig fetch <url>`
- 使用本地路径：在 build.zig.zon 中将 `.url` 改为 `.path`