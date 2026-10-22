---
date: "2026-10-22"
category: ".NET"
read_time: "8分钟阅读"
title: "MVVM Toolkit 核心功能详解"
excerpt: "Community Toolkit MVVM 核心功能梳理，包括 ObservableObject、属性变更通知与命令绑定。"
tags: ["CSharp", "MVVM", "CommunityToolkit"]
---

## MVVM Toolkit 核心功能详解

### 1. ObservableObject

**特点:**
- 实现 `INotifyPropertyChanged` 接口的基类
- 提供属性变更通知机制
- 支持 `INotifyPropertyChanging` 接口(属性变更前通知)

**应用场景:**
- MVVM 模式中的 ViewModel 基类
- 需要数据绑定的业务模型
- 任何需要通知 UI 属性变化的场景

**用法示例:**
```csharp
public partial class MyViewModel : ObservableObject
{
    [ObservableProperty]
    private string name;
}
```

### 2. ObservableRecipient

**特点:**
- 继承自 `ObservableObject`
- 集成 Messenger 消息服务支持
- 自动管理消息订阅生命周期

**应用场景:**
- 需要跨组件通信的 ViewModel
- 松耦合的模块间消息传递
- 复杂应用中的事件总线场景

**用法示例:**
```csharp
[ObservableRecipient]
public sealed partial class ModelWithNotifyPropertyChangedRecipientsAndDisplayAttributeLast : ObservableValidator
{
    [ObservableProperty]
    [NotifyPropertyChangedRecipients]
    public partial object? SomeProperty { get; set; }
}
```

### 3. ObservableValidator

**特点:**
- 继承自 `ObservableObject`
- 实现 `INotifyDataErrorInfo` 接口
- 支持数据注解验证(Data Annotations)

**应用场景:**
- 表单验证
- 用户输入校验
- 业务规则验证

**用法示例:**
```csharp
public partial class MyFormViewModel : ObservableValidator
{
    [ObservableProperty]
    [Required]
    [MinLength(1)]
    [MaxLength(100)]
    private string? name;
}
```

### 4. RelayCommand / AsyncRelayCommand

**特点:**
- 实现 `ICommand` 接口
- `RelayCommand`: 同步命令
- `AsyncRelayCommand`: 支持异步操作和取消
- 通过 `[RelayCommand]` 特性自动生成

**应用场景:**
- UI 按钮点击事件
- 用户交互操作
- 异步数据加载

**用法示例:**
```csharp
partial class MyViewModel
{
    [RelayCommand]
    private void Test()
    {
    }
}
```

**命令与属性联动:**
```csharp
[ObservableProperty]
[NotifyCanExecuteChangedFor(nameof(GreetUserCommand))]
public partial string Name { get; set; }

public IRelayCommand GreetUserCommand { get; }
```

### 5. Messenger System

**WeakReferenceMessenger:**
- 使用弱引用避免内存泄漏
- 适合长生命周期对象

**StrongReferenceMessenger:**
- 使用强引用提升性能
- 牺牲弱引用换取速度

**应用场景:**
- 跨模块通信
- 解耦组件间依赖
- 事件广播

### 6. Ioc (依赖注入)

**特点:**
- 配置 DI 容器的辅助类
- 简化服务注册和解析

**应用场景:**
- 应用启动时配置服务
- 管理对象生命周期
- 实现控制反转(IoC)

### 7. Source Generators (源代码生成器)

**特点:**
- 编译时基于特性生成样板代码
- 零运行时开销
- 类型安全

**核心生成器:**
- `ObservablePropertyGenerator`: 生成属性实现
- `RelayCommandGenerator`: 生成命令实现

**生成示例:**

输入:
```csharp
[ObservableProperty]
private string name;
```

生成输出:
```csharp
public string Name
{
    get => name;
    set
    {
        if (!EqualityComparer<string>.Default.Equals(name, value))
        {
            OnNameChanging(value);
            OnPropertyChanging("Name");
            name = value;
            OnNameChanged(value);
            OnPropertyChanged("Name");
        }
    }
}
```

## Notes

MVVM Toolkit 是微软官方维护的 MVVM 框架，是 MvvmLight 的官方继承者。它支持多个目标框架，包括 .NET Standard 2.0/2.1 和 .NET 8.0，并且在 Microsoft Store 等第一方应用中广泛使用。

源代码生成器支持多个 Roslyn 版本以保持广泛兼容性，并包含完善的诊断分析器和代码修复器。

Wiki pages you might want to explore:
- [ObservableProperty System (CommunityToolkit/dotnet)](/wiki/CommunityToolkit/dotnet#2.1)
- [Source Generators (CommunityToolkit/dotnet)](/wiki/CommunityToolkit/dotnet#2.3)
- [Diagnostics and Code Fixers (CommunityToolkit/dotnet)](/wiki/CommunityToolkit/dotnet#2.4)
