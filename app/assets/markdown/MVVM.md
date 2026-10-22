---
date: "2026-10-22"
category: ".NET"
read_time: "8分钟阅读"
title: "Community Toolkit MVVM 笔记"
excerpt: "Community Toolkit MVVM 通过源代码生成器简化属性通知和命令绑定，并记录 WinUI 3 中 x:Bind 的兼容性问题。"
tags: ["CSharp", "MVVM", "WinUI"]
---

Community Toolkit MVVM通过源代码生成器简化了MVVM模式的实现，包括属性更改通知和命令绑定。

### WinUI 3中`x:Bind`和Community Toolkit MVVM的兼容性

在WinUI 3 (以及UWP XAML) 应用程序中，使用Community Toolkit MVVM时，建议使用`partial`属性而不是字段来定义可观察属性。这是因为在WinRT场景中，字段上的`[ObservableProperty]`属性生成的代码可能不兼容AOT (Ahead-of-Time) 编译。使用`partial`属性可以确保CsWinRT生成器正确生成所需的WinRT封送代码。

例如，您应该这样定义一个可观察属性：

```csharp
[ObservableProperty]
public partial string? Text { get; set; }
```


而不是这样：

```csharp
[ObservableProperty]
private string? text;
```


### 将ViewModel中的方法绑定到自定义控件的委托属性

要将ViewModel中的方法绑定到自定义控件的委托属性，您可以使用`[RelayCommand]`属性。`RelayCommand`生成器会将标记的方法转换为一个`IRelayCommand`属性，该属性可以在XAML中通过`x:Bind`进行绑定。

1.  **在ViewModel中定义方法并使用`[RelayCommand]`属性**：

    ```csharp
    using CommunityToolkit.Mvvm.Input;
    using CommunityToolkit.Mvvm.ComponentModel; // For ObservableObject

    public partial class MyViewModel : ObservableObject
    {
        [RelayCommand]
        private void MyAction()
        {
            // 执行您的逻辑
        }
    }
    ```
    
    源代码生成器会自动生成一个名为`MyActionCommand`的`IRelayCommand`属性。

2.  **在自定义控件中定义委托属性**<cite/>：

    假设您的自定义控件有一个名为`CommandProperty`的`DependencyProperty`，其类型为`ICommand`或`IRelayCommand`。

    ```csharp
    // CustomControl.cs
    public sealed partial class CustomControl : Control
    {
        public static readonly DependencyProperty CommandProperty =
            DependencyProperty.Register(
                nameof(Command),
                typeof(ICommand),
                typeof(CustomControl),
                new PropertyMetadata(null));

        public ICommand Command
        {
            get => (ICommand)GetValue(CommandProperty);
            set => SetValue(CommandProperty, value);
        }

        public CustomControl()
        {
            this.DefaultStyleResourceUri = new Uri("ms-appx:///CustomControl/CustomControl.xaml");
        }
    }
    ```
    <cite/>

3.  **在XAML中使用`x:Bind`进行绑定**<cite/>：

    在您的WinUI 3页面的XAML中，您可以将自定义控件的`Command`属性绑定到ViewModel中生成的`MyActionCommand`<cite/>：

    ```xml
    <Page
        x:Class="YourApp.MainPage"
        xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        xmlns:local="using:YourApp"
        xmlns:custom="using:YourApp.CustomControls"
        xmlns:d="http://schemas.microsoft.com/expression/blend/2008"
        xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006"
        mc:Ignorable="d">

        <Page.DataContext>
            <local:MyViewModel x:Name="ViewModel"/>
        </Page.DataContext>

        <Grid>
            <custom:CustomControl Command="{x:Bind ViewModel.MyActionCommand, Mode=OneWay}" />
        </Grid>
    </Page>
    ```
    <cite/>

    请注意，`Mode=OneWay`通常适用于命令绑定，因为命令通常是从UI触发到ViewModel的单向操作<cite/>。

### WinRT兼容性注意事项

在WinRT (如WinUI 3) 场景中，Community Toolkit MVVM的源代码生成器会进行额外的检查。例如，`[RelayCommand]`在某些情况下可能与`[GeneratedBindableCustomProperty]`不兼容，这可能会导致警告`MVVMTK0046` 。如果遇到此类警告，建议手动声明命令属性而不是依赖`[RelayCommand]`生成器。

Notes:
`x:Bind`是WinUI 3中推荐的数据绑定方式，它在编译时生成代码，提供更好的性能和编译时类型检查<cite/>。Community Toolkit MVVM的源代码生成器与`x:Bind`配合良好，因为它也生成编译时代码。

Wiki pages you might want to explore:
- [ObservableProperty System (CommunityToolkit/dotnet)](/wiki/CommunityToolkit/dotnet#2.1)
- [Source Generators (CommunityToolkit/dotnet)](/wiki/CommunityToolkit/dotnet#2.3)
- [Diagnostics and Code Fixers (CommunityToolkit/dotnet)](/wiki/CommunityToolkit/dotnet#2.4)

View this search on DeepWiki: https://deepwiki.com/search/winui-3communitymvvmxbindviewm_2bea4971-f331-4cd3-9035-298fc24dee60
