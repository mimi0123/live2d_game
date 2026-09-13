#!/usr/bin/env python
# -*- coding: utf-8 -*-
r"""
moc3_analyze_rig.py - 分析 Live2D .moc3 的绑定质量指标，用于「对标优秀模型」。

用途：把已完成模型（尤其是公认优秀的商业/官方模型）当作标准，量化出它的
      · 变形器树深度分布
      · Warp Deformer 转换分割数（rows x cols）分布
      · ArtMesh 顶点数分布（= 布点密度）
      · ArtMesh 挂到 deformer 的比例
      · Part 树结构
    然后照着这些指标去布自己的模型。

依赖：py-moc3（pip install py-moc3，MIT，零依赖）
用法：
    python tools\moc3_analyze_rig.py <model.moc3>
    python tools\moc3_analyze_rig.py <model.moc3> --parts
    python tools\moc3_analyze_rig.py <model.moc3> --json out.json
"""
import sys
import os
import io
import json
import argparse
from collections import Counter

try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass

try:
    from moc3 import Moc3
except ImportError:
    sys.stderr.write("需要 py-moc3：pip install py-moc3\n")
    sys.exit(1)


def g(m, key, default=None):
    try:
        return m[key]
    except Exception:
        return default


def analyze(path):
    m = Moc3.from_file(path)
    d_ids  = g(m, "deformer.ids", []) or []
    d_type = g(m, "deformer.types", []) or []
    d_pdef = g(m, "deformer.parent_deformer_indices", []) or []
    d_ppar = g(m, "deformer.parent_part_indices", []) or []
    d_spec = g(m, "deformer.specific_indices", []) or []
    w_rows = g(m, "warp_deformer.rows", []) or []
    w_cols = g(m, "warp_deformer.cols", []) or []
    p_ids  = g(m, "part.ids", []) or []
    p_ppar = g(m, "part.parent_part_indices", []) or []
    am_ids = g(m, "art_mesh.ids", []) or []
    am_pdef= g(m, "art_mesh.parent_deformer_indices", []) or []
    am_vc  = g(m, "art_mesh.vertex_counts", []) or []

    n_def = len(d_ids)
    n_warp = len(w_rows)
    n_rot = n_def - n_warp

    # type 编码：数量最多的那个是 warp（实测 warp=0, rotation=1）
    tc = Counter(d_type)
    t_warp = tc.most_common(1)[0][0] if tc else 0

    # 变形器树深度
    cache = {}

    def depth_of(i):
        if i < 0 or i >= n_def:
            return 0
        if i in cache:
            return cache[i]
        cache[i] = 1  # 防环
        if i < len(d_pdef):
            cache[i] = 1 + depth_of(d_pdef[i])
        return cache[i]

    depths = [depth_of(i) for i in range(n_def)]

    # Warp 转换分割数
    divs = Counter()
    for i, t in enumerate(d_type):
        if t == t_warp and i < len(d_spec):
            si = d_spec[i]
            if 0 <= si < len(w_rows):
                divs["%dx%d" % (w_rows[si], w_cols[si])] += 1

    # ArtMesh 顶点数
    vc = sorted(am_vc) if am_vc else []
    n_am = len(vc)
    vstat = {}
    if n_am:
        vstat = {
            "min": vc[0],
            "p25": vc[n_am // 4],
            "median": vc[n_am // 2],
            "p75": vc[n_am * 3 // 4],
            "mean": int(sum(vc) / n_am),
            "max": vc[-1],
        }

    bound = sum(1 for x in am_pdef if x is not None and x >= 0)

    return {
        "file": path,
        "counts": {
            "parts": len(p_ids),
            "deformers": n_def,
            "warp": n_warp,
            "rotation": n_rot,
            "art_meshes": n_am,
            "parameters": len(g(m, "parameter.ids", []) or []),
        },
        "deformer_depth_hist": dict(sorted(Counter(depths).items())),
        "deformer_depth_max": max(depths) if depths else 0,
        "warp_divisions_top": divs.most_common(12),
        "artmesh_vertex_stats": vstat,
        "artmesh_bound_ratio": "%.1f%%" % (100.0 * bound / n_am) if n_am else "n/a",
        "deformer_per_mesh": "%.2f" % (n_def / n_am) if n_am else "n/a",
        "_part_ids": p_ids,
        "_part_parents": p_ppar,
    }


def print_report(r, show_parts=False):
    c = r["counts"]
    print("=" * 56)
    print("文件: %s" % r["file"])
    print("=" * 56)
    print("部件 %-6d 变形器 %-6d (Warp %d / Rotation %d)"
          % (c["parts"], c["deformers"], c["warp"], c["rotation"]))
    print("ArtMesh %-5d 参数 %-5d  变形器/网格 = %s"
          % (c["art_meshes"], c["parameters"], r["deformer_per_mesh"]))
    print()
    print("变形器树最大深度: %d" % r["deformer_depth_max"])
    print("深度分布(层:个数): %s" % r["deformer_depth_hist"])
    print()
    print("Warp 转换分割数 top:")
    for k, v in r["warp_divisions_top"]:
        print("   %-10s %d" % (k, v))
    print()
    vs = r["artmesh_vertex_stats"]
    if vs:
        print("ArtMesh 顶点数: min=%d  p25=%d  中位=%d  p75=%d  均值=%d  max=%d"
              % (vs["min"], vs["p25"], vs["median"], vs["p75"], vs["mean"], vs["max"]))
    print("挂到 deformer 的 ArtMesh 比例: %s" % r["artmesh_bound_ratio"])

    if show_parts:
        print()
        print("Part 树:")
        p_ids = r["_part_ids"]
        p_par = r["_part_parents"]
        kids = {}
        for i, pid in enumerate(p_ids):
            pa = p_par[i] if i < len(p_par) else -1
            kids.setdefault(pa, []).append((i, pid))

        def walk(i, lv):
            for ci, cid in kids.get(i, []):
                print("   " + "  " * lv + "- " + str(cid))
                walk(ci, lv + 1)

        walk(-1, 0)


def main():
    ap = argparse.ArgumentParser(description="分析 moc3 绑定质量指标")
    ap.add_argument("moc3", help="模型 .moc3 路径")
    ap.add_argument("--parts", action="store_true", help="打印 Part 树")
    ap.add_argument("--json", help="把结果写成 JSON 到指定路径")
    a = ap.parse_args()

    if not os.path.isfile(a.moc3):
        sys.stderr.write("找不到文件: %s\n" % a.moc3)
        sys.exit(2)

    r = analyze(a.moc3)
    print_report(r, a.parts)

    if a.json:
        out = {k: v for k, v in r.items() if not k.startswith("_")}
        with io.open(a.json, "w", encoding="utf-8") as f:
            json.dump(out, f, ensure_ascii=False, indent=2)
        print("\nJSON 已写出: %s" % a.json)


if __name__ == "__main__":
    main()
