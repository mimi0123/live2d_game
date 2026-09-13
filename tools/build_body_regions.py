#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
把细碎的 Live2D 部件(Part)归并成「大部件」(身体部位)，用于鼠标互动时的命中分区。

输入：tools/moc3_build_part_map.py 产出的 data/parts_*.json
输出：data/body_regions_*.json
      regions[] 里每个大部件带：id / 中文标签 / 包含的部件 / 包含的 ArtMesh 列表
      mesh_to_region 是运行时直接查的那张表：网格名 -> 大部件 id

为什么需要它：
  MO 这种换装模型有 293 个部件、212 个带网格，其中绝大多数是「眼影款式3」「挑染2」这类
  小开关，直接拿来当互动区毫无意义。真正的做法是按中文图层路径做关键字归并，
  压到十来个「手 / 腿 / 衣服 / 头发 / 脸 ...」这种粒度。

调规则：改下面的 RULES 就行，顺序敏感，**先命中者优先**。
参考的业界惯例：官方 Cubism SDK 只有 Head / Body 两个区，重叠时 Head 优先；
社区常见扩展是 Head / Body / Left / Right / Other，以及 Area1..Area9。
本工程不用官方那套（模型没有 HitAreas），改用自己的关键字归并 + 实时三角形命中。
"""

import io
import json
import os
import sys

# ---------------- 规则表：先命中者优先 ----------------
RULES = [
    # (大部件 id, 中文标签, 关键字列表)
    ("hair", "头发", ["发", "刘海", "辫", "麻花", "呆毛", "挑染", "鬓角", "后脑勺", "马尾", "发丝"]),
    ("tail", "尾巴", ["鱼尾", "尾鳍", "尾巴", "尾部", "尾"]),
    ("leg", "腿/足", ["腿", "足", "脚", "鞋", "袜"]),
    ("arm", "手/臂", ["手", "臂"]),
    ("headwear", "头饰", ["耳", "角", "光环", "皇冠", "眼镜", "蝴蝶结", "荷包蛋",
                          "头饰", "发饰", "帽子", "魅魔", "独角兽", "头纱", "额饰", "额"]),
    ("face", "脸/五官", ["脸", "五官", "眼", "眉", "嘴", "鼻", "腮红", "唇", "齿",
                         "舌", "瞳", "睫毛", "眼线", "表情", "泪", "汗"]),
    ("neck", "肩颈", ["脖", "颈", "肩"]),
    ("clothes", "衣服", ["衣", "裙", "裤", "外套", "布料", "领", "校徽", "胸针",
                         "花纹", "抹胸", "内衣", "袖", "袍", "披肩", "腰链", "链条"]),
    ("torso", "躯干", ["胸", "腰", "腹", "身体", "上身", "下身", "躯干"]),
    ("other", "其他/挂件", []),  # 兜底，放最后
]

REGION_LABEL = {r[0]: r[1] for r in RULES}
REGION_ORDER = [r[0] for r in RULES]


def classify(path, name):
    """按规则表把部件归到一个大部件。先匹配完整路径，再退回部件名。"""
    for rid, _label, keys in RULES:
        if not keys:
            continue
        for k in keys:
            if k in path:
                return rid
    for rid, _label, keys in RULES:
        if not keys:
            continue
        for k in keys:
            if k in name:
                return rid
    return "other"


def build(parts_json):
    d = json.load(io.open(parts_json, encoding="utf-8"))
    regions = {rid: {"id": rid, "label": REGION_LABEL[rid], "parts": [], "meshes": []}
               for rid in REGION_ORDER}
    mesh_to_region = {}
    for p in d["parts"]:
        if not p["meshes"]:
            continue
        rid = classify(p.get("path", ""), p.get("name", ""))
        regions[rid]["parts"].append({
            "index": p["index"],
            "name": p["name"],
            "path": p.get("path", ""),
            "mesh_count": len(p["meshes"]),
        })
        regions[rid]["meshes"].extend(p["meshes"])
        for mn in p["meshes"]:
            mesh_to_region[mn] = rid
    # 透传运行时需要的两张索引表
    mesh_to_part_index = d.get("mesh_to_part_index", {})
    mesh_to_drawable_index = d.get("mesh_to_drawable_index", {})
    for rid in REGION_ORDER:
        regions[rid]["part_count"] = len(regions[rid]["parts"])
        regions[rid]["mesh_count"] = len(regions[rid]["meshes"])
    return {
        "model": d.get("model", ""),
        "rule_version": 1,
        "regions": [regions[rid] for rid in REGION_ORDER],
        "mesh_to_region": mesh_to_region,
        "mesh_to_part_index": mesh_to_part_index,
        "mesh_to_drawable_index": mesh_to_drawable_index,
        "mesh_total": len(mesh_to_region),
    }


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    src = sys.argv[1]
    out = sys.argv[2] if len(sys.argv) > 2 else None
    res = build(src)
    print("[OK] %s : %d meshes -> regions" % (res["model"], res["mesh_total"]))
    print("     %-12s %-10s %8s %8s" % ("id", "标签", "部件数", "网格数"))
    for r in res["regions"]:
        if r["mesh_count"] == 0:
            continue
        bar = "#" * min(40, r["mesh_count"] // 8)
        print("     %-12s %-10s %8d %8d  %s" % (r["id"], r["label"], r["part_count"],
                                                r["mesh_count"], bar))
    if out:
        dd = os.path.dirname(out)
        if dd:
            os.makedirs(dd, exist_ok=True)
        io.open(out, "w", encoding="utf-8").write(json.dumps(res, ensure_ascii=False, indent=1))
        print("     wrote %s" % out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
