# -*- coding: utf-8 -*-
"""把开源医疗知识图谱整理成「搜索词 → 科室」词典，输出 server/data/dept_keywords.csv。

数据来源：QASystemOnMedicalKG（https://github.com/liuhuanyong/QASystemOnMedicalKG）
的 data/medical.json —— 8,808 种疾病，每种标有症状（symptom）和就诊科室
（cure_department）。原项目注明「请勿商用」，本系统为课程设计，非商业用途。

用法（只在更新词典时运行，网站运行时不需要）：
    pip install pypinyin
    python tools/build_dept_keywords.py <medical.json 路径>

处理规则：
  1. 原数据的 54 个科室归并到本院 13 个科室；急诊科不走预约，记在 other_dept 列，
     搜索时提示直接去急诊。
  2. 一种疾病挂多个科室时取最具体的：「外科 + 骨外科」算骨科，「五官科 + 眼科」算眼科。
  3. 疾病名直接对应它的科室；症状按「出现该症状的疾病」在各科的占比给权重，
     占比不到 15% 的科室不收，避免「乏力」这类通用症状把所有科室都拉进来。
  4. 每个词用 pypinyin 生成全拼和首字母，支持 weiyan / wy 这样的拼音搜索。
  5. 「疼」统一写成「痛」（患者常说胃疼、腰疼，数据里多写胃痛、腰痛），
     搜索函数对关键词做同样的替换。
"""
import collections
import re
import csv
import json
import sys
from pathlib import Path

from pypinyin import Style, lazy_pinyin

OUT = Path(__file__).resolve().parent.parent / "server" / "data" / "dept_keywords.csv"

# 本院科室（与 seed_data.DEPARTMENTS 一致）
OUR = {"D01": "内科", "D02": "外科", "D03": "儿科", "D04": "骨科", "D05": "眼科",
       "D06": "妇产科", "D07": "皮肤科", "D08": "耳鼻喉科", "D09": "口腔科", "D10": "中医科",
       "D11": "精神心理科", "D12": "肿瘤科", "D13": "男科"}

# 原数据科室 → 本院科室
TO_OUR = {
    "内科": "D01", "消化内科": "D01", "神经内科": "D01", "心内科": "D01", "呼吸内科": "D01",
    "内分泌科": "D01", "肾内科": "D01", "血液科": "D01", "风湿免疫科": "D01", "传染科": "D01",
    "感染科": "D01", "泌尿内科": "D01", "肝病": "D01",
    "外科": "D02", "普外科": "D02", "心胸外科": "D02", "神经外科": "D02",
    "泌尿外科": "D02", "肛肠科": "D02", "肝胆外科": "D02", "烧伤科": "D02",
    "儿科": "D03", "儿科综合": "D03", "小儿内科": "D03", "小儿外科": "D03",
    "骨外科": "D04",
    "眼科": "D05",
    "妇产科": "D06", "妇科": "D06", "产科": "D06", "不孕不育": "D06", "生殖健康": "D06",
    "皮肤性病科": "D07", "皮肤科": "D07", "性病科": "D07",
    "耳鼻喉科": "D08", "五官科": "D08",
    "口腔科": "D09",
    "中医科": "D10", "中医综合": "D10",
    "精神科": "D11", "心理科": "D11",
    "肿瘤科": "D12", "肿瘤内科": "D12", "肿瘤外科": "D12",
    "男科": "D13",
}
# 让位规则：大内科 / 大外科有更具体的科室时让位（「外科 + 骨外科」算骨科）；
# 「五官科」笼统，同时标了眼科 / 口腔科时让给它们（否则算耳鼻喉科）
GENERIC = {"D01", "D02"}

# 原数据科室 → 本院未开设的科室。急诊不走预约挂号，单独提示
TO_OTHER = {"急诊科": "急诊科"}
# 其余（营养科、康复科、整形美容科、减肥、遗传病科、其他科室 / 综合）不收

# 科室名本身也是搜索词（含常见叫法）
DEPT_WORDS = {
    "D01": ["内科", "大内科"], "D02": ["外科", "普外科"], "D03": ["儿科", "小儿科"],
    "D04": ["骨科", "骨外科", "骨伤科"], "D05": ["眼科"],
    "D06": ["妇产科", "妇科", "产科"], "D07": ["皮肤科"], "D08": ["耳鼻喉科", "五官科"],
    "D09": ["口腔科", "牙科"], "D10": ["中医科", "中医"], "D11": ["精神心理科", "精神科", "心理科"],
    "D12": ["肿瘤科"], "D13": ["男科"],
}
# 人群词：带这些词的搜索优先指向对应科室（如「孩子发烧」→ 儿科）
ALIAS_WORDS = {"D03": ["孩子", "小孩", "宝宝", "儿童", "婴儿", "幼儿", "小儿"],
               "D06": ["孕妇", "怀孕", "孕期"]}
OTHER_WORDS = {"急诊科": ["急诊科", "急诊"]}

SYMPTOM_MIN_SHARE = 0.15
MAX_TERM = 60


def targets_of(depts):
    """一种疾病的就诊科室 → (本院科室集合, 本院未开设的科室集合)。"""
    if "五官科" in depts and ({"眼科", "口腔科", "耳鼻喉科"} & set(depts)):
        depts = [d for d in depts if d != "五官科"]
    ours = {TO_OUR[d] for d in depts if d in TO_OUR}
    if ours - GENERIC:
        ours -= GENERIC
    if ours:
        return ours, set()
    return set(), {TO_OTHER[d] for d in depts if d in TO_OTHER}


def py(term):
    full = "".join(lazy_pinyin(term)).lower()
    abbr = "".join(lazy_pinyin(term, style=Style.FIRST_LETTER)).lower()
    return full[:200], abbr[:60]


def clean(term):
    t = re.sub("疼(?!痛)", "痛", (term or "").strip())
    return t if 1 <= len(t) <= MAX_TERM else ""


def main(src):
    rows = [json.loads(line) for line in open(src, encoding="utf-8") if line.strip()]
    out = {}                                  # (term, kind, dept_id, other) → weight

    def add(term, kind, dept_id, other, weight):
        term = clean(term)
        if term:
            key = (term, kind, dept_id or "", other or "")
            out[key] = max(out.get(key, 0), weight)

    for dept_id, words in DEPT_WORDS.items():
        for w in words:
            add(w, "dept", dept_id, None, 1000)
    for dept_id, words in ALIAS_WORDS.items():
        for w in words:
            add(w, "dept", dept_id, None, 300)
    for other, words in OTHER_WORDS.items():
        for w in words:
            add(w, "dept", None, other, 1000)

    sym_count = collections.defaultdict(collections.Counter)
    for r in rows:
        ours, others = targets_of(r.get("cure_department") or [])
        targets = [(d, None) for d in sorted(ours)] + [(None, o) for o in sorted(others)]
        if not targets:
            continue
        for d, o in targets:
            add(r.get("name"), "disease", d, o, max(1, 100 // len(targets)))
        for s in set(r.get("symptom") or []):
            for t in targets:
                sym_count[s][t] += 1

    for s, cnt in sym_count.items():
        total = sum(cnt.values())
        for (d, o), n in cnt.items():
            share = n / total
            if share >= SYMPTOM_MIN_SHARE:
                add(s, "symptom", d, o, max(1, round(share * 100)))

    OUT.parent.mkdir(parents=True, exist_ok=True)
    with open(OUT, "w", encoding="utf-8", newline="") as f:
        w = csv.writer(f)
        w.writerow(["term", "kind", "dept_id", "other_dept", "weight", "pinyin", "abbr"])
        for (term, kind, d, o), weight in sorted(out.items(), key=lambda x: (x[0][1], x[0][2], x[0][3], x[0][0])):
            full, abbr = py(term)
            w.writerow([term, kind, d, o, weight, full, abbr])

    kinds = collections.Counter(k[1] for k in out)
    print("written %s: %d rows %s" % (OUT, len(out), dict(kinds)))
    per = collections.Counter(OUR.get(k[2]) or ("[未开设]" + k[3]) for k in out)
    for name, n in per.most_common():
        print("  %-12s %d" % (name, n))


if __name__ == "__main__":
    main(sys.argv[1])
