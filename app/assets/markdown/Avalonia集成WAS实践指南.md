---
date: "2026-04-29"
category: "技术实践"
read_time: "5分钟阅读"
title: "Avalonia 集成 Windows App SDK 实践指南"
excerpt: "记录 Avalonia 项目集成 Windows App SDK 的完整流程，包括 Mica 效果探索与常见问题解决"
tags: ["Avalonia", "Windows App SDK", "WAS", "MSIX", "Mica"]
---

### 一、前置准备
1. 安装 `winappcli` 工具
2. 创建 Avalonia 项目

### 二、核心集成步骤

#### 1. 更新项目配置
修改 `.csproj` 中的 TargetFramework，指定 Windows SDK 版本：
```xml
<TargetFramework>net10.0-windows10.0.26100.0</TargetFramework>
```

#### 2. 一键初始化 WAS
运行以下命令，按提示完成配置：
```bash
winapp init
```

该命令自动完成：
- 检测并更新 TargetFramework（如需要）
- 添加必要的 NuGet 包（`Microsoft.WindowsAppSDK`、`Microsoft.Windows.SDK.BuildTools` 等）
- 生成 `Package.appxmanifest` 和资源文件

#### 3. 带身份调试运行
直接运行即可自动获得包身份：
```bash
dotnet run
```

#### 4. MSIX 打包发布
```bash
# 生成开发证书（如已存在则跳过）
winapp cert generate --if-exists skip

# 构建发布版本
dotnet build -c Release

# 打包并签名
winapp pack .\bin\Release\net10.0-windows10.0.26100.0 --manifest .\Package.appxmanifest --cert .\devcert.pfx

# 安装证书（需管理员权限）
winapp cert install .\devcert.pfx
```

### 三、Mica 效果探索

尝试使用 `MicaController` 实现 Mica 效果：


实现代码示例：
```csharp
private void InitializeMicaEffect()
{
try
{
	if (!MicaController.IsSupported())
	{
		System.Diagnostics.Debug.WriteLine("当前系统不支持 Mica 效果");
		return;
	}

	var windowHandle = TryGetPlatformHandle()?.Handle ?? IntPtr.Zero;
	if (windowHandle == IntPtr.Zero)
	{
		Console.WriteLine("无法获取窗口句柄");
		return;
	}
	var windowId = Win32Interop.GetWindowIdFromWindow(windowHandle);


	var options = new DispatcherQueueOptions()
	{
		dwSize = (uint)Marshal.SizeOf(typeof(DispatcherQueueOptions)), 
		threadType = 2,          
		apartmentType = 1        
	};
	
	IntPtr queueController = IntPtr.Zero;
	var hr = CreateDispatcherQueueController(options, out queueController);
	
	if (hr != 0)
	{
		Console.WriteLine($"创建DispatcherQueueController失败: 0x{hr:x8}");
		return;
	}

	var compositor = new Windows.UI.Composition.Compositor();

	var desktopWindowTarget = CreateDesktopWindowTarget(compositor, windowHandle);

	_micaController = new MicaController();

	_isMicaSupported = _micaController.SetTarget(windowId, desktopWindowTarget);

	if (_isMicaSupported)
	{
		Console.WriteLine("Mica 效果已成功应用");
	}
	else
	{
		Console.WriteLine("无法在此窗口上应用 Mica 效果");
		_micaController?.Dispose();
		_micaController = null;
	}
}
catch (Exception ex)
{
	Console.WriteLine($"Mica 初始化失败: {ex.Message}\n{ex.StackTrace}");

	_micaController?.Dispose();
	_micaController = null;
}
}

private DesktopWindowTarget CreateDesktopWindowTarget(Windows.UI.Composition.Compositor compositor, IntPtr hwnd)
{
var interop = compositor.As<ICompositorDesktopInterop>();
interop.CreateDesktopWindowTarget(hwnd, false, out IntPtr targetPtr);
var target = DesktopWindowTarget.FromAbi(targetPtr);
target.Root = compositor.CreateContainerVisual();
return target;
}

protected override void OnClosed(EventArgs e)
{
base.OnClosed(e);
if (_micaController != null)
{
	try
	{
		_micaController.Dispose();
	}
	catch (Exception ex)
	{
		System.Diagnostics.Debug.WriteLine($"清理 MicaController 失败: {ex.Message}");
	}
	finally
	{
		_micaController = null;
	}
}
}

[ComImport]
[Guid("29E691FA-4567-4DCA-B319-D0F207EB6807")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface ICompositorDesktopInterop
{
void CreateDesktopWindowTarget(IntPtr hwndTarget, bool isTopmost, out IntPtr result);
}

[StructLayout(LayoutKind.Sequential)]
internal struct DispatcherQueueOptions
{
   public uint dwSize;
   public uint threadType;
   public uint apartmentType;
}

[DllImport("CoreMessaging.dll", EntryPoint = "CreateDispatcherQueueController", SetLastError = true)]
internal static extern int CreateDispatcherQueueController(DispatcherQueueOptions options, out IntPtr queueController);
```

**重要发现**：直接使用上述方法会导致窗口内容消失（只剩标题栏）。

查阅 Avalonia 源码 [WinUiCompositedWindow.cs](https://github.com/AvaloniaUI/Avalonia/blob/master/src/Windows/Avalonia.Win32/WinRT/Composition/WinUiCompositedWindow.cs#L37-L95) 后发现：**Avalonia 本身已经使用 Composition API 实现窗口效果**，再次创建会清空 root 节点。

**结论**：无需为 Avalonia 窗口额外实现 Mica 效果。

### 四、开发环境注意事项

在 Rider 中集成 WAS 后，需要注意以下配置问题：

- **运行配置**：需将运行配置修改为 UWP 模式，否则会报错
- **预览窗口问题**：默认运行配置使用 `Avalonia.Designer.HostApp.dll`，会导致 WAS 链接异常
- **XAML LSP 异常**：WAS 链接问题会影响 XAML 预览和语言服务

**建议**：在完成基础 UI 开发后，再集成 WAS 完善 Native 功能，避免开发过程中遇到不必要的调试障碍。