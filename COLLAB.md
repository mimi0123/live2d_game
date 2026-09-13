# 协作说明（LobsterAI ↔ WorkBuddy 共享 J:\live2d_game）

> 本文件供两位 AI 助手协作时阅读，避免互相踩脚。Master 睡觉期间双方都在推进本项目。

## 当前分工

| 模块 | 负责人 | 说明 |
| --- | --- | --- |
| `scripts/gd/region/region_detector.gd`（autoload RegionDetector） | LobsterAI | 点击模型部位 → 画布坐标 → 区域名，调 `Dialogue.say(region, random_order)`；F4 显示区域矩形 |
| `scripts/gd/region/region_overlay.gd` | LobsterAI | 区域矩形可视化 |
| `data/regions.json` | LobsterAI | 区域定义（头/胸/手/腿/衣服，矩形用中心坐标） |
| `data/dialogue.json` | LobsterAI | 遗留台词数据（新引擎无 interaction_data.json 时的回退） |
| `scripts/gd/debug/debug_panel.gd`（autoload DebugPanel，F3） | LobsterAI | 调试面板：切模型/表情/动作/命中区域/台词编辑（写 dialogue.json） |
| `scripts/gd/dialogue/dialogue_manager.gd`（autoload Dialogue） | WorkBuddy | 阶段/好感度引擎（phases/zones/score），`say()`→`interact()`，F5 编辑器 |
| `scripts/gd/ui/interact_editor.gd` | WorkBuddy | F5 互动编辑器 |
| `data/interaction_data.json` | WorkBuddy | 阶段/好感数据（user:// 优先） |

## 接入约定（已对接）

1. RegionDetector 点击区域 → `Dialogue.say(region, random_order)` → 路由到 `interact(zone_id)`。
2. `regions.json` 的区域名 = `interact()` 的 zone_id（头/胸/手/腿/衣服…）。
3. 新引擎无 interaction_data.json 时，`interact()` 回退到 `_legacy_line()` 读 `data/dialogue.json`——所以 LobsterAI 的遗留台词仍然生效。

## 已做的修复（LobsterAI 于 08-31 早）

1. `dialogue_manager.gd` 的 `JSON.stringify(out, "\t", "\t")` 第 3 参应为 bool → 已改为 `JSON.stringify(out, "\t")`。
2. 其余为新增文件，未改动 WorkBuddy 的交互引擎逻辑。

## 注意

- 调试快捷键：F3 调试面板（LobsterAI）/ F4 区域矩形（LobsterAI）/ F5 互动编辑器（WorkBuddy）/ 1-5 测试各部位。
- 换模型后区域矩形需按模型画布坐标重调（regions.json）。
- interact_editor.gd 目前有「分隔符重复挂载」的运行时告警（Can't add child 'sep_xxx' already has a parent），属于 WorkBuddy 域，未代改。
