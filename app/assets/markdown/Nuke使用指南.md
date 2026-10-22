---
date: "2026-10-22"
category: ".NET"
read_time: "18分钟阅读"
title: "Nuke 构建系统使用指南"
excerpt: "Nuke 是跨平台的 .NET 构建自动化系统，支持用 C# 编写强类型构建脚本并对接 CI/CD。"
tags: ["Nuke", "构建", "CI/CD"]
---

# Nuke 构建系统使用指南

## 什么是 Nuke？

Nuke 是一个跨平台的 .NET 构建自动化系统，具有以下特点：

- **强类型**：使用 C# 编写构建脚本，有完整的 IDE 支持
- **跨平台**：支持 Windows、Linux、macOS
- **可扩展**：丰富的内置工具和第三方扩展
- **CI/CD 友好**：自动生成 CI 配置文件

## 项目结构

```
StarSorter/
├── .nuke/                    # Nuke 配置目录
├── build/                    # 构建脚本目录
│   ├── Build.cs              # 主构建脚本
│   ├── Configuration.cs      # 配置枚举
│   └── StarSorter.csproj
├── compose/                  # Android/Jetpack Compose 项目
│   ├── app/                  # Android 应用模块
│   ├── gradle/               # Gradle 包装器
│   └── ...
├── core/                     # Zig 核心库
│   ├── src/                  # Zig 源代码
│   ├── build.zig             # Zig 构建脚本
│   └── build.zig.zon         # Zig 包配置
├── winui/                    # WinUI 3 应用
│   ├── App.cs                # 应用入口
│   └── winui.csproj          # 项目文件
├── docs/                     # 文档目录
├── build.cmd                 # Windows 入口脚本
├── build.ps1                 # PowerShell 入口脚本
└── build.sh                  # Unix 入口脚本
```

## 构建目标说明

| 目标 | 说明 | 平台限制 |
|------|------|----------|
| `Clean` | 清理所有构建产物 | 无 |
| `BuildZigCore` | 编译 Zig 核心库 | 需要 Zig |
| `Restore` | 恢复 .NET 依赖 | 无 |
| `BuildWinUIApp` | 构建 WinUI 3 应用 | Windows |
| `BuildAndroidApp` | 构建 Jetpack Compose Android 应用 | 无 (需 JDK/Android SDK) |
| `RunWinUI` | 运行 WinUI 应用 | Windows |
| `Test` | 运行所有测试 | 无 |
| `FullBuild` | 完整构建（默认目标） | 无 |
| `BuildCoreOnly` | 仅构建 Zig 核心库 | 需要 Zig |

## 交互式菜单

运行 `./build.ps1`（无参数）时会显示交互式菜单：

```
╔══════════════════════════════════════════════════════════════╗
║              StarSorter - 构建菜单                 ║
╠══════════════════════════════════════════════════════════════╣
║  1. 完整构建 (WinUI + Android)                              ║
║  2. 仅构建 WinUI 3 应用                                     ║
║  3. 仅构建 Android/Jetpack Compose 应用                     ║
║  4. 仅构建 Zig 核心库                                       ║
║  5. 运行所有测试                                             ║
║  6. 运行 WinUI 应用 (调试)                                  ║
║  0. 退出                                                    ║
╚══════════════════════════════════════════════════════════════╝

请选择操作 [0-6]: 
```

## 基本概念

### 1. Target（目标）

Target 是构建的基本单元，类似于 Make 中的 target 或 MSBuild 中的 Task。

```csharp
Target Clean => _ => _
    .Before(Restore)
    .Executes(() =>
    {
        // 清理逻辑
    });
```

### 2. Target 依赖关系

```csharp
Target Compile => _ => _
    .DependsOn(Restore)      // 必须先完成 Restore
    .DependsOn(CompileCore)  // 必须先完成 CompileCore
    .Executes(() =>
    {
        // 编译逻辑
    });
```

### 3. 参数定义

```csharp
[Parameter("构建配置")]
readonly Configuration Configuration = IsLocalBuild ? Configuration.Debug : Configuration.Release;

[Parameter("自定义参数")]
readonly string MyCustomParam = "default_value";
```

## 常用参数

| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `-Configuration` | Debug/Release | Release | 构建配置 |
| `-BuildWinUI` | bool | true | 是否构建 WinUI 应用 |
| `-BuildAndroid` | bool | true | 是否构建 Android 应用 |
| `-target` | string | FullBuild | 指定要执行的目标 |

## 运行构建

### Windows

```powershell
# 交互式菜单（无参数）
./build.ps1

# 完整构建（命令行模式）
./build.ps1 -target FullBuild

# 仅构建 Android
./build.ps1 -BuildWinUI false -target BuildAndroidApp

# 仅构建 WinUI
./build.ps1 -BuildAndroid false -target BuildWinUIApp

# 仅构建 Zig 核心
./build.ps1 -target BuildCoreOnly

# 构建 Release 版本
./build.ps1 -Configuration Release

# 运行 WinUI 应用（调试）
./build.ps1 -BuildAndroid false -target RunWinUI

# 运行所有测试
./build.ps1 -target Test

# 查看帮助
./build.ps1 --help
```

### Linux/macOS

```bash
# 完整构建
./build.sh

# 仅构建 Android
./build.sh -BuildWinUI false -target BuildAndroidApp

# 构建 Release 版本
./build.sh -Configuration Release
```

## 环境要求

### 1. Zig
- 安装位置：建议添加到 PATH
- 版本：建议使用最新稳定版（测试版本：0.16.0）
- 下载：[ziglang.org/download/](https://ziglang.org/download/)

### 2. .NET SDK
- 版本：.NET 10.0（项目构建脚本使用）
- 下载：[dotnet.microsoft.com/download](https://dotnet.microsoft.com/download)

### 3. Android 开发环境
- JDK 17（AGP 8.x 要求）
- Android SDK（通过 Android Studio 安装）
- 环境变量：`JAVA_HOME`、`ANDROID_HOME`

### 4. WinUI 3 构建（Windows 专属）
- Windows 10/11
- Visual Studio 2022（带 Windows 应用开发工作负载）
- Windows App SDK（版本 2.0+）

## 构建流程

### 目标依赖关系图

```
Clean
   │
   ▼
BuildZigCore (Zig 核心库)
   │
   ├──► Restore (.NET 依赖) ──► BuildWinUIApp (WinUI 3)
   │
   └──► BuildAndroidApp (Compose)
```

### 执行顺序

1. **Clean**：清理所有构建产物
2. **BuildZigCore**：编译 Zig 核心库
3. **Restore**：恢复 .NET 依赖（指定运行时标识符）
4. **BuildWinUIApp**：构建 WinUI 3 应用（自动检测系统位数）
5. **BuildAndroidApp**：构建 Android 应用

## 构建产物位置

### Zig 核心库
```
core/zig-out/lib/
├── core.dll          (Windows)
├── libcore.so        (Linux)
└── libcore.dylib     (macOS)
```

### WinUI 应用
```
winui/bin/Release/net10.0-windows10.0.22621.0/win-x64/
└── winui.exe
```

### Android APK
```
compose/app/build/outputs/apk/
├── debug/
│   └── app-debug.apk
└── release/
    └── app-release-unsigned.apk
```

## 调试构建脚本

在 Visual Studio 或 Rider 中，可以直接调试 Build.cs：

1. 设置断点
2. 右键 Build.cs 项目 → Debug
3. 或使用调试配置启动

## CI/CD 集成

### GitHub Actions 示例

```yaml
name: CI
on:
  push:
    branches: [ main ]
  pull_request:
    branches: [ main ]

jobs:
  build-windows:
    runs-on: windows-latest
    
    steps:
    - uses: actions/checkout@v4
    
    - name: Setup .NET
      uses: actions/setup-dotnet@v4
      with:
        dotnet-version: 10.0.x
    
    - name: Setup Zig
      uses: goto-bus-stop/setup-zig@v2
      with:
        version: 0.16.0
    
    - name: Build
      run: .\build.ps1 -Configuration Release -BuildAndroid false

  build-android:
    runs-on: ubuntu-latest
    
    steps:
    - uses: actions/checkout@v4
    
    - name: Setup .NET
      uses: actions/setup-dotnet@v4
      with:
        dotnet-version: 10.0.x
    
    - name: Setup Zig
      uses: goto-bus-stop/setup-zig@v2
      with:
        version: 0.16.0
    
    - name: Setup Java
      uses: actions/setup-java@v4
      with:
        java-version: '17'
        distribution: 'temurin'
    
    - name: Build Android
      run: ./build.sh -Configuration Release -BuildWinUI false
```

## 最佳实践

### 1. 使用强类型路径

```csharp
// 推荐
AbsolutePath SourceDirectory => RootDirectory / "src";

// 不推荐
string sourceDir = Path.Combine(RootDirectory, "src");
```

### 2. 分离关注点

```csharp
// 将不同职责的 Target 分开
Target CompileCore => _ => _.Executes(() => { /* Zig 编译 */ });
Target CompileDotNet => _ => _.Executes(() => { /* .NET 编译 */ });
Target Compile => _ => _.DependsOn(CompileCore, CompileDotNet);
```

### 3. 使用条件执行

```csharp
Target CompileWindows => _ => _
    .OnlyWhenStatic(() => IsWin)
    .Executes(() => { /* Windows 特定逻辑 */ });

Target CompileLinux => _ => _
    .OnlyWhenStatic(() => IsLinux)
    .Executes(() => { /* Linux 特定逻辑 */ });
```

### 4. 处理 .NET 10.0 兼容性

由于 .NET 10.0 移除了 BinaryFormatter，Nuke 的 `DotNetClean`、`DotNetRestore`、`DotNetBuild` 等 API 不再可用。解决方案是直接调用 `dotnet` CLI：

```csharp
// 使用 CLI 替代 Nuke API
ProcessTasks.StartProcess("dotnet", "restore -r win-x64", workingDirectory)
    .AssertZeroExitCode();

ProcessTasks.StartProcess("dotnet", "build -c Release -r win-x64", workingDirectory)
    .AssertZeroExitCode();
```

### 5. WinUI 构建注意事项

WinUI 3 构建需要指定运行时标识符（RID）：

```csharp
var runtimeIdentifier = Environment.Is64BitOperatingSystem ? "win-x64" : "win-x86";
ProcessTasks.StartProcess("dotnet", $"build -r {runtimeIdentifier}", WinUIDirectory)
    .AssertZeroExitCode();
```
