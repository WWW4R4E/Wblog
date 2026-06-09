---
date: ""
category: ".NET"
read_time: "20分钟阅读"
title: "dotnet new 项目模板指南"
excerpt: "从零创建 dotnet new 项目模板，包含配置详解、安装使用、修改更新和分发共享"
tags: [".NET", "模板", "笔记"]
---

# dotnet new 项目模板指南

> 基于 WinUI NavigationView 模板实战经验总结
> 从零创建 → 安装使用 → 修改更新 → 分发共享

---

## 目录

1. [基础知识](#1-基础知识)
2. [从零创建模板](#2-从零创建模板)
3. [template.json 配置详解](#3-templatejson-配置详解)
4. [安装与使用](#4-安装与使用)
5. [修改与更新](#5-修改与更新)
6. [分发与共享](#6-分发与共享)
7. [常见问题](#7-常见问题)

---

## 1. 基础知识

### 什么是 dotnet new 模板？

`dotnet new` 是 .NET SDK 自带的项目脚手架工具。模板就是一个包含 `{}.template.config/template.json` 的普通项目文件夹，执行 `dotnet new install` 后即可用 `dotnet new <shortName>` 创建项目。

### 和 VS 导出模板（.vstemplate）的区别

| 特性 | VS 导出模板 (.vstemplate) | dotnet new 模板 (template.json) |
|------|--------------------------|-------------------------------|
| 配置格式 | XML | JSON |
| 安装方式 | 复制 .zip 到 Templates 目录 | `dotnet new install` |
| 变量替换 | `$safeprojectname$` 等 VS 宏 | `sourceName` + 符号替换 |
| 跨平台 | ❌ Windows only | ✅ Linux/macOS/Windows |
| VS 中显示 | ✅ 原生支持 | ✅ VS 自动发现 |
| 版本管理 | ❌ 手动管理 | ✅ 可通过 NuGet 包管理 |
| GUID 生成 | ✅ 自动 | ✅ 需配置 `generator` 符号 |

---

## 2. 从零创建模板

### 2.1 准备基础项目

先创建一个能正常编译运行的项目，以此作为模板原型。

```bash
# 以 WinUI 3 为例，先用微软官方模板创建
dotnet new winui-navview -n MyTemplate

# 确认能编译
dotnet build -p:Platform=x64
```

### 2.2 创建模板配置目录

```bash
# 在项目根目录下
mkdir .template.config
```

然后创建 `.template.config/template.json`。

### 2.3 最小配置

```json
{
  "$schema": "http://json.schemastore.org/template",
  "author": "你的名字",
  "classifications": ["WinUI", "Navigation", "Desktop"],
  "name": "你的模板名称",
  "description": "一句话描述这个模板",
  "identity": "YourCompany.YourTemplate.CSharp",
  "shortName": "your-short-name",
  "sourceName": "MyTemplate",
  "tags": {
    "language": "C#",
    "type": "project"
  }
}
```

### 2.4 关键字段说明

| 字段 | 作用 | 示例 |
|------|------|------|
| `shortName` | CLI 使用的简称 | `winui-nav-custom` |
| `sourceName` | 要被替换的字符串 | `MyTemplate` — 新建时会被项目名替换 |
| `identity` | 模板唯一标识 | 推荐格式：`公司.类别.语言` |
| `classifications` | VS 中的标签 | 影响搜索分类 |

### 2.5 使用 sourceName 替换

**核心机制**：`template.json` 中的 `sourceName` 指定一个字符串（如 `MyTemplate`），当执行 `dotnet new your-short-name -n NewProject` 时，模板引擎会**自动将项目内所有文件和文件名中的 `MyTemplate` 替换为 `NewProject`**。

所以：
- 源代码中所有 namespace `MyTemplate` → 自动变成 `NewProject`
- 文件名 `MyTemplate.csproj` → 自动变成 `NewProject.csproj`
- 文件夹名 `MyTemplate/` → 自动变成 `NewProject/`

> 💡 **最佳实践**：项目内不要用 `$safeprojectname$`，全部用你的 `sourceName` 字符串即可。

### 2.6 处理 GUID

在 `template.json` 中添加 `guids` 数组：

```json
{
  "guids": [
    "FAE04EC0-301F-11D3-BF4B-00C04F79EFBC"
  ]
}
```

模板引擎会查找该 GUID 并替换为新生成的 GUID。但注意：这个替换**并不总是自动触发**，如果发现 GUID 没被替换，可以显式定义符号：

```json
{
  "symbols": {
    "projectGuid": {
      "type": "generated",
      "generator": "guid",
      "replaces": "YOUR-PLACEHOLDER-GUID",
      "parameters": {
        "format": "D"
      }
    }
  }
}
```

然后在文件中写入 `YOUR-PLACEHOLDER-GUID`，新建时会被自动替换。

### 2.7 处理包标识符（Package.appxmanifest）

WinUI 项目包清单中有两个特殊标记必须**保留原样**：

- `$targetentrypoint$` — WinUI 构建系统在编译时替换
- `$targetnametoken$.exe` — 同上

**不要**试图把 `$targetentrypoint$` 替换掉！它不是 VS 模板变量，而是 WinUI 的 MSBuild 属性。

---

## 3. template.json 配置详解

### 3.1 完整配置参考

```json
{
  "$schema": "http://json.schemastore.org/template",
  "author": "你的名字/组织",
  "classifications": [
    "WinUI",
    "Navigation View",
    "Desktop"
  ],
  "name": "WinUI Navigation View Template",
  "description": "基于 WinUI 3 NavigationView 的导航模板，包含 DI、主题切换、页面导航",
  "identity": "YourOrg.WinUI.NavigationViewTemplate.CSharp",
  "groupIdentity": "YourOrg.WinUI.Templates",
  "shortName": "winnav-template",
  "tags": {
    "language": "C#",
    "type": "project"
  },
  "sourceName": "App1",
  "preferNameDirectory": true,
  "guids": [
    "FAE04EC0-301F-11D3-BF4B-00C04F79EFBC"
  ],
  "symbols": {
    "projectGuid": {
      "type": "generated",
      "generator": "guid",
      "replaces": "YOUR-PLACEHOLDER-GUID",
      "parameters": {
        "format": "D"
      }
    }
  },
  "sources": [
    {
      "modifiers": [
        {
          "condition": "(skip)",
          "exclude": [
            ".template.config/**",
            "bin/**",
            "obj/**",
            "*.user",
            "*.suo",
            ".vs/**",
            "*.md"
          ]
        }
      ]
    }
  ]
}
```

### 3.2 symbols（符号/变量）

除了 `sourceName` 自动替换，还可以定义额外符号：

```json
"symbols": {
  "Framework": {
    "type": "parameter",
    "description": "目标框架",
    "datatype": "choice",
    "choices": [
      { "choice": "net9.0-windows10.0.19041.0", "description": ".NET 9" },
      { "choice": "net10.0-windows10.0.19041.0", "description": ".NET 10" }
    ],
    "defaultValue": "net10.0-windows10.0.19041.0",
    "replaces": "TARGET_FRAMEWORK"
  },
  "IncludeSampleData": {
    "type": "parameter",
    "datatype": "bool",
    "defaultValue": "true",
    "description": "是否包含示例数据"
  }
}
```

使用方式：

```bash
dotnet new winnav-template -n MyApp --Framework net9.0-windows10.0.19041.0 --IncludeSampleData false
```

### 3.3 sources（文件过滤）

排除不需要的文件进入模板：

```json
"sources": [
  {
    "modifiers": [
      {
        "exclude": [
          ".template.config/**",
          "bin/**",
          "obj/**",
          ".vs/**",
          "*.user",
          "*.suo",
          "Thumbs.db"
        ]
      }
    ]
  }
]
```

如果你想保留某些 README 但用户创建时不想看到：

```json
"rename": [
  {
    "action": "rename",
    "source": "README-template.md",
    "target": "README.md"
  }
]
```

---

## 4. 安装与使用

### 4.1 安装模板

```bash
# 从本地文件夹安装
dotnet new install "C:\Users\123\Desktop\MyTemplateProject"

# 从 NuGet 包安装
dotnet new install MyCompany.Templates::1.0.0
```

### 4.2 创建项目

```bash
# 最简单的用法
dotnet new winnav-template -n MyNewApp

# 指定输出目录
dotnet new winnav-template -n MyNewApp -o "D:\Projects\MyNewApp"

# 查看可用参数
dotnet new winnav-template --help
```

### 4.3 列出已安装模板

```bash
# 按短名称搜索
dotnet new list winnav-template

# 查看所有已安装模板包
dotnet new uninstall
```

### 4.4 VS 中使用

安装后重启 VS，新建项目 → 搜索短名称（如 `winnav-template`）→ 直接使用。

> VS 会自动发现通过 `dotnet new install` 安装的模板，无需额外配置。

---

## 5. 修改与更新

### 5.1 修改模板内容

直接编辑**源模板文件夹**内的文件：

1. 修改源代码（如添加新页面、修改样式）
2. 修改 `.template.config/template.json`（如更新版本、添加参数）

### 5.2 重新安装更新

```bash
# 先卸载旧版本
dotnet new uninstall "C:\Users\123\Desktop\MyTemplateProject"

# 再重新安装
dotnet new install "C:\Users\123\Desktop\MyTemplateProject"
```

> ⚠️ **注意**：`dotnet new install` 不会自动检测源文件变化，每次修改后都需要先 `uninstall` 再 `install`。

### 5.3 验证修改

```bash
# 创建一个测试项目
dotnet new winnav-template -n TestUpdate -o "C:\Temp\TestUpdate"

# 检查文件是否按预期生成
dir C:\Temp\TestUpdate /s
```

### 5.4 懒人更新脚本

新建 `update-template.ps1`：

```powershell
param(
    [string]$TemplatePath = ".",
    [string]$TestName = "TestApp",
    [string]$TestDir = "$env:TEMP\TemplateTest"
)

# 卸载旧版
dotnet new uninstall "$(Resolve-Path $TemplatePath)"

# 重新安装
dotnet new install "$(Resolve-Path $TemplatePath)"

# 清理测试目录
if (Test-Path $TestDir) { Remove-Item -Recurse -Force $TestDir }

# 测试生成
dotnet new winnav-template -n $TestName -o $TestDir

# 尝试编译
pushd $TestDir
dotnet build -p:Platform=x64
popd

Write-Output "`n✅ 更新完成！测试项目已生成到: $TestDir"
```

---

## 6. 分发与共享

### 6.1 方式一：直接分享文件夹（最简单）

将模板文件夹（包含 `.template.config`）打包成 ZIP 或直接发给别人。

对方执行：

```bash
dotnet new install "C:\Users\对方\Desktop\MyTemplateFolder"
```

优点：简单直接
缺点：需要手动管理版本

### 6.2 方式二：发布为 NuGet 包（推荐）

将模板打包为 `.nupkg`，上传到 NuGet 或私有源。

#### 创建 nuspec 文件

`MyTemplate.nuspec`：

```xml
<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://schemas.microsoft.com/packaging/2012/06/nuspec.xsd">
  <metadata>
    <id>YourOrg.WinUI.NavigationViewTemplate</id>
    <version>1.0.0</version>
    <title>WinUI NavigationView Template</title>
    <authors>你的名字</authors>
    <description>基于 WinUI 3 NavigationView 的导航模板</description>
    <tags>dotnet-new template WinUI NavView</tags>
    <packageTypes>
      <packageType name="Template" />
    </packageTypes>
  </metadata>
</package>
```

#### 打包

```bash
# 安装 nuget CLI 工具
dotnet tool install --global NuGet.Build.Tasks.Pack

# 打包为 .nupkg（注：将模板内容放进 content/ 目录）
# 或者用 .csproj 方式（推荐）
```

#### 推荐：使用 .csproj 打包

创建 `MyTemplate.csproj`：

```xml
<Project Sdk="Microsoft.Build.NoTargets">
  <PropertyGroup>
    <PackageId>YourOrg.WinUI.NavigationViewTemplate</PackageId>
    <Version>1.0.0</Version>
    <Description>基于 WinUI 3 NavigationView 的导航模板</Description>
    <Authors>你的名字</Authors>
    <PackageTags>dotnet-new;template;winui;navigation</PackageTags>
    <PackageType>Template</PackageType>
    <TargetFramework>netstandard2.0</TargetFramework>
    <IncludeContentInPack>true</IncludeContentInPack>
    <IncludeBuildOutput>false</IncludeBuildOutput>
    <NoDefaultExcludes>true</NoDefaultExcludes>
  </PropertyGroup>

  <ItemGroup>
    <Content Include="**" Exclude="bin/**;obj/**;*.nupkg" />
    <Compile Remove="**/*" />
  </ItemGroup>
</Project>
```

```bash
# 打包
dotnet pack

# 安装测试
dotnet new install "bin\Release\YourOrg.WinUI.NavigationViewTemplate.1.0.0.nupkg"
```

#### 上传到 NuGet

```bash
# 发布到 nuget.org
dotnet nuget push bin\Release\YourOrg.WinUI.NavigationViewTemplate.1.0.0.nupkg --api-key 你的API密钥 --source https://api.nuget.org/v3/index.json
```

之后别人通过以下方式安装：

```bash
dotnet new install YourOrg.WinUI.NavigationViewTemplate
# 或指定版本
dotnet new install YourOrg.WinUI.NavigationViewTemplate::1.0.0
```

### 6.3 方式三：Git 仓库 + CI 自动发布

将模板项目托管在 GitHub，配置 GitHub Actions 自动打包发布到 NuGet。

优点：
- 版本自动管理
- 团队协作方便
- 可设置 CI/CD 自动测试

示例 `.github/workflows/publish.yml`：

```yaml
name: Publish Template

on:
  push:
    tags:
      - 'v*'

jobs:
  publish:
    runs-on: windows-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-dotnet@v4
        with:
          dotnet-version: '10.x'
      - run: dotnet pack -c Release
      - run: dotnet nuget push **\*.nupkg --api-key ${{secrets.NUGET_API_KEY}} --source https://api.nuget.org/v3/index.json
```

---

## 7. 常见问题

### Q: 创建的项目编译报错

检查：
1. 源模板本身能否正常编译 → `dotnet build -p:Platform=x64`
2. 源模板中是否残留 VS 变量（如 `$safeprojectname$`）→ 应全部替换为你的 `sourceName`
3. WinUI 项目必须指定平台（不能用 AnyCPU）

### Q: GUID 没被替换

`guids` 数组**不一定触发替换**。显式使用 `symbols` 方案：

```json
"symbols": {
  "myGuid": {
    "type": "generated",
    "generator": "guid",
    "replaces": "PLACEHOLDER-GUID-HERE"
  }
}
```

在文件中写 `PLACEHOLDER-GUID-HERE`，新建时会被替换。

### Q: VS 中不显示模板

1. 运行 `dotnet new install` 确认安装成功
2. 重启 VS
3. 检查 `template.json` 是否有语法错误（用 JSON 验证工具）
4. 检查 `template.json` 的 `tags.type` 是否为 `"project"`
5. 确保 `.template.config` 目录名大小写正确

### Q: VS 中显示两个一样的模板

检查是否同时安装了：
- 从文件夹安装的版本 (`dotnet new install <folder>`)
- 从 NuGet 安装的版本 (`dotnet new install <package>`)
- 微软官方相似的模板（如 `WinUI NavigationView App`）

运行 `dotnet new uninstall` 查看所有已安装来源。

### Q: `$targetentrypoint$` 和 `$targetnametoken$` 要改吗？

**不要改**。这两个是 WinUI 构建系统的 MSBuild 属性，编译时自动替换。如果手动改成文字值，运行时会出现 `COMException`。

### Q: 更新模板后 VS 还是旧版本

```bash
# 重新安装
dotnet new uninstall "C:\Path\To\Template"
dotnet new install "C:\Path\To\Template"
# 然后重启 VS
```

---

## 总结：快速参考清单

### 创建模板（一次性的）

```
□ 准备好一个可编译的项目
□ 创建 .template.config/template.json
□ 设置 sourceName 为你的项目名
□ 替换项目中所有 VS 变量为 sourceName
□ 配置 guids 或 symbols 处理 GUID
□ 配置 sources 排除不需要的文件
□ dotnet new install <folder> 安装
□ dotnet new <shortName> -n TestApp 测试
□ dotnet build 确认编译通过
```

### 更新模板（每次修改后）

```
□ dotnet new uninstall <folder>
□ 修改源代码或 template.json
□ dotnet new install <folder>
□ dotnet new <shortName> -n TestApp 验证
```

### 分发模板（选择一种）

```
□ 方式一：直接分享文件夹（最简单）
□ 方式二：打包为 NuGet 包（推荐）
□ 方式三：Git + CI 自动发布（最专业）
```

---

> 这份指南基于实际的 WinUI NavigationView 模板实战编写。
> 如有问题或建议，欢迎反馈！
