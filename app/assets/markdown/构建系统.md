---
date: "2026-04-01"
category: "技术"
read_time: "8分钟阅读"
title: "Zig 构建系统常用模板详解"
href: "/blog/zig-build-system-templates"
excerpt: "详细介绍 Zig 构建系统的 8 个核心模板，涵盖可执行文件、动态/静态库、C 语言集成、跨平台构建及依赖管理等常用场景。"
tags: ["Zig", "构建系统", "教程", "笔记"]
---

## Q
可以给我详细介绍一下zig的构建系统吗？主要是告诉我解决几个常用的构建模板，我想做个md笔记
## Zig 构建系统常用模板详解
本代码图详细展示了Zig构建系统的8个核心模板，涵盖从基础可执行文件构建[1a-1d]到复杂的跨平台动态库开发[2a-2d][5c-5d]，包括C语言集成[4a-4d]、依赖管理[6a-6d]、测试配置[7a-7d]和文件安装[8a-8d]等常用场景。
### 1. 可执行文件构建模板
展示最基础的可执行文件构建流程，从创建构建步骤到配置模块和优化选项
### 1a. 创建可执行文件步骤 (`build.zig:43`)
使用 addExecutable 创建编译步骤
```text
const exe = b.addExecutable(.{
```
### 1b. 设置输出文件名 (`build.zig:44`)
从源文件路径推导可执行文件名
```text
.name = std.fs.path.stem(case.src_path),
```
### 1c. 指定源文件 (`build.zig:46`)
设置主源文件路径
```text
.root_source_file = b.path(case.src_path),
```
### 1d. 添加依赖关系 (`build.zig:55`)
将编译步骤添加到构建依赖链
```text
step.dependOn(&exe.step);
```
### 2. 动态库构建模板
演示如何构建动态链接库(DLL/SO)，包括版本管理和链接配置
### 2a. 创建库构建步骤 (`build.zig:9`)
使用 addLibrary 创建库编译配置
```text
const lib = b.addLibrary(.{
```
### 2b. 设置动态链接 (`build.zig:10`)
指定生成动态库而非静态库
```text
.linkage = .dynamic,
```
### 2c. 库版本管理 (`build.zig:12`)
设置库的语义版本号
```text
.version = .{ .major = 1, .minor = 0, .patch = 0 },
```
### 2d. 链接动态库 (`build.zig:33`)
将动态库链接到可执行文件
```text
exe.root_module.linkLibrary(lib);
```
### 3. 静态库构建模板
展示静态库的构建和链接过程，包括头文件包含路径配置
### 3a. 创建静态库 (`build.zig:9`)
初始化静态库构建配置
```text
const foo = b.addLibrary(.{
```
### 3b. 指定静态链接 (`build.zig:10`)
设置库类型为静态库
```text
.linkage = .static,
```
### 3c. 添加C源文件 (`build.zig:18`)
将C文件编译到静态库中
```text
foo.root_module.addCSourceFile(.{ .file = b.path("foo.c"), .flags = &[_][]const u8{} });
```
### 3d. 配置头文件路径 (`build.zig:19`)
添加头文件搜索目录
```text
foo.root_module.addIncludePath(b.path("."));
```
### 4. 混合C/Zig项目模板
演示如何在Zig项目中集成C代码，包括编译标志和链接器配置
### 4a. 添加C源文件编译 (`build.zig:30`)
编译C文件并指定C标准
```text
exe.root_module.addCSourceFile(.{ .file = b.path("test.c"), .flags = &[_][]const u8{"-std=c11"} });
```
### 4b. 链接C标准库 (`build.zig:25`)
启用C标准库链接
```text
.link_libc = true,
```
### 4c. 强制使用LLVM后端 (`build.zig:28`)
为特殊C特性启用LLVM
```text
.use_llvm = true,
```
### 4d. 设置运行期望 (`build.zig:34`)
配置测试运行期望值
```text
run_cmd.expectExitCode(0);
```
### 5. 跨平台构建模板
展示如何处理不同平台的构建需求，包括目标解析和条件编译
### 5a. 解析目标平台 (`build.zig:40`)
将目标查询转换为具体目标
```text
const resolved_target = b.resolveTargetQuery(case.target);
```
### 5b. 操作系统过滤 (`build.zig:36`)
根据操作系统条件跳过构建
```text
if (case.os_filter) |os_tag| {
```
### 5c. 自定义目标配置 (`build.zig:11`)
为裸机环境设置目标
```text
.target = b.resolveTargetQuery(.{ .cpu_arch = .x86, .os_tag = .freestanding }),
```
### 5d. 平台特定宏 (`build.zig:27`)
为Windows MSVC添加导出宏
```text
if (b.graph.host.result.abi == .msvc) shared.root_module.addCMacro("API", "__declspec(dllexport)");
```
### 6. 依赖管理和模块系统
演示Zig的依赖管理机制，包括模块导入和依赖传递
### 6a. 声明依赖 (`build.zig:45`)
创建并配置项目依赖
```text
const dep = b.dependency("other", .{
```
### 6b. 传递目标配置 (`build.zig:46`)
为依赖指定目标平台
```text
.target = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu }),
```
### 6c. 匿名模块导入 (`build.zig:24`)
在运行时导入生成的二进制文件
```text
exe.root_module.addAnonymousImport("bootloader.elf", .{
```
### 6d. 动态源文件 (`build.zig:25`)
使用构建产物作为模块源
```text
.root_source_file = bootloader.getEmittedBin(),
```
### 7. 测试和运行配置
展示如何配置测试运行、环境变量和进程执行
### 7a. 创建运行步骤 (`build.zig:35`)
添加可执行文件运行步骤
```text
const run_cmd = b.addRunArtifact(exe);
```
### 7b. 传递二进制参数 (`build.zig:31`)
将构建产物作为命令行参数传递
```text
run.addArtifactArg(child);
```
### 7c. 清理环境变量 (`build.zig:32`)
运行时清空环境变量
```text
run.clearEnvironment();
```
### 7d. 设置工作目录 (`build.zig:41`)
为运行步骤配置工作目录
```text
run_relative.setCwd(tmp_cwd);
```
### 8. 文件安装和头文件管理
演示如何安装构建产物、配置头文件和管理安装目录结构
### 8a. 安装头文件目录 (`build.zig:42`)
批量安装头文件并排除特定文件
```text
libfoo.installHeadersDirectory(b.path("include"), "foo", .{ .exclude_extensions = &.{".ignore_me.h"} });
```
### 8b. 生成配置头文件 (`build.zig:57`)
创建并安装配置头文件
```text
libfoo.installConfigHeader(b.addConfigHeader(.{
```
### 8c. 自定义安装路径 (`build.zig:85`)
配置库和头文件的安装目录
```text
const install_libfoo = b.addInstallArtifact(libfoo, .{
```
### 8d. 覆盖头文件目录 (`build.zig:87`)
自定义头文件安装位置
```text
.h_dir = .{ .override = .{ .custom = "custom/include" } },
```