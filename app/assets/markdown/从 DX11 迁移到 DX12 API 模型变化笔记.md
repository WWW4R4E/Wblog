---
date: "2026-10-19"
category: "技术"
read_time: "5分钟阅读"
title: "从 DX11 迁移到 DX12:那些必须注意的 API 模型变化"
excerpt: "记录 DX11 迁移到 DX12 过程中的关键 API 变化,特别是 CreateSwapChainFor* 参数从 device 变成 command queue 的根本原因。"
tags: ["DirectX", "D3D12", "API", "笔记"]
---

# 从 DX11 迁移到 DX12:那些必须注意的 API 模型变化

## 背景

从 DX11 迁移到 DX12,远不止 API 名称的变化。微软重写了整个图形栈的设计哲学——从 "driver manages everything" 变成 "application manages everything"。这篇笔记记录迁移过程中最容易踩坑的几个 API 变化,以及它们背后的设计原因。

## 变化一:设备创建从一步变两步

### DX11 的方式

DX11 提供一个大而全的 API,创建设备的同时把交换链也建好:

```zig
// DX11(对比用伪代码)
// 一个调用同时拿到 device、deviceContext、swapChain
D3D11CreateDeviceAndSwapChain(..., &swapChainDesc, &swapChain, &device, &deviceContext, ...);
```

### DX12 的方式

```zig
// 第一步:用 DXGI 创建 Factory
var factory: ?*anyopaque = null;
const hr = CreateDXGIFactory2(0, &IID_IDXGIFactory2, &factory);

// 第二步:用 Factory 枚举适配器、创建 D3D12 Device
var d3d_device: ?*win32.ID3D12Device = null;
D3D12CreateDevice(adapter, D3D_FEATURE_LEVEL_12_0, &IID_ID3D12Device, &d3d_device);

// 第三步:用 Factory 创建 SwapChain(单独一步)
var swap_chain: ?*win32.IDXGISwapChain = null;
factory.CreateSwapChainForHwnd(/* ... */);
```

### 为什么要拆成两步?

DX11 的 `D3D11CreateDeviceAndSwapChain` 强行绑定了"设备创建"和"呈现",灵活性很差。DX12 把它们解耦成两个独立概念:

| 概念 | 职责 |
|------|------|
| **D3D12 Device** | 负责资源创建、命令队列、pipeline 状态对象等 — 只管"绘制" |
| **DXGI Factory + SwapChain** | 负责呈现到窗口 — 只管"把画好的东西显示出来" |

这样做的好处:
- 可以先创建设备、跑纯离线渲染计算(Compute),完全不需要 SwapChain
- 可以用同一个 Device 创建多个 SwapChain(多窗口场景)
- SwapChain 可以被销毁再重建(resize 时),Device 不需要跟着重建

## 变化二:CreateSwapChainFor* 的第一个参数为什么变成 Command Queue

### DX11

DX11 里 SwapChain 和 DeviceContext 隐式绑定,Present 是 DeviceContext 的一个方法:

```zig
// DX11(对比用伪代码)
// Present 是 DeviceContext 的方法,驱动内部知道怎么提交
deviceContext.Present(0, 0);
```

### DX12

```zig
// D3D12CreateDevice 之后,先创建 DIRECT 类型的 Command Queue
var command_queue: ?*win32.ID3D12CommandQueue = null;
const queue_desc = win32.D3D12_COMMAND_QUEUE_DESC{
    .Type = win32.D3D12_COMMAND_LIST_TYPE_DIRECT,
    .Flags = .NONE,
};
d3d_device.CreateCommandQueue(&queue_desc, &IID_ID3D12CommandQueue, &command_queue);

// CreateSwapChainFor* 的第一个参数是 command_queue,不是 device
factory.CreateSwapChainForHwnd(
    &hwnd,
    &swap_chain_desc,
    command_queue,
    null,
    &swap_chain
);
```

### 根本原因:DX12 不再有 Immediate Context

这是整个迁移中最核心的设计变化之一:

| 层面 | DX11 | DX12 |
|------|------|------|
| 提交命令的方式 | **隐式**: Immediate Context 是单例,驱动自动串行化 | **显式**: 多个 Command Queue 并行,应用自己决定提交顺序 |
| Present 的归属 | 驱动内部绑定到 Immediate Context | **你必须告诉 SwapChain 用哪个 Queue 来提交 Present 命令** |
| 为什么需要 Device | Device 是"资源工厂",不负责命令执行 | Device 和命令提交解耦了 |

**一句话总结**: DX12 把"画命令"和"显示画好的东西"都变成了你自己显式控制的流程。SwapChain 需要知道往哪个 Queue 里塞 present 命令,而 Device 只是一个资源创建器——所以 SwapChain 必须跟 Queue 绑定,不能跟 Device 绑定。

### 对 initForComposition 的影响

如果你的代码里有 `initForComposition`(绑定到 `Windows.UI.Composition` 的 `SwapChainPanel`),同样的变化:

```
// DX11:
deviceContext -> Present

// DX12:
commandQueue  -> present
// 底层都是 factory.CreateSwapChainForComposition(..., commandQueue, ...)
```

## 总结:DX11 vs DX12 核心设计哲学变化

| 维度 | DX11 | DX12 |
|------|------|------|
| Device 职责 | 同时做资源创建和命令提交 | 只做资源创建 |
| SwapChain 创建 | 和 Device 一步到位 | 用 Factory 单独创建,绑定到 Command Queue |
| Present 路径 | 隐式走 Immediate Context | 显式走你指定的 DIRECT Command Queue |
| 应用的控制粒度 | 粗(驱动决定很多) | 细(应用自己管理线程和资源) |

**迁移 Checklist**:
- 把 `D3D11CreateDeviceAndSwapChain` 拆成:先 `CreateDXGIFactory2` → `D3D12CreateDevice` → `CreateCommandQueue` → `CreateSwapChainFor*`
- `CreateSwapChainFor*` 的第一个参数从 device 改成 DIRECT 类型的 Command Queue
- 理解 SwapChain → Queue 绑定关系,resize 时 SwapChain 重建但 Queue 不动
