---
date: "2026-10-22"
category: "技术"
read_time: "20分钟阅读"
title: "Win32 + Direct2D 手搓 UI 架构模板"
excerpt: "Win32 + Direct2D 手搓 UI 架构模板，覆盖 DirectComposition、Acrylic 与高性能渲染的实践要点。"
tags: ["Win32", "Direct2D", "UI", "架构"]
---

# Win32 + Direct2D 手搓 UI 架构模板

## 适用场景

- 原生 Windows 小工具
- 追求体积小（单个 exe，无运行时依赖）、启动快、性能高
- 需要 DirectComposition / Acrylic / 高性能渲染

---

## 一、核心矛盾

Win32 窗口过程（`windowProc`）天然是**消息驱动的巨大 switch**：

```zig
fn windowProc(hwnd, msg, wparam, lparam) LRESULT {
    switch (msg) {
        WM_PAINT       => { /* 绘制 */ }
        WM_LBUTTONDOWN => { /* 命中检测 + 布局重算 */ }
        WM_SIZE        => { /* 重建资源 */ }
    }
}
```

当 UI 逻辑膨胀时，**所有代码都塞在消息处理里**，导致三个耦合：

| 耦合维度                   | 症状                                      |
| -------------------------- | ----------------------------------------- |
| 数据读取 + 布局计算 + 绘制 | WM_PAINT 里直接读全局状态、算位置、调 D2D |
| 命中检测 + 布局计算        | WM_LBUTTONDOWN 里重新算一遍一模一样的位置 |
| 笔刷创建 + 绘制逻辑        | 绘制路径里按需 CreateSolidColorBrush      |

**解决方案**：把 "读取数据 → 计算布局 → 绘制" 拆成三段，各管各的。

---

## 二、架构：三层两阶段

```
┌────────────────────────────────────────────────────────┐
│                   应用层 (app.zig)                     │
│  WM_PAINT        painer.render(&State)                 │
│  WM_LBUTTONDOWN  painter.hitTest(x, y)                 │
│  WM_SIZE         painter.resize(w, h)                  │
│  WM_DESTROY      painter.deinit()                      │
├────────────────────────────────────────────────────────┤
│                                                        │
│  ┌─────────────────────────────┐                       │
│  │  State (只读快照)           │   ← 纯数据，可测试    │
│  │  - 从 g_app 抓取所需字段    │                       │
│  │  - 不挂方法，不碰 COM       │                       │
│  └─────────────────────────────┘                       │
│                                                        │
│  ┌─────────────────────────────┐                       │
│  │  Painter                    │  ← per-window         │
│  │  - d2d: D2DContext          │    (owns 渲染设备)    │
│  │  - brushes: BrushCache      │    (owns 笔刷)        │
│  │  - layout: LayoutResult     │    (布局缓存)         │
│  │                             │                       │
│  │  render(&State)             │                       │
│  │    ├─ layout(state)         │ 纯数学 → LayoutResult │
│  │    ├─ draw(&layout)         │ 只画                  │
│  │    └─ drawOverlays(state)   │ 额外覆盖层            │
│  │                             │                       │
│  │  hitTest(x, y) → ?Result    │ 查 layout，零计算     │
│  │  resize(w, h)               │ 重建 D2D + 失效笔刷   │
│  └─────────────────────────────┘                       │
│                                                        │
│  ┌─────────────────────────────┐                       │
│  │  D2D 工具层                 │                       │
│  │  - D2DContext               │ 设备 + swapchain      │
│  │  - BrushCache               │ 笔刷 lazy init        │
│  │  - drawRect, drawRR, ...    │ 便利函数              │
│  └─────────────────────────────┘                       │
│                                                        │
└────────────────────────────────────────────────────────┘
```

### 两层工具，三层数据

| 层             | 文件              | 职责                          | 谁持有             |
| -------------- | ----------------- | ----------------------------- | ------------------ |
| **State**      | `state.zig`       | 只读数据快照                  | 临时变量，每帧新建 |
| **Painter**    | `xxx_painter.zig` | layout + draw + hitTest       | 全局 `g_xxx`       |
| **D2DContext** | `d2d.zig`         | D2D 设备、SwapChain、便利方法 | Painter 内         |
| **BrushCache** | `brushes.zig`     | 笔刷 lazy init + invalidate   | Painter 内         |

---

## 三、数据流

### 渲染帧

```
WM_PAINT
  → State{ .field1 = ..., .field2 = ... }     // 抓快照，开销 = 若干指针赋值
  → painter.render(&state)
      → layout(state)                          // 纯数学，产 LayoutResult
      → draw(&layout)                          // 只调 D2D，不查 state
      → drawOverlays(state)                    // 需要实时数据的覆盖层
      → 缓存 layout                            // 供 hitTest 用
  → return 0
```

### 鼠标事件

```
WM_LBUTTONDOWN / WM_MOUSEMOVE / WM_RBUTTONDOWN
  → x = LOWORD(lparam), y = HIWORD(lparam)
  → painter.hitTest(x, y)                      // 查缓存 layout，无计算
  → 分发结果（切换状态、弹出菜单、拖动...）
```

**关键**：命中检测不需要重新算 layout，因为上一次 `render()` 已经算好并存下来了。

---

## 四、D2D 配置模板

### D2DContext (`d2d.zig`)

```zig
pub const D2DContext = struct {
    ctx: *ID2D1DeviceContext,
    swap: *IDXGISwapChain1,
    width: u32,
    height: u32,
    // ... 设备、效果链

    pub fn init(hwnd: HWND, w: u32, h: u32) !D2DContext
    pub fn deinit(self: *D2DContext) void
    pub fn resize(self: *D2DContext, w: u32, h: u32) void

    // 薄封装——把每次的 ID2D1RenderTarget.xxx 包成简短调用
    pub fn fillRoundedRect(self, rect, radius, brush) void
    pub fn drawRoundedRect(self, rect, radius, brush, width) void
    pub fn drawBitmap(self, bmp, rect, opacity) void
    pub fn fillRect(self, rect, brush) void
    pub fn drawText(self, text, rect, brush, format) void  // DWrite
    pub fn hiconToBitmap(self, hicon) !*ID2D1Bitmap         // HICON → D2D
};
```

所有便利方法都是 **1~3 行转发**，不做状态管理，不做缓冲。

### BrushCache (`brushes.zig`)

```zig
pub const BrushCache = struct {
    brush_a: ?*ID2D1SolidColorBrush,
    brush_b: ?*ID2D1SolidColorBrush,
    // 每个 Painter 按需定义自己的笔刷字段

    pub fn init() BrushCache       // 全 null
    pub fn deinit(self) void       // 逐个 Release
    pub fn invalidate(self) void   // resize 后调用，置 null
    pub fn getBrushA(self, ctx) *ID2D1SolidColorBrush  // lazy create
```

笔刷跟随 RenderTarget，`resize()` 重建 target 后必须 `invalidate()`。
下次 getXxx 自动重建，Painter 不需要关心重建时机。

---

## 五、LayoutResult 设计原则

```zig
pub const LayoutResult = struct {
    // 定长数组（避免分配器），每个 Painter 按需定义
    items: [MAX_ITEMS]ItemLayout,
    count: u8,
    overlay_rect: Rect,
    // ...
};
pub const ItemLayout = struct {
    rect: Rect,
    is_active: bool,
    data: usize,  // 关联的业务 id（workspace idx / button id / ...）
};
```

**规则**：
1. 定长数组，不用 `ArrayList`，不用分配器 — Painter 的渲染路径不分配内存
2. `ItemLayout.data` 携带业务 id，`hitTest` 直接返回，Painter 不需要查表
3. `Rect` 同时服务 draw（画在哪）和 hitTest（点在哪）
4. 一次 layout 产出，两个消费者共享

---

## 六、Painter 标准模板

```zig
pub const MyPainter = struct {
    d2d: D2DContext,
    brushes: BrushCache,
    hwnd: HWND,
    layout: LayoutResult,

    pub fn init(hwnd: HWND) !MyPainter {
        var self = MyPainter{
            .d2d = try D2DContext.init(hwnd, ...),
            .brushes = BrushCache.init(),
            .hwnd = hwnd,
            .layout = undefined,
        };
        return self;
    }

    pub fn deinit(self: *MyPainter) void {
        self.brushes.deinit();
        self.d2d.deinit();
    }

    pub fn render(self: *MyPainter, state: *const State) void {
        self.d2d.beginDraw();
        self.d2d.renderBackground();        // Acrylic / Clear
        self.layout = self.layout(state);
        self.draw(&self.layout);
        self.drawOverlays(state);
        self.d2d.endDraw();
    }

    fn layout(self, state: *const State) LayoutResult { /* 纯数学 */ }
    fn draw(self, layout: *const LayoutResult) void { /* 只画 */ }
    fn drawOverlays(self, state: *const State) void { /* 可选 */ }

    pub fn hitTest(self: *const MyPainter, x: f32, y: f32) ?usize {
        for (0..self.layout.count) |i| {
            if (rectContains(self.layout.items[i].rect, x, y))
                return self.layout.items[i].data;
        }
        return null;
    }

    pub fn resize(self: *MyPainter, w: u32, h: u32) void {
        self.d2d.resize(w, h);
        self.brushes.invalidate();
    }
};
```

---

## 七、BrushCache 为什么不能留在 D2DContext 里

笔刷绑定到 RenderTarget。`resize()` 重建 SwapChain + Target 后，所有旧笔刷变成悬空指针。

**设计决策**：笔刷从 D2DContext 中拆出来，单独管理。

```
D2DContext.resize()
  → 内部重建 RenderTarget
  → 外部调 brushes.invalidate()
  → 下次 draw() 调 brushes.getXxx() 自动重建
```

这样 Painter 不需要知道 D2DContext 内部细节。

---

## 八、多窗口怎么办

每个窗口一个 Painter，各自拥有自己的 D2DContext + BrushCache：

```zig
var g_main_bar: ?MainBarPainter = null;
var g_settings: ?SettingsPainter = null;
var g_hud: ?HUDPainter = null;

fn windowProc(hwnd, msg, wparam, lparam) LRESULT {
    // 用 hwnd 分发到正确的 Painter
    if (hwnd == main_bar_hwnd and g_main_bar) |*p| { return handle(p, ...); }
    if (hwnd == settings_hwnd and g_settings) |*p| { return handle(p, ...); }
    return DefWindowProc(...);
}
```

Painter 之间不共享 D2D 资源，只共享 State（只读指针，无锁）。

---

## 九、总结：手搓 UI 的自律约定

1. **State 只有字段，没有方法** — 纯数据，Painter 只读
2. **Painter 持有自己的 D2D** — 不共享设备，不跨窗口冲突
3. **layout 只算一次** — layout 产物同时服务 draw 和 hitTest
4. **draw 只看 LayoutResult** — 不看 State（除非覆盖层）
5. **笔刷 lazy init** — resize 后 invalidate，Painter 不需要知道重建时机
6. **消息函数只调度** — 不写绘制逻辑，不写命中检测逻辑
7. **定长数组** — Painter 渲染路径不分配内存
