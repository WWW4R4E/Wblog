---
date: "2026-10-19"
category: "技术"
read_time: "8分钟阅读"
title: "Vulkan 在 Mac 上的运行原理与 MoltenVK 接入实践"
excerpt: "深入解析 Vulkan 在 macOS 上通过 MoltenVK 转译到 Metal 的完整链路,并给出让 Vulkan 引擎真正跑起来的代码改动步骤。"
tags: ["Vulkan", "MoltenVK", "Metal", "笔记"]
---

# Vulkan 在 Mac 上的运行原理与 MoltenVK 接入实践

## 背景

macOS 不原生支持 Vulkan。Mojang 在 Minecraft 26.3 中给 Java 版加入了 Vulkan 渲染后端,但在 Mac 上选择 Vulkan 模式后,底层实际跑的还是 Metal——中间有一层 MoltenVK 转换层。这件事引起了好奇:既然最终还是 Metal,那"选 Vulkan"到底是个什么过程?如果自己写了一个 Vulkan 引擎,怎么让它在 Mac 上真正跑起来?

## 原理剖析:MoltenVK 是怎么工作的?

MoltenVK 本质是一个 **Vulkan 到 Metal 的转译层**。需要区分两个层面:

### 游戏代码层面 vs 系统执行层面

| 层面 | 发生了什么 | 谁在干活 |
|------|-----------|---------|
| **游戏代码层面** | 引擎发出的是 Vulkan API 调用 | 游戏自己(完全不知道 Metal 的存在) |
| **系统执行层面** | MoltenVK 把 Vulkan 指令翻译成 Metal 调用 | macOS Metal 驱动真正执行到 GPU |

**关键**: Vulkan over Metal,不是原生 Metal。除非你用了 Ciderlight/mcopt 之类提供原生 Metal 后端的第三方模组,否则 Minecraft 自己并没有直接调 Metal。

### 为什么需要这层转换?

- macOS 唯一原生的 GPU API 是 Metal
- Vulkan 和 Metal 的着色器语言、管线模型差异很大
- MoltenVK 由 Khronos 官方维护,负责完整的转译工作

### 性能和兼容性代价

- 转换层带来额外开销,Vulkan 模式在 Mac 上 **不一定比原生 OpenGL 快**,甚至可能更慢
- 早期版本有画面全粉(pink-screen)、输入延迟等 Bug,目前仍处于实验阶段
- 遇到问题时切换回 OpenGL 通常是更稳妥的选择

## 环境配置

### 正确姿势:LunarG Vulkan SDK for macOS

最省事的方法是直接使用 **LunarG 的 Vulkan SDK for macOS**,里面已经包含了预编译好的 MoltenVK 库。

**注意:不要用 Homebrew 安装 `vulkan-headers`**。它通常缺少关键的 ICD 配置文件,会导致程序找不到 MoltenVK。

### 环境变量

安装后,确保开发环境能找到库和 ICD 文件:

```bash
# 告诉 Vulkan 加载器去哪里找 MoltenVK 的 ICD 描述文件
export VK_ICD_FILENAMES="/path/to/VulkanSDK/MoltenVK_icd.json"

# 告诉动态链接器去哪里找 MoltenVK 的 .dylib
export DYLD_LIBRARY_PATH="/path/to/VulkanSDK/lib:$DYLD_LIBRARY_PATH"
```

## 核心代码改动(最关键的一步)

这是最容易踩坑的地方。Vulkan 默认只枚举"完全合规"的驱动,而 MoltenVK 被归类为 **"可移植性"(Portability)实现**。默认情况下,Vulkan 加载器 **不会** 把这些设备暴露给你的程序。

**如果你不改代码,`vkEnumeratePhysicalDevices` 会直接返回 0 个设备,引擎根本看不到 Mac 的 GPU。**

### 必须做两件事

1. **启用扩展**: 在 `ppEnabledExtensionNames` 中加入 `VK_KHR_portability_enumeration`
2. **设置标志位**: 在 `VkInstanceCreateInfo` 的 `flags` 中按位或上 `VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR`

### 示例代码

```cpp
// 1. 构建扩展列表 — 在你已有的窗口相关扩展基础上追加
std::vector<const char*> extensions = {
    VK_EXT_debug_utils_extension_name,   // 调试层(可选但推荐)
    VK_KHR_surface_extension_name,       // Surface 基础
    VK_EXT_metal_surface_extension_name, // macOS Surface(现代推荐,见下方说明)
    // ... 你其他需要的扩展
};

// 2. 关键:加入 portability enumeration
extensions.push_back(VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME);

// 3. 创建 VkInstance
VkInstanceCreateInfo createInfo{};
createInfo.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
createInfo.enabledExtensionCount = extensions.size();
createInfo.ppEnabledExtensionNames = extensions.data();

// 4. 关键:设置枚举 portability 驱动的标志位
createInfo.flags |= VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR;

VkInstance instance;
vkCreateInstance(&createInfo, nullptr, &instance);
```

### 能不能不改代码?

**基本不行**。这个行为是写死在 Vulkan 加载器逻辑里的,无法通过环境变量或配置"欺骗"它。

有一个理论旁路是 **直接链接 MoltenVK,跳过系统 Vulkan 加载器**。MoltenVK 本身实现了加载器的入口点,理论上可能不执行那套过滤逻辑。但这意味着:
- 你需要修改 **构建配置**(链接方式)
- 会失去验证层(Validation Layers)等调试工具
- 依然涉及项目配置改动,开发阶段得不偿失

所以两行代码的改动是成本最低、最稳妥的做法。

### 让代码更健壮

建议先查询这个扩展是否存在,存在才启用,这样不会影响 Windows/Linux 的构建:

```cpp
// 查询支持的扩展
uint32_t extensionCount;
vkEnumerateInstanceExtensionProperties(nullptr, &extensionCount, nullptr);
std::vector<VkExtensionProperties> extensions(extensionCount);
vkEnumerateInstanceExtensionProperties(nullptr, &extensionCount, extensions.data());

bool hasPortability = false;
for (auto& ext : extensions) {
    if (strcmp(ext.extensionName, VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME) == 0) {
        hasPortability = true;
        break;
    }
}

// 仅在支持时启用
if (hasPortability) {
    yourExtensions.push_back(VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME);
    createInfo.flags |= VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR;
}
```

## 窗口与 Surface

窗口部分完成后,下一步是创建 Vulkan Surface。在 macOS 上,Vulkan 的呈现最终要依托于 **CAMetalLayer**。

### Surface 扩展选择

**重要:Apple 平台的 Surface 扩展经历了两次迭代。**

| 扩展 | 状态 | 说明 |
|------|------|------|
| `VK_MVK_macos_surface` / `VK_MVK_ios_surface` | **已弃用** | 旧版 MoltenVK 专属扩展,仍可使用但不再推荐 |
| `VK_EXT_metal_surface` | **现代推荐** | Vulkan 原生标准扩展,不仅适用于 MoltenVK,也被 KosmicKrisp 等其他 Metal 后端支持 |

**新代码应使用 `VK_EXT_metal_surface`**,它的创建参数直接接受一个 `CAMetalLayer*`:

```cpp
// 使用现代推荐的 VK_EXT_metal_surface
VkMetalSurfaceCreateInfoEXT surfaceInfo{};
surfaceInfo.sType = VK_STRUCTURE_TYPE_METAL_SURFACE_CREATE_INFO_EXT;
surfaceInfo.pLayer = myCAMetalLayer;  // 直接传入 CAMetalLayer

VkSurfaceKHR surface;
vkCreateMetalSurfaceEXT(instance, &surfaceInfo, nullptr, &surface);
```

### 确保窗口 Layer 类型

无论用哪个扩展,窗口的 Layer 必须是 **`CAMetalLayer`**,这样 Vulkan 交换链才能正确呈现图像。

```objc
// AppKit/NSView 中设置 CAMetalLayer
NSView* view = ...;
view.wantsLayer = YES;
view.layer = [CAMetalLayer layer];
```

## MoltenVK 的能力限制

既然底层是 Metal,你的 Vulkan 引擎在 Mac 上会有一些固有的能力缺失:

| Vulkan 特性 | MoltenVK 支持情况 |
|------------|------------------|
| 几何着色器(Geometry Shaders) | 不可用 |
| 曲面细分(Tessellation) | 不可用 |
| 计算着色器 | 基本支持 |
| 图形管线 | 大部分支持 |

如果在开发中用到这些高级特性,在 Mac 上需要准备替代方案或做条件编译。

## 替代方案:KosmicKrisp

除了 MoltenVK,还有一个较新的选项叫 **KosmicKrisp**(基于 Mesa):
- 专门针对 Apple Silicon 优化
- 目标支持现代 Vulkan(最高 1.4)
- 目前主要瞄准 macOS 26+

**结论**: 追求前沿特性且只针对新系统,可以关注 KosmicKrisp;追求稳定和广泛兼容性,MoltenVK 仍是更稳妥的选择。值得注意的是,KosmicKrisp 也支持 `VK_EXT_metal_surface`,所以如果你一开始就用了这个现代扩展,未来切换后端几乎不需要改 Surface 相关代码。

## 总结

让 Vulkan 引擎在 Mac 上跑起来的完整链路:

1. 安装 LunarG Vulkan SDK for macOS(不要用 Homebrew)
2. 设置 `VK_ICD_FILENAMES` 和 `DYLD_LIBRARY_PATH` 环境变量
3. 在 `VkInstanceCreateInfo` 中启用 `VK_KHR_portability_enumeration` 扩展 + 设置 `VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR` 标志位
4. 使用 `VK_EXT_metal_surface`(现代推荐)或 `VK_MVK_macos_surface`(旧版)创建 Surface,确保窗口 Layer 是 `CAMetalLayer`
5. 注意 MoltenVK 不支持几何着色器和曲面细分
