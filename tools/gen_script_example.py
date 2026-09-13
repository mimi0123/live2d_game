#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""从 interaction_data.json 生成纯文本作者脚本 interaction_script.txt.example。"""
import json, os

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
src = os.path.join(BASE, "data", "interaction_data.json")
out = os.path.join(BASE, "data", "interaction_script.txt.example")

with open(src, "r", encoding="utf-8") as f:
    data = json.load(f)

def sign(n):
    if n > 0:
        return "+%d" % n
    return "%d" % n

lines = []
lines.append("# ============================================================")
lines.append("# 互动对话 · 纯文本作者脚本  v1")
lines.append("# ============================================================")
lines.append("# 用法：把下面这套格式的内容存成  interaction_script.txt")
lines.append("#       （放在 data/ 目录，与本范例同目录），在游戏里按 F6，")
lines.append("#       或打开 F5 编辑器点「导入文本脚本」，即可批量导入。")
lines.append("#")
lines.append("# 规则：")
lines.append("#   · # 开头的整行是注释，会被忽略；空行也忽略。")
lines.append("#   · 角色名 / 好感可降 是可选全局设置（不写就用游戏里现有的）。")
lines.append("#   · == 阶段头 ==  ：  == <阶段id> | <阶段名> | <解锁分> ==")
lines.append("#   · 进入: 台词      ：进入该阶段时播放的台词（可写多行）。")
lines.append("#   · -- 部位头 --    ：  -- <部位id> | <显示名> | <得分±> [| 随机] --")
lines.append("#                      得分可正可负；加 「随机」 则每次随机抽一句。")
lines.append("#   · 普通行          ：属于上一个 --部位-- 的台词。")
lines.append("#                      行尾可跟  | expr=表情名 | voice=语音文件 （可选）。")
lines.append("#   · 部位id 必须和 regions.json 里的区域名一致（如 头/胸/手/腿/衣服）。")
lines.append("#   · 注意：台词文本里不要出现竖线 | （它用来分隔 表情/语音）。")
lines.append("# ============================================================")
lines.append("")

lines.append("角色名: %s" % data.get("default_speaker", ""))
lines.append("好感可降: %s" % ("是" if data.get("score_can_go_negative", True) else "否"))
lines.append("")

for ph in data.get("phases", []):
    lines.append("== %s | %s | %d ==" % (ph.get("id", ""), ph.get("name", ""), int(ph.get("unlock_score", 0))))
    for ud in ph.get("unlock_dialogue", []):
        expr = ud.get("expr", "")
        suffix = (" | expr=" + expr) if expr else ""
        lines.append("进入: %s%s" % (ud.get("text", ""), suffix))
    for zid, z in ph.get("zones", {}).items():
        label = z.get("label", zid)
        score = sign(int(z.get("score", 0)))
        rand = " | 随机" if z.get("random", False) else ""
        lines.append("-- %s | %s | %s%s --" % (zid, label, score, rand))
        for ln in z.get("lines", []):
            expr = ln.get("expr", "")
            voice = ln.get("voice", "")
            suffix = ""
            if expr:
                suffix += " | expr=" + expr
            if voice:
                suffix += " | voice=" + voice
            lines.append("%s%s" % (ln.get("text", ""), suffix))
    lines.append("")

with open(out, "w", encoding="utf-8") as f:
    f.write("\n".join(lines))

print("written:", out)
