# Live2D 互动游戏（Godot 4.7）

Godot 4.7.1 + gd_cubism 的 Live2D 桌宠互动游戏工程。

- **SoftTouch 软体触摸**：HandContact 虚拟手（掌心 + 3 指）→ 压力场 → 多触点合并 → ArtMesh 顶点形变（含幂等基准 / cross_limit 几何上限）
- **ShadowBrush 阴影画笔**：独立于物理形变的动态阴影系统（模型空间，随压强映射 alpha / scale）
- **音游模块**：双轨判定 / 结算 / 谱面生成工具

## 运行

1. 安装 Godot 4.7.1（标准版）
2. 安装 [gd_cubism](https://github.com/MizunagiKun/gd_cubism) GDExtension 插件到 `addons/gd_cubism/`
3. 将 Live2D 模型放入 `models/`（本仓库未包含模型与音频资产）
4. 用 Godot 打开 `project.godot`，运行 `scenes/main.tscn`

> 注：`models/`、`audio/`、`engine/`、`fonts/` 未入库（体积/版权），克隆后需自行补齐。