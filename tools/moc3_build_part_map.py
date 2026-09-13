#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
从 Live2D 的 .moc3 + .cdi3.json 里解出「ArtMesh(网格) -> Part(图层/部件)」的归属表。

为什么需要它：
  gd_cubism 只暴露 get_meshes()（网格名 -> MeshInstance2D）和 get_part_opacities()，
  没有暴露每个网格属于哪个部件。而 .moc3 二进制里每个 ArtMesh 都带了
  parentPartIndex，.cdi3.json 里又有 Part Id -> 中文名 的对照，
  两者一合就能得到「图层名 -> 它底下所有网格」的完整映射。

用法：
  python tools/moc3_build_part_map.py models/MO/MO.moc3 models/MO/MO.cdi3.json data/parts_MO.json

.moc3 结构要点（format=4，V4.02）：
  header 64B : b'MOC3' + format(1B) + endian(1B)
  [64, 704)  : 160 个 uint32 的段偏移表
  offsets[0] : Counts，23 个 int32：
               0=Parts 1=Deformers 2=WarpDeformers 3=RotationDeformers
               4=ArtMeshes 5=Parameters ...
  offsets[1] : Canvas（ppu, originX, originY, width, height）
  Parts      : space(8B*n) | ids(64B*n) | 6 个 int 数组(最后 1 个是 parentIndex)
  ArtMeshes  : 4 个 space(8B*n) | ids(64B*n) | kfBandIdx, kfIdx, kfCnt, visible,
               enable, parentPartIndex, parentDeformerIndex, texture,
               drawableFlag(1B*n), positionCount, uvIndex, positionIndex,
               vertexCount, drawableMaskIndex, drawableMaskCount
  每个数组按 64 字节对齐。
"""

import io
import json
import os
import struct
import sys


def rdstr(data, off, n):
    out = []
    for i in range(n):
        b = data[off + i * 64: off + i * 64 + 64]
        out.append(b.split(b"\x00")[0].decode("utf-8", "replace"))
    return out


def rdi32(data, off, n):
    return list(struct.unpack("<%di" % n, data[off:off + 4 * n]))


def build(moc3_path, cdi3_path):
    data = open(moc3_path, "rb").read()
    if data[:4] != b"MOC3":
        raise ValueError("not a moc3 file: %s" % moc3_path)
    fmt = data[4]
    if fmt != 4:
        sys.stderr.write("[W] format=%d (only 4 = V4.02 is verified)\n" % fmt)

    offsets = list(struct.unpack("<160I", data[64:64 + 640]))
    counts = list(struct.unpack("<23i", data[offsets[0]:offsets[0] + 92]))
    n_part, n_def, n_am, n_param = counts[0], counts[1], counts[4], counts[5]

    part_ids = rdstr(data, offsets[3], n_part)
    part_parent = rdi32(data, offsets[9], n_part)
    am_ids = rdstr(data, offsets[33], n_am)
    am_parent_part = rdi32(data, offsets[39], n_am)
    am_parent_def = rdi32(data, offsets[40], n_am)
    am_vertex_count = rdi32(data, offsets[46], n_am)

    # ---- 交叉校验，防止偏移推算错了还写出一份假数据 ----
    bad_part = [i for i, v in enumerate(am_parent_part) if v < -1 or v >= n_part]
    bad_def = [i for i, v in enumerate(am_parent_def) if v < -1 or v >= n_def]
    if bad_part:
        raise ValueError("parentPartIndex out of range: %s" % bad_part[:5])
    if bad_def:
        raise ValueError("parentDeformerIndex out of range: %s" % bad_def[:5])
    if min(am_vertex_count) <= 0:
        raise ValueError("vertexCount looks wrong: min=%d" % min(am_vertex_count))

    cdi = json.load(io.open(cdi3_path, encoding="utf-8"))
    name_of = {p["Id"]: p.get("Name", p["Id"]) for p in cdi["Parts"]}
    missing = [pid for pid in part_ids if pid not in name_of]

    parts = []
    for i in range(n_part):
        parts.append({
            "index": i,
            "id": part_ids[i],
            "name": name_of.get(part_ids[i], part_ids[i]),
            "parent": part_parent[i],
            "meshes": [],
        })

    orphan = 0
    mesh_to_part_index = {}
    mesh_to_drawable_index = {}
    for mi in range(n_am):
        pi = am_parent_part[mi]
        mesh_to_drawable_index[am_ids[mi]] = mi
        if 0 <= pi < n_part:
            parts[pi]["meshes"].append(am_ids[mi])
            mesh_to_part_index[am_ids[mi]] = pi
        else:
            orphan += 1

    def path_of(i):
        seg, guard = [], 0
        while i >= 0 and guard < 64:
            seg.append(parts[i]["name"])
            i = parts[i]["parent"]
            guard += 1
        return "/".join(reversed(seg))

    for i, p in enumerate(parts):
        p["path"] = path_of(i)

    return {
        "model": os.path.basename(moc3_path),
        "counts": {"parts": n_part, "artmeshes": n_am, "deformers": n_def, "parameters": n_param},
        "parts_without_cdi3_name": missing,
        "orphan_meshes": orphan,
        "parts": parts,
        # 运行时用：网格名 -> 所属部件下标（配合 get_part_opacities() 判断该部件是否被隐藏）
        "mesh_to_part_index": mesh_to_part_index,
        # 运行时用：网格名 -> drawable 下标（= 绘制顺序，越大约靠上层）
        "mesh_to_drawable_index": mesh_to_drawable_index,
    }


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    moc3, cdi3 = sys.argv[1], sys.argv[2]
    out = sys.argv[3] if len(sys.argv) > 3 else None
    res = build(moc3, cdi3)
    print("[OK] %s : parts=%d artmeshes=%d deformers=%d parameters=%d"
          % (res["model"], res["counts"]["parts"], res["counts"]["artmeshes"],
             res["counts"]["deformers"], res["counts"]["parameters"]))
    print("     parts with meshes: %d / %d   orphan meshes: %d   unnamed: %d"
          % (sum(1 for p in res["parts"] if p["meshes"]), res["counts"]["parts"],
             res["orphan_meshes"], len(res["parts_without_cdi3_name"])))
    if out:
        d = os.path.dirname(out)
        if d:
            os.makedirs(d, exist_ok=True)
        io.open(out, "w", encoding="utf-8").write(json.dumps(res, ensure_ascii=False, indent=1))
        print("     wrote %s" % out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
