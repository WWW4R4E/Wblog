---
date: "2026-10-22"
category: "技术实践"
read_time: "40分钟阅读"
title: "SMTC音乐播放控制器组件制作指南"
excerpt: "基于 C# + WinUI3 + CsWin32 的系统级音乐播放控制器（SMTC）实现指南。"
tags: ["CSharp", "WinUI3", "SMTC", "Windows"]
---

# SMTC音乐播放控制器组件制作指南

> 基于 C# + WinUI3 + CsWin32 的系统级音乐播放控制器实现

## 📖 目录

1. [SMTC 基础概念](#1-smtc-基础概念)
2. [项目环境配置](#2-项目环境配置)
3. [核心API介绍](#3-核心api介绍)
4. [数据模型设计](#4-数据模型设计)
5. [媒体控制器实现](#5-媒体控制器实现)
6. [媒体信息获取](#6-媒体信息获取)
7. [播放控制功能](#7-播放控制功能)
8. [UI界面实现](#8-ui界面实现)
9. [完整示例代码](#9-完整示例代码)
10. [注意事项与最佳实践](#10-注意事项与最佳实践)

---

## 1. SMTC 基础概念

### 什么是 SMTC？

**SMTC (System Media Transport Controls)** 是 Windows 10/11 中的系统级媒体传输控制框架。

### 核心功能

- **🎵 系统级媒体会话管理**：Windows系统维护所有正在播放媒体的应用程序会话
- **🎛️ 全局媒体控制**：通过音量键、蓝牙耳机、锁屏界面等控制任何播放器
- **📋 媒体信息获取**：获取当前播放的歌曲名、艺术家、专辑封面等
- **🔄 跨应用程序通信**：不同应用可以监听和控制其他应用的媒体播放

### 支持的播放器

- Spotify
- 网易云音乐
- QQ音乐
- Windows Media Player
- Microsoft Edge 视频播放
- 等所有支持 Windows Media Foundation 的应用

---

## 2. 项目环境配置

### 2.1 NuGet 包依赖

```xml
<PackageReference Include="Microsoft.WindowsAppSDK" Version="1.4.231008000" />
<PackageReference Include="Microsoft.Windows.CsWin32" Version="0.3.106" />
<PackageReference Include="Win32Metadata" Version="54.0.43" />
```

### 2.2 项目文件配置

**Package.appxmanifest**
```xml
<Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10"
         xmlns:uap="http://schemas.microsoft.com/appx/manifest/uap/windows10"
         xmlns:rescap="http://schemas.microsoft.com/appx/manifest/foundation/windows10/restrictedcapabilities">

  <Applications>
    <Application Id="App">
      <uap:VisualElements>
        <uap:DefaultTile>
          <uap:ShowNameOnTiles>
            <uap:ShowOn Tile="square150x150Logo" />
          </uap:ShowNameOnTiles>
        </uap:DefaultTile>
      </uap:VisualElements>
    </Application>
  </Applications>

  <Capabilities>
    <rescap:Capability Name="backgroundMediaPlayback" />
  </Capabilities>
</Package>
```

### 2.3 必要的 using 语句

```csharp
using Windows.Media.Control;
using Windows.Storage.Streams;
using Microsoft.UI.Xaml;
using Microsoft.UI.Dispatching;
using System;
using System.IO;
using System.Threading.Tasks;
```

---

## 3. 核心API介绍

### 3.1 主要命名空间

| 命名空间 | 用途 |
|---------|------|
| `Windows.Media.Control` | 核心SMTC API |
| `Windows.Storage.Streams` | 处理媒体缩略图 |

### 3.2 关键类说明

#### GlobalSystemMediaTransportControlsSessionManager
- **作用**：获取系统媒体会话管理器
- **主要方法**：
  - `RequestAsync()` - 请求管理器实例
  - `GetCurrentSession()` - 获取当前活动会话
- **重要事件**：
  - `CurrentSessionChanged` - 当前会话切换事件

#### GlobalSystemMediaTransportControlsSession
- **作用**：代表单个媒体播放会话
- **主要方法**：
  - `TryGetMediaPropertiesAsync()` - 获取媒体属性
  - `GetPlaybackInfo()` - 获取播放状态信息
  - `TryPlayAsync()` / `TryPauseAsync()` - 播放/暂停控制
  - `TrySkipNextAsync()` / `TrySkipPreviousAsync()` - 切换歌曲
- **重要事件**：
  - `MediaPropertiesChanged` - 媒体属性变化事件

#### GlobalSystemMediaTransportControlsSessionMediaProperties
- **作用**：包含媒体元数据
- **主要属性**：
  - `Title` - 歌曲标题
  - `Artist` - 艺术家
  - `AlbumTitle` - 专辑名称
  - `Thumbnail` - 专辑封面

---

## 4. 数据模型设计

### 4.1 媒体信息模型

```csharp
/// <summary>
/// 媒体信息数据模型
/// </summary>
public class MediaInfo
{
    /// <summary>
    /// 歌曲标题
    /// </summary>
    public string Title { get; set; } = string.Empty;

    /// <summary>
    /// 艺术家
    /// </summary>
    public string Artist { get; set; } = string.Empty;

    /// <summary>
    /// 专辑名称
    /// </summary>
    public string Album { get; set; } = string.Empty;

    /// <summary>
    /// 来源应用名称
    /// </summary>
    public string AppName { get; set; } = string.Empty;

    /// <summary>
    /// 专辑封面字节数组
    /// </summary>
    public byte[]? Thumbnail { get; set; }

    /// <summary>
    /// 是否正在播放
    /// </summary>
    public bool IsPlaying { get; set; }

    /// <summary>
    /// 播放位置（如果支持）
    /// </summary>
    public TimeSpan? Position { get; set; }

    /// <summary>
    /// 总时长（如果支持）
    /// </summary>
    public TimeSpan? Duration { get; set; }
}
```

### 4.2 控制能力模型

```csharp
/// <summary>
/// 媒体控制能力
/// </summary>
public class MediaControlCapabilities
{
    public bool CanPlay { get; set; }
    public bool CanPause { get; set; }
    public bool CanNext { get; set; }
    public bool CanPrevious { get; set; }
    public bool CanSeek { get; set; }
    public bool CanShuffle { get; set; }
    public bool CanRepeat { get; set; }
}
```

---

## 5. 媒体控制器实现

### 5.1 MediaController 核心类

```csharp
/// <summary>
/// SMTC 媒体控制器
/// </summary>
public class MediaController : IDisposable
{
    private GlobalSystemMediaTransportControlsSessionManager? _sessionManager;
    private GlobalSystemMediaTransportControlsSession? _currentSession;
    private bool _disposed = false;

    /// <summary>
    /// 媒体信息变化事件
    /// </summary>
    public event EventHandler<MediaInfo>? MediaInfoChanged;

    /// <summary>
    /// 会话状态变化事件
    /// </summary>
    public event EventHandler<bool>? SessionActiveChanged;

    /// <summary>
    /// 初始化媒体控制器
    /// </summary>
    public async Task<bool> InitializeAsync()
    {
        try
        {
            // 请求媒体会话管理器
            _sessionManager = await GlobalSystemMediaTransportControlsSessionManager.RequestAsync();
            
            if (_sessionManager == null)
                return false;

            // 注册会话变化事件
            _sessionManager.CurrentSessionChanged += OnCurrentSessionChanged;

            // 获取当前活动会话
            await UpdateCurrentSession();
            
            return true;
        }
        catch (Exception ex)
        {
            System.Diagnostics.Debug.WriteLine($"初始化媒体控制器失败: {ex.Message}");
            return false;
        }
    }

    /// <summary>
    /// 更新当前会话
    /// </summary>
    private async Task UpdateCurrentSession()
    {
        try
        {
            // 移除旧会话的事件监听
            if (_currentSession != null)
            {
                _currentSession.MediaPropertiesChanged -= OnMediaPropertiesChanged;
                _currentSession.PlaybackInfoChanged -= OnPlaybackInfoChanged;
            }

            // 获取新的当前会话
            _currentSession = _sessionManager?.GetCurrentSession();

            if (_currentSession != null)
            {
                // 注册新会话的事件
                _currentSession.MediaPropertiesChanged += OnMediaPropertiesChanged;
                _currentSession.PlaybackInfoChanged += OnPlaybackInfoChanged;

                // 立即更新媒体信息
                await UpdateMediaInfo();
                SessionActiveChanged?.Invoke(this, true);
            }
            else
            {
                SessionActiveChanged?.Invoke(this, false);
            }
        }
        catch (Exception ex)
        {
            System.Diagnostics.Debug.WriteLine($"更新当前会话失败: {ex.Message}");
        }
    }

    /// <summary>
    /// 当前会话变化事件处理
    /// </summary>
    private async void OnCurrentSessionChanged(GlobalSystemMediaTransportControlsSessionManager sender, CurrentSessionChangedEventArgs args)
    {
        await UpdateCurrentSession();
    }

    /// <summary>
    /// 媒体属性变化事件处理
    /// </summary>
    private async void OnMediaPropertiesChanged(GlobalSystemMediaTransportControlsSession sender, MediaPropertiesChangedEventArgs args)
    {
        await UpdateMediaInfo();
    }

    /// <summary>
    /// 播放信息变化事件处理
    /// </summary>
    private async void OnPlaybackInfoChanged(GlobalSystemMediaTransportControlsSession sender, PlaybackInfoChangedEventArgs args)
    {
        await UpdateMediaInfo();
    }
}
```

---

## 6. 媒体信息获取

### 6.1 获取媒体属性方法

```csharp
/// <summary>
/// 更新媒体信息
/// </summary>
private async Task UpdateMediaInfo()
{
    if (_currentSession == null) 
    {
        MediaInfoChanged?.Invoke(this, new MediaInfo());
        return;
    }

    try
    {
        // 获取媒体属性和播放信息
        var mediaProperties = await _currentSession.TryGetMediaPropertiesAsync();
        var playbackInfo = _currentSession.GetPlaybackInfo();

        if (mediaProperties == null)
            return;

        // 创建媒体信息对象
        var mediaInfo = new MediaInfo
        {
            Title = mediaProperties.Title ?? "未知标题",
            Artist = mediaProperties.Artist ?? "未知艺术家",
            Album = mediaProperties.AlbumTitle ?? "",
            AppName = _currentSession.SourceAppUserModelId ?? "未知应用",
            IsPlaying = playbackInfo.PlaybackStatus == GlobalSystemMediaTransportControlsSessionPlaybackStatus.Playing
        };

        // 获取播放位置和时长（如果支持）
        var timelineProperties = playbackInfo.AutoRepeatMode;
        
        // 获取专辑封面
        await LoadThumbnail(mediaProperties, mediaInfo);

        // 在UI线程触发事件
        var dispatcherQueue = DispatcherQueue.GetForCurrentThread();
        if (dispatcherQueue != null)
        {
            dispatcherQueue.TryEnqueue(() =>
            {
                MediaInfoChanged?.Invoke(this, mediaInfo);
            });
        }
    }
    catch (Exception ex)
    {
        System.Diagnostics.Debug.WriteLine($"获取媒体信息失败: {ex.Message}");
    }
}
```

### 6.2 专辑封面处理

```csharp
/// <summary>
/// 加载专辑封面
/// </summary>
private async Task LoadThumbnail(GlobalSystemMediaTransportControlsSessionMediaProperties mediaProperties, MediaInfo mediaInfo)
{
    try
    {
        if (mediaProperties.Thumbnail != null)
        {
            using var thumbnailStream = await mediaProperties.Thumbnail.OpenReadAsync();
            
            if (thumbnailStream.Size > 0)
            {
                using var reader = new DataReader(thumbnailStream);
                await reader.LoadAsync((uint)thumbnailStream.Size);

                mediaInfo.Thumbnail = new byte[thumbnailStream.Size];
                reader.ReadBytes(mediaInfo.Thumbnail);
            }
        }
    }
    catch (Exception ex)
    {
        System.Diagnostics.Debug.WriteLine($"加载专辑封面失败: {ex.Message}");
        // 封面加载失败不影响其他信息的显示
    }
}
```

---

## 7. 播放控制功能

### 7.1 基础播放控制

```csharp
/// <summary>
/// 播放/暂停切换
/// </summary>
public async Task<bool> PlayPauseAsync()
{
    if (_currentSession == null) 
        return false;

    try
    {
        var playbackInfo = _currentSession.GetPlaybackInfo();
        
        if (playbackInfo.PlaybackStatus == GlobalSystemMediaTransportControlsSessionPlaybackStatus.Playing)
        {
            return await _currentSession.TryPauseAsync();
        }
        else
        {
            return await _currentSession.TryPlayAsync();
        }
    }
    catch (Exception ex)
    {
        System.Diagnostics.Debug.WriteLine($"播放/暂停操作失败: {ex.Message}");
        return false;
    }
}

/// <summary>
/// 下一首
/// </summary>
public async Task<bool> NextTrackAsync()
{
    if (_currentSession == null) 
        return false;

    try
    {
        return await _currentSession.TrySkipNextAsync();
    }
    catch (Exception ex)
    {
        System.Diagnostics.Debug.WriteLine($"下一首操作失败: {ex.Message}");
        return false;
    }
}

/// <summary>
/// 上一首
/// </summary>
public async Task<bool> PreviousTrackAsync()
{
    if (_currentSession == null) 
        return false;

    try
    {
        return await _currentSession.TrySkipPreviousAsync();
    }
    catch (Exception ex)
    {
        System.Diagnostics.Debug.WriteLine($"上一首操作失败: {ex.Message}");
        return false;
    }
}
```

### 7.2 控制能力检查

```csharp
/// <summary>
/// 获取当前媒体控制能力
/// </summary>
public MediaControlCapabilities GetControlCapabilities()
{
    if (_currentSession == null)
        return new MediaControlCapabilities();

    try
    {
        var controls = _currentSession.GetPlaybackInfo().Controls;
        
        return new MediaControlCapabilities
        {
            CanPlay = controls.IsPlayEnabled,
            CanPause = controls.IsPauseEnabled,
            CanNext = controls.IsNextEnabled,
            CanPrevious = controls.IsPreviousEnabled,
            CanSeek = controls.IsPlaybackPositionEnabled,
            CanShuffle = controls.IsShuffleEnabled,
            CanRepeat = controls.IsRepeatEnabled
        };
    }
    catch (Exception ex)
    {
        System.Diagnostics.Debug.WriteLine($"获取控制能力失败: {ex.Message}");
        return new MediaControlCapabilities();
    }
}

/// <summary>
/// 快速属性：是否可以播放
/// </summary>
public bool CanPlay => GetControlCapabilities().CanPlay;

/// <summary>
/// 快速属性：是否可以暂停
/// </summary>
public bool CanPause => GetControlCapabilities().CanPause;

/// <summary>
/// 快速属性：是否可以下一首
/// </summary>
public bool CanNext => GetControlCapabilities().CanNext;

/// <summary>
/// 快速属性：是否可以上一首
/// </summary>
public bool CanPrevious => GetControlCapabilities().CanPrevious;
```

### 7.3 资源释放

```csharp
/// <summary>
/// 释放资源
/// </summary>
public void Dispose()
{
    if (_disposed)
        return;

    try
    {
        if (_currentSession != null)
        {
            _currentSession.MediaPropertiesChanged -= OnMediaPropertiesChanged;
            _currentSession.PlaybackInfoChanged -= OnPlaybackInfoChanged;
        }

        if (_sessionManager != null)
        {
            _sessionManager.CurrentSessionChanged -= OnCurrentSessionChanged;
        }
    }
    catch (Exception ex)
    {
        System.Diagnostics.Debug.WriteLine($"释放资源时出错: {ex.Message}");
    }
    finally
    {
        _disposed = true;
    }
}
```

---

## 8. UI界面实现

### 8.1 XAML 布局设计

**MainWindow.xaml**
```xml
<Grid Background="{ThemeResource ApplicationPageBackgroundThemeBrush}">
    <ScrollViewer>
        <StackPanel Margin="40" Spacing="20" MaxWidth="400">
            
            <!-- 标题栏 -->
            <TextBlock Text="🎵 SMTC 音乐控制器" 
                      FontSize="24" 
                      FontWeight="Bold" 
                      HorizontalAlignment="Center"/>
            
            <!-- 专辑封面 -->
            <Border Background="{ThemeResource CardBackgroundFillColorDefaultBrush}"
                    CornerRadius="12"
                    Padding="20">
                <Image x:Name="ThumbnailImage" 
                       Width="200" 
                       Height="200" 
                       Stretch="UniformToFill">
                    <Image.Source>
                        <BitmapImage UriSource="ms-appx:///Assets/default-album.png"/>
                    </Image.Source>
                </Image>
            </Border>
            
            <!-- 歌曲信息 -->
            <StackPanel Spacing="8">
                <TextBlock x:Name="TitleText" 
                          FontSize="20" 
                          FontWeight="SemiBold" 
                          TextAlignment="Center"
                          TextWrapping="Wrap"
                          Text="暂无播放内容"/>
                          
                <TextBlock x:Name="ArtistText" 
                          FontSize="16" 
                          TextAlignment="Center"
                          Opacity="0.8"
                          TextWrapping="Wrap"
                          Text=""/>
                          
                <TextBlock x:Name="AlbumText" 
                          FontSize="14" 
                          TextAlignment="Center"
                          Opacity="0.6"
                          TextWrapping="Wrap"
                          Text=""/>
                          
                <TextBlock x:Name="AppNameText" 
                          FontSize="12" 
                          TextAlignment="Center"
                          Opacity="0.5"
                          Text=""/>
            </StackPanel>
            
            <!-- 播放状态指示器 -->
            <Border Background="{ThemeResource AccentFillColorDefaultBrush}"
                    CornerRadius="20"
                    Padding="12,6"
                    HorizontalAlignment="Center">
                <TextBlock x:Name="StatusText" 
                          Text="⏸ 已暂停" 
                          FontSize="12"
                          Foreground="White"/>
            </Border>
            
            <!-- 控制按钮 -->
            <StackPanel Orientation="Horizontal" 
                       HorizontalAlignment="Center" 
                       Spacing="15">
                       
                <Button Name="PreviousButton" 
                        Content="⏮" 
                        Click="PreviousButton_Click" 
                        IsEnabled="False"
                        Width="50" 
                        Height="50"
                        FontSize="18"
                        CornerRadius="25"/>
                        
                <Button Name="PlayPauseButton" 
                        Content="▶" 
                        Click="PlayPauseButton_Click" 
                        IsEnabled="False"
                        Width="60" 
                        Height="60"
                        FontSize="20"
                        CornerRadius="30"
                        Background="{ThemeResource AccentFillColorDefaultBrush}"/>
                        
                <Button Name="NextButton" 
                        Content="⏭" 
                        Click="NextButton_Click" 
                        IsEnabled="False"
                        Width="50" 
                        Height="50"
                        FontSize="18"
                        CornerRadius="25"/>
            </StackPanel>
            
            <!-- 连接状态 -->
            <TextBlock x:Name="ConnectionStatusText" 
                      Text="🔍 正在搜索媒体播放器..." 
                      FontSize="12"
                      HorizontalAlignment="Center"
                      Opacity="0.7"/>
                      
        </StackPanel>
    </ScrollViewer>
</Grid>
```

### 8.2 后台代码实现

**MainWindow.xaml.cs**
```csharp
public sealed partial class MainWindow : Window
{
    private MediaController? _mediaController;

    public MainWindow()
    {
        this.InitializeComponent();
        this.Closed += MainWindow_Closed;
        
        // 异步初始化媒体控制器
        _ = InitializeMediaControllerAsync();
    }

    /// <summary>
    /// 初始化媒体控制器
    /// </summary>
    private async Task InitializeMediaControllerAsync()
    {
        try
        {
            _mediaController = new MediaController();
            
            // 注册事件
            _mediaController.MediaInfoChanged += OnMediaInfoChanged;
            _mediaController.SessionActiveChanged += OnSessionActiveChanged;
            
            // 初始化
            bool success = await _mediaController.InitializeAsync();
            
            if (success)
            {
                ConnectionStatusText.Text = "✅ 已连接到系统媒体服务";
            }
            else
            {
                ConnectionStatusText.Text = "❌ 无法连接到系统媒体服务";
            }
        }
        catch (Exception ex)
        {
            ConnectionStatusText.Text = $"❌ 初始化失败: {ex.Message}";
            System.Diagnostics.Debug.WriteLine($"初始化媒体控制器失败: {ex}");
        }
    }

    /// <summary>
    /// 媒体信息变化事件处理
    /// </summary>
    private void OnMediaInfoChanged(object? sender, MediaInfo mediaInfo)
    {
        // 更新歌曲信息
        TitleText.Text = !string.IsNullOrEmpty(mediaInfo.Title) ? mediaInfo.Title : "未知标题";
        ArtistText.Text = mediaInfo.Artist;
        AlbumText.Text = mediaInfo.Album;
        AppNameText.Text = !string.IsNullOrEmpty(mediaInfo.AppName) ? $"来自: {mediaInfo.AppName}" : "";

        // 更新播放状态
        StatusText.Text = mediaInfo.IsPlaying ? "▶ 正在播放" : "⏸ 已暂停";
        PlayPauseButton.Content = mediaInfo.IsPlaying ? "⏸" : "▶";

        // 更新控制按钮状态
        var capabilities = _mediaController?.GetControlCapabilities();
        if (capabilities != null)
        {
            PlayPauseButton.IsEnabled = capabilities.CanPlay || capabilities.CanPause;
            NextButton.IsEnabled = capabilities.CanNext;
            PreviousButton.IsEnabled = capabilities.CanPrevious;
        }

        // 更新专辑封面
        UpdateThumbnail(mediaInfo.Thumbnail);
    }

    /// <summary>
    /// 会话状态变化事件处理
    /// </summary>
    private void OnSessionActiveChanged(object? sender, bool isActive)
    {
        if (isActive)
        {
            ConnectionStatusText.Text = "🎵 检测到活动的媒体播放器";
        }
        else
        {
            ConnectionStatusText.Text = "⏳ 等待媒体播放器启动...";
            
            // 重置UI状态
            TitleText.Text = "暂无播放内容";
            ArtistText.Text = "";
            AlbumText.Text = "";
            AppNameText.Text = "";
            StatusText.Text = "⏸ 已暂停";
            PlayPauseButton.Content = "▶";
            PlayPauseButton.IsEnabled = false;
            NextButton.IsEnabled = false;
            PreviousButton.IsEnabled = false;
            
            // 重置专辑封面
            UpdateThumbnail(null);
        }
    }

    /// <summary>
    /// 更新专辑封面
    /// </summary>
    private void UpdateThumbnail(byte[]? thumbnailData)
    {
        try
        {
            if (thumbnailData != null && thumbnailData.Length > 0)
            {
                using var stream = new MemoryStream(thumbnailData);
                var bitmap = new BitmapImage();
                bitmap.SetSource(stream.AsRandomAccessStream());
                ThumbnailImage.Source = bitmap;
            }
            else
            {
                // 使用默认封面
                ThumbnailImage.Source = new BitmapImage(new Uri("ms-appx:///Assets/default-album.png"));
            }
        }
        catch (Exception ex)
        {
            System.Diagnostics.Debug.WriteLine($"更新专辑封面失败: {ex.Message}");
            ThumbnailImage.Source = new BitmapImage(new Uri("ms-appx:///Assets/default-album.png"));
        }
    }

    /// <summary>
    /// 播放/暂停按钮点击事件
    /// </summary>
    private async void PlayPauseButton_Click(object sender, RoutedEventArgs e)
    {
        if (_mediaController != null)
        {
            bool success = await _mediaController.PlayPauseAsync();
            if (!success)
            {
                // TODO: 显示错误提示
                System.Diagnostics.Debug.WriteLine("播放/暂停操作失败");
            }
        }
    }

    /// <summary>
    /// 下一首按钮点击事件
    /// </summary>
    private async void NextButton_Click(object sender, RoutedEventArgs e)
    {
        if (_mediaController != null)
        {
            bool success = await _mediaController.NextTrackAsync();
            if (!success)
            {
                System.Diagnostics.Debug.WriteLine("下一首操作失败");
            }
        }
    }

    /// <summary>
    /// 上一首按钮点击事件
    /// </summary>
    private async void PreviousButton_Click(object sender, RoutedEventArgs e)
    {
        if (_mediaController != null)
        {
            bool success = await _mediaController.PreviousTrackAsync();
            if (!success)
            {
                System.Diagnostics.Debug.WriteLine("上一首操作失败");
            }
        }
    }

    /// <summary>
    /// 窗口关闭事件处理
    /// </summary>
    private void MainWindow_Closed(object sender, WindowEventArgs args)
    {
        // 释放媒体控制器资源
        _mediaController?.Dispose();
    }
}
```

---

## 9. 完整示例代码

### 9.1 项目结构

```
📁 SMTCMusicController/
├── 📁 Assets/
│   └── 🖼️ default-album.png
├── 📁 Models/
│   ├── 📄 MediaInfo.cs
│   └── 📄 MediaControlCapabilities.cs
├── 📁 Services/
│   └── 📄 MediaController.cs
├── 📄 MainWindow.xaml
├── 📄 MainWindow.xaml.cs
├── 📄 App.xaml
├── 📄 App.xaml.cs
└── 📄 Package.appxmanifest
```

### 9.2 完整的 MediaController.cs

```csharp
using Windows.Media.Control;
using Windows.Storage.Streams;
using Microsoft.UI.Dispatching;
using System;
using System.IO;
using System.Threading.Tasks;

namespace SMTCMusicController.Services
{
    /// <summary>
    /// SMTC 媒体控制器完整实现
    /// </summary>
    public class MediaController : IDisposable
    {
        private GlobalSystemMediaTransportControlsSessionManager? _sessionManager;
        private GlobalSystemMediaTransportControlsSession? _currentSession;
        private bool _disposed = false;

        public event EventHandler<MediaInfo>? MediaInfoChanged;
        public event EventHandler<bool>? SessionActiveChanged;

        public async Task<bool> InitializeAsync()
        {
            try
            {
                _sessionManager = await GlobalSystemMediaTransportControlsSessionManager.RequestAsync();
                
                if (_sessionManager == null)
                    return false;

                _sessionManager.CurrentSessionChanged += OnCurrentSessionChanged;
                await UpdateCurrentSession();
                
                return true;
            }
            catch (Exception ex)
            {
                System.Diagnostics.Debug.WriteLine($"初始化媒体控制器失败: {ex.Message}");
                return false;
            }
        }

        private async Task UpdateCurrentSession()
        {
            try
            {
                if (_currentSession != null)
                {
                    _currentSession.MediaPropertiesChanged -= OnMediaPropertiesChanged;
                    _currentSession.PlaybackInfoChanged -= OnPlaybackInfoChanged;
                }

                _currentSession = _sessionManager?.GetCurrentSession();

                if (_currentSession != null)
                {
                    _currentSession.MediaPropertiesChanged += OnMediaPropertiesChanged;
                    _currentSession.PlaybackInfoChanged += OnPlaybackInfoChanged;

                    await UpdateMediaInfo();
                    SessionActiveChanged?.Invoke(this, true);
                }
                else
                {
                    SessionActiveChanged?.Invoke(this, false);
                }
            }
            catch (Exception ex)
            {
                System.Diagnostics.Debug.WriteLine($"更新当前会话失败: {ex.Message}");
            }
        }

        private async void OnCurrentSessionChanged(GlobalSystemMediaTransportControlsSessionManager sender, CurrentSessionChangedEventArgs args)
        {
            await UpdateCurrentSession();
        }

        private async void OnMediaPropertiesChanged(GlobalSystemMediaTransportControlsSession sender, MediaPropertiesChangedEventArgs args)
        {
            await UpdateMediaInfo();
        }

        private async void OnPlaybackInfoChanged(GlobalSystemMediaTransportControlsSession sender, PlaybackInfoChangedEventArgs args)
        {
            await UpdateMediaInfo();
        }

        private async Task UpdateMediaInfo()
        {
            if (_currentSession == null) 
            {
                MediaInfoChanged?.Invoke(this, new MediaInfo());
                return;
            }

            try
            {
                var mediaProperties = await _currentSession.TryGetMediaPropertiesAsync();
                var playbackInfo = _currentSession.GetPlaybackInfo();

                if (mediaProperties == null)
                    return;

                var mediaInfo = new MediaInfo
                {
                    Title = mediaProperties.Title ?? "未知标题",
                    Artist = mediaProperties.Artist ?? "未知艺术家",
                    Album = mediaProperties.AlbumTitle ?? "",
                    AppName = _currentSession.SourceAppUserModelId ?? "未知应用",
                    IsPlaying = playbackInfo.PlaybackStatus == GlobalSystemMediaTransportControlsSessionPlaybackStatus.Playing
                };

                await LoadThumbnail(mediaProperties, mediaInfo);

                var dispatcherQueue = DispatcherQueue.GetForCurrentThread();
                dispatcherQueue?.TryEnqueue(() =>
                {
                    MediaInfoChanged?.Invoke(this, mediaInfo);
                });
            }
            catch (Exception ex)
            {
                System.Diagnostics.Debug.WriteLine($"获取媒体信息失败: {ex.Message}");
            }
        }

        private async Task LoadThumbnail(GlobalSystemMediaTransportControlsSessionMediaProperties mediaProperties, MediaInfo mediaInfo)
        {
            try
            {
                if (mediaProperties.Thumbnail != null)
                {
                    using var thumbnailStream = await mediaProperties.Thumbnail.OpenReadAsync();
                    
                    if (thumbnailStream.Size > 0)
                    {
                        using var reader = new DataReader(thumbnailStream);
                        await reader.LoadAsync((uint)thumbnailStream.Size);

                        mediaInfo.Thumbnail = new byte[thumbnailStream.Size];
                        reader.ReadBytes(mediaInfo.Thumbnail);
                    }
                }
            }
            catch (Exception ex)
            {
                System.Diagnostics.Debug.WriteLine($"加载专辑封面失败: {ex.Message}");
            }
        }

        public async Task<bool> PlayPauseAsync()
        {
            if (_currentSession == null) 
                return false;

            try
            {
                var playbackInfo = _currentSession.GetPlaybackInfo();
                
                if (playbackInfo.PlaybackStatus == GlobalSystemMediaTransportControlsSessionPlaybackStatus.Playing)
                {
                    return await _currentSession.TryPauseAsync();
                }
                else
                {
                    return await _currentSession.TryPlayAsync();
                }
            }
            catch (Exception ex)
            {
                System.Diagnostics.Debug.WriteLine($"播放/暂停操作失败: {ex.Message}");
                return false;
            }
        }

        public async Task<bool> NextTrackAsync()
        {
            if (_currentSession == null) 
                return false;

            try
            {
                return await _currentSession.TrySkipNextAsync();
            }
            catch (Exception ex)
            {
                System.Diagnostics.Debug.WriteLine($"下一首操作失败: {ex.Message}");
                return false;
            }
        }

        public async Task<bool> PreviousTrackAsync()
        {
            if (_currentSession == null) 
                return false;

            try
            {
                return await _currentSession.TrySkipPreviousAsync();
            }
            catch (Exception ex)
            {
                System.Diagnostics.Debug.WriteLine($"上一首操作失败: {ex.Message}");
                return false;
            }
        }

        public MediaControlCapabilities GetControlCapabilities()
        {
            if (_currentSession == null)
                return new MediaControlCapabilities();

            try
            {
                var controls = _currentSession.GetPlaybackInfo().Controls;
                
                return new MediaControlCapabilities
                {
                    CanPlay = controls.IsPlayEnabled,
                    CanPause = controls.IsPauseEnabled,
                    CanNext = controls.IsNextEnabled,
                    CanPrevious = controls.IsPreviousEnabled,
                    CanSeek = controls.IsPlaybackPositionEnabled,
                    CanShuffle = controls.IsShuffleEnabled,
                    CanRepeat = controls.IsRepeatEnabled
                };
            }
            catch (Exception ex)
            {
                System.Diagnostics.Debug.WriteLine($"获取控制能力失败: {ex.Message}");
                return new MediaControlCapabilities();
            }
        }

        public bool CanPlay => GetControlCapabilities().CanPlay;
        public bool CanPause => GetControlCapabilities().CanPause;
        public bool CanNext => GetControlCapabilities().CanNext;
        public bool CanPrevious => GetControlCapabilities().CanPrevious;

        public void Dispose()
        {
            if (_disposed)
                return;

            try
            {
                if (_currentSession != null)
                {
                    _currentSession.MediaPropertiesChanged -= OnMediaPropertiesChanged;
                    _currentSession.PlaybackInfoChanged -= OnPlaybackInfoChanged;
                }

                if (_sessionManager != null)
                {
                    _sessionManager.CurrentSessionChanged -= OnCurrentSessionChanged;
                }
            }
            catch (Exception ex)
            {
                System.Diagnostics.Debug.WriteLine($"释放资源时出错: {ex.Message}");
            }
            finally
            {
                _disposed = true;
            }
        }
    }
}
```

---

## 10. 注意事项与最佳实践

### 10.1 权限与安全

- **🔐 权限要求**：需要在 `Package.appxmanifest` 中声明 `backgroundMediaPlayback` 权限
- **🛡️ 安全考虑**：SMTC 只能控制支持该标准的应用，无法控制系统级进程
- **⚠️ 隐私保护**：某些应用可能会限制媒体信息的获取

### 10.2 性能优化

- **📊 事件处理**：避免在事件处理程序中执行耗时操作
- **🧵 线程安全**：确保UI更新在主线程中进行
- **💾 内存管理**：及时释放事件监听器和资源

### 10.3 错误处理

- **🔄 重试机制**：网络或系统错误时实现适当的重试
- **📝 日志记录**：记录关键操作和错误信息以便调试
- **🚫 优雅降级**：当SMTC不可用时提供替代方案

### 10.4 用户体验

- **⚡ 响应速度**：保持UI响应，使用异步操作
- **🎨 视觉反馈**：为用户操作提供及时的视觉反馈
- **🔄 状态同步**：确保UI状态与实际播放状态同步

### 10.5 兼容性考虑

- **🖥️ 系统版本**：SMTC 需要 Windows 10 1903 或更高版本
- **📱 设备支持**：不同设备的媒体控制能力可能不同
- **🎵 应用兼容**：并非所有音乐应用都完全支持SMTC

### 10.6 扩展建议

- **🎤 歌词集成**：集成Web API获取歌词显示
- **📊 播放统计**：记录播放历史和统计数据
- **🎨 主题定制**：支持多种UI主题和布局
- **🔧 设置选项**：提供用户自定义控制选项
- **📢 通知集成**：集成Windows通知系统

---

## 🎉 总结

通过本指南，你可以创建一个功能完整的SMTC音乐播放控制器组件。该组件能够：

- ✅ 获取系统中任何支持SMTC的媒体播放器信息
- ✅ 控制播放、暂停、上一首、下一首
- ✅ 显示歌曲信息、专辑封面
- ✅ 实时响应播放状态变化
- ✅ 提供良好的用户交互体验

这为后续集成歌词显示、播放统计等高级功能奠定了坚实的基础。

---

*📅 文档创建日期：2025-07-28*  
*🔧 适用技术栈：C# + WinUI3 + CsWin32*  
*📖 目标系统：Windows 10 1903+ / Windows 11*