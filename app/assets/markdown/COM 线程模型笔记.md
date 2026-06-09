---
date: "2026-06-09"  
category: "技术"  
read_time: "8分钟阅读"  
title: "COM 线程模型笔记"  
excerpt: "COM 线程模型笔记"  
tags: ["COM", "Windows"]  
---

```markdown
# COM 线程模型笔记

## 一、三种 Apartment 类型

COM 运行时定义了三种公寓（Apartment）类型，描述的是 **线程归属于哪种公寓**：

| 类型    | 全称                       | 说明                                             |
| ------- | -------------------------- | ------------------------------------------------ |
| **STA** | Single-Threaded Apartment  | 单线程公寓，一个线程独占一个公寓                 |
| **MTA** | Multi-Threaded Apartment   | 多线程公寓，多个线程共享一个公寓                 |
| **NTA** | Neutral-Threaded Apartment | 中性线程公寓，任何线程可直接调用（实际使用较少） |

### STA vs MTA 核心区别

| 维度             | STA                                               | MTA                             |
| ---------------- | ------------------------------------------------- | ------------------------------- |
| 线程归属         | 一个线程独占一个公寓                              | 多个线程共享一个公寓            |
| 并发访问         | COM 对象始终只被同一线程调用                      | 多个 MTA 线程可同时访问同一对象 |
| 跨线程调用       | 必须经过消息泵（message pump）**编组（marshal）** | 直接调用，无需编组              |
| 对象线程安全     | 不需要（天然串行访问）                            | 必须自己保证线程安全            |
| 是否需要消息循环 | **需要**（`GetMessage` / `DispatchMessage`）      | 不需要                          |

**简单类比：**

- STA：我在自己的房间里干活，你找我必须敲门排队，我按顺序处理。安全但有开销。
- MTA：大家都在同一个大厅，谁都能直接来找我。快但容易冲突。

### 初始化方式

```c
// Win32 经典 COM
CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);   // STA
CoInitializeEx(NULL, COINIT_MULTITHREADED);        // MTA

// WinRT
RoInitialize(RoInitType::SingleThreaded);   // STA
RoInitialize(RoInitType::MultiThreaded);    // MTA
```

> ⚠️ 注意：WinRT 的公寓模型和经典 COM 的 STA/MTA/NTA **不是完全一一对应的**。

---

## 二、Agile 不是一种 Apartment 类型

这是一个容易混淆的点。

### 概念区分

| 概念            | 回答的问题               | 性质               |
| --------------- | ------------------------ | ------------------ |
| STA / MTA / NTA | "我在哪个公寓里？"       | 线程（公寓）的状态 |
| Agile           | "我能不能跨公寓直接用？" | 对象的一个行为属性 |

- Agile 对象通过实现 `IAgileObject` 接口来声明自己可以在任何公寓中直接使用，无需 marshal。
- **它不是第 4 种公寓类型**，而是对象自身的一个特征标记。

### 在 WinRT 中

WinRT 大量使用 Agile —— 很多运行时类默认就是 agile 的，这是 WinRT 相对于经典 COM 的一个设计改进。

当遇到 **非 agile 的对象**（尤其是遗留 COM 组件）时，如果客户端没有正确处理公寓上下文，就会出问题。

---

## 三、跨公寓调用的超时机制：IMessageFilter

当 **MTA 线程调用 STA 对象** 时，COM 需要把请求通过消息泵投递到 STA 线程。如果 STA 线程迟迟不处理，调用方（MTA 线程）会一直阻塞等待。

### 处理流程

```
1. MTA 线程发起调用 → COM marshal 成窗口消息投递给 STA
2. STA 线程忙 / 没有在泵消息 → 调用方阻塞等待
3. 超时后，COM 调用 IMessageFilter::RetryRejectedCall
4. MessageFilter 返回值决定后续行为：
   - SERVERCALL_REJECTED    → 调用直接失败
   - SERVERCALL_RETRYLATER  → 等一会儿再试
   - 其他策略               → 可以走异步路径
```

### IMessageFilter 接口

```c
HRESULT RetryRejectedCall(
    HWND hwndCallee,    // 被调用方窗口句柄
    DWORD dwTickCount,  // 调用方已等待的毫秒数
    DWORD dwRejectType  // SERVERCALL_REJECTED / SERVERCALL_RETRYLATER
);
// 返回值：>=0 表示重试间隔（毫秒），-1 表示放弃
```

### 默认超时

COM 的默认重试/拒绝超时大概在 **60 秒**左右，但可能受注册表或系统配置影响（具体值待确认）。

---

## 四、STA 线程池（STAPT）

Windows 后来在 `ComBase` 内部引入了 STA 池化机制：

- 系统可以自动管理一批 STA 线程
- 当一个 STA 线程卡住时，可以将新的调用路由到池中另一个 STA 线程
- 这看起来像是"自动切换"，但严格来说不是异步，而是 **换了一个 STA 线程来处理**

---

## 五、Rust/WinRT 中的公寓模型踩坑

`windows-rs`（微软官方 Rust 绑定）和早期的 `winrt` crate 在公寓模型上都有过问题。

### 1. 默认公寓类型与 Rust 异步运行时冲突

Rust 异步运行时（tokio 等）天然倾向于多线程，所以很多 crate 默认走 MTA。但某些 WinRT API（比如涉及 UI 的）要求在 STA 中调用，产生冲突。

### 2. STA 需要消息泵，Rust 默认没有

STA 依赖 `GetMessage` / `DispatchMessage` 消息循环来编组跨公寓调用。Rust 的 async runtime 不自带这套机制，导致：

- 跨公寓调用直接挂起或死锁
- 某些 COM 对象创建失败

### 3. Agile 对象的判断和 Marshal

并非所有对象都是 agile 的。Rust 端在判断对象是否 agile 以及是否需要 marshal 上，有段时间处理得不完善。

### 相关资源

- `windows-rs` GitHub Issues（搜 `apartment`、`STA`、`MTA`、`marshal`）
- Kenny Kerr 的博客（windows.com）

---

## 六、概念关系总览

```
公寓类型（Thread 层面）          对象属性（Object 层面）
┌─────────────────────┐        ┌──────────────────────┐
│  STA                │        │  Agile               │
│  MTA                │        │  (IAgileObject)      │
│  NTA                │        │  非 Agile             │
└─────────────────────┘        └──────────────────────┘
        │                               │
        └───────── 跨公寓调用时 ─────────┘
                        │
              ┌─────────┴─────────┐
              │  需要 Marshal？    │
              │  IMessageFilter？  │
              │  走消息泵？        │
              └───────────────────┘
```

---

*最后更新：基于与 MiMo 的讨论整理，部分内容（如默认超时时间）尚需自行验证。*