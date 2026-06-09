---
date: "2026-04-29"  
category: "技术"  
read_time: "8分钟阅读"  
title: "COM梗概"  
excerpt: "COM梗概"  
tags: ["COM", "Windows"]  
---

这是一组 Windows COM (组件对象模型) 的核心 API 函数，来自 `ole32.dll`。它们主要负责 COM 库的初始化、对象激活、内存管理、线程模型、安全性以及代理/存根 (marshaling) 等底层机制。

下面按功能分组解释这些函数是干什么的：

### 1. 核心初始化与清理
-   **`CoInitializeEx`**：初始化 COM 库。在调用任何其他 COM 函数之前（除了内存分配函数），通常需要先调用它。`dwCoInit` 参数指定线程模型（如 `COINIT_APARTMENTTHREADED` 或 `COINIT_MULTITHREADED`）。**注意：`CoInitialize` 是其早期简化版本**。
-   **`CoUninitialize`**：关闭当前线程上由 `CoInitializeEx` 打开的 COM 库。它会释放所有之前加载的 DLL、取消已注册的类对象等，**必须与 `CoInitializeEx` 配对调用**。

### 2. 内存管理
-   **`CoGetMalloc`**：获取 COM 任务内存分配器 (`IMalloc` 接口)。COM 通常使用 `CoTaskMemAlloc`/`CoTaskMemFree`，这个函数可以让你拿到分配器实例，用于释放由 COM 函数返回（且要求调用者释放）的内存（例如字符串、结构体）。

### 3. 线程与单元 (Apartment) 信息
-   **`CoGetCurrentProcess`**：获取当前进程的唯一 ID（相当于 `GetCurrentProcessId()`）。
-   **`CoGetCallerTID`**：获取当前跨单元调用中调用方的线程 ID。
-   **`CoGetCurrentLogicalThreadId`**：获取当前逻辑线程的标识符（GUID）。
-   **`CoGetContextToken`**：返回当前 COM 上下文的标记（用于内部内存访问）。
-   **`CoGetApartmentType`**：获取当前线程的单元类型（如 `APTTYPE_STA` 或 `APTTYPE_MTA`）。
-   **`CoIncrementMTAUsage` / `CoDecrementMTAUsage`**：引用计数方式保持 MTA（多线程单元）激活。某些需要 MTA 环境的操作可能会调用它们防止提前关闭。

### 4. 对象激活与类工厂
-   **`CoCreateInstance`**：**最常用函数**。根据 CLSID 创建 COM 组件的实例并返回请求的接口。例如 `CoCreateInstance(&CLSID_MyComponent, ...)`。
-   **`CoCreateInstanceEx`**：增强版，允许指定远程服务器信息 (`COSERVERINFO`) 或一次性请求多个接口 (`MULTI_QI` 数组)。
-   **`CoCreateInstanceFromApp`**：为 Windows Store/App 容器提供的受限版本。
-   **`CoGetClassObject`**：获取类工厂 (`IClassFactory`) 接口，而不是直接创建实例。你可以用类工厂控制如何创建对象（比如单例模式）。
-   **`CoRegisterClassObject`**：将 COM 对象的类工厂注册到 COM 中，使其他进程/线程可以激活它（用于实现 COM 服务端）。
-   **`CoRevokeClassObject`**：撤销之前注册的类对象。
-   **`CoResumeClassObjects` / `CoSuspendClassObjects`**：批量暂停/恢复所有已注册类对象的激活请求（用于优化批量注册）。

### 5. 服务器生命周期控制
-   **`CoAddRefServerProcess`** / **`CoReleaseServerProcess`**：增加/减少全局进程中活动服务器对象的计数。当计数从 0 变 1 或从 1 变 0 时，COM 会发出相应通知。通常用于 DLL 服务端控制自己的退出时机。
-   **`CoLockObjectExternal`**：强制锁定或解锁一个对象（增加外部引用计数），防止其意外释放。
-   **`CoDisconnectObject`**：强制断开一个对象与所有客户端的连接（所有远程调用将失败）。

### 6. 代理 (Proxy)、存根 (Stub) 与 Marshaling
-   **`CoGetPSClsid` / `CoRegisterPSClsid`**：获取/注册特定接口的代理/存根组件的 CLSID。用于自定义接口的跨单元/跨进程封送。
-   **`CoCreateFreeThreadedMarshaler`**：创建一个“自由线程封送器”，使原属于单线程单元的对象可以被任意线程直接访问（但需要对象本身支持线程安全）。
-   **`CoCopyProxy`**：复制一个代理对象。
-   **`CoRegisterSurrogate`**：注册一个代理项进程（用于 DLL 服务器在代理进程中运行）。

### 7. 安全性 (Authentication & Impersonation)
-   **`CoInitializeSecurity`**：**关键安全函数**。为整个进程设置 COM 安全级别（认证级别、模拟级别、权限描述符等）。必须在创建任何可聚合对象之前调用。
-   **`CoSetProxyBlanket`** / **`CoQueryProxyBlanket`**：设置/查询一个特定接口代理的安全设置（允许为不同对象指定不同安全级别）。
-   **`CoQueryClientBlanket`**：在服务器端获取调用客户端的认证信息。
-   **`CoImpersonateClient`** / **`CoRevertToSelf`**：模拟客户端的安全上下文（例如用客户端的权限访问资源），然后恢复。
-   **`CoQueryAuthenticationServices`**：查询系统可用的认证服务列表。

### 8. 调用取消机制
-   **`CoEnableCallCancellation`** / **`CoDisableCallCancellation`**：开启/关闭同步调用的取消能力。
-   **`CoSetCancelObject`** / **`CoGetCancelObject`**：设置/获取当前线程的取消对象（用于接收取消通知）。
-   **`CoCancelCall`**：取消指定线程正在挂起的 COM 调用。
-   **`CoTestCancel`**：检查当前调用是否已被请求取消。

### 9. 其他辅助与杂项
-   **`CoFreeUnusedLibraries`** / **`CoFreeUnusedLibrariesEx`**：卸载不再使用的 COM DLL（无活动对象时）。
-   **`CoDisconnectContext`**：断开当前上下文中的所有外部连接（带超时）。
-   **`CoGetCallContext`** / **`CoSwitchCallContext`**：获取/切换当前调用的上下文对象。
-   **`CoIsHandlerConnected`**：判断一个对象是否与它的远程处理程序处于连接状态。
-   **`CoGetObjectContext`**：获取当前对象的 COM 上下文接口。
-   **`CoAllowUnmarshalerCLSID`**：允许特定 CLSID 作为解封器（较新的安全缓解机制）。
-   **`CoRegisterActivationFilter`**：注册激活过滤器（主要用于调试或拦截对象激活）。

### 如何理解这些函数的常见使用场景？

-   **编写 COM 客户端（调用别人组件）**：通常使用 `CoInitializeEx` → `CoCreateInstance` → 调用接口方法 → `CoUninitialize`。可选用到 `CoTaskMemFree`。
-   **编写 COM 服务器（提供自己的组件供别人调用）**：需要 `CoRegisterClassObject`、`CoAddRefServerProcess`/`CoReleaseServerProcess`、可能用到 `CoResumeClassObjects`。以及 DLL 服务器中的 `DllGetClassObject`/`DllCanUnloadNow`。
-   **跨线程/进程传递对象**：依赖代理/存根，会涉及 `CoMarshalInterface`/`CoUnmarshalInterface` 相关函数（不在你列表中，但概念相关）。
-   **安全设置**：调用 `CoInitializeSecurity` 是很多进程的第一步。若省略，COM 会使用部分默认值，但可能不符合你的安全需求。

如果你正要与这些函数打交道，通常先看 `CoInitializeEx`、`CoCreateInstance` 和 `CoUninitialize` 就足够了。大多数其他函数在进阶使用或实现 COM 服务端时才会出现。