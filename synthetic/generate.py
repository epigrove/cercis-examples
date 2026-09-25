#!/usr/bin/env python3
"""生成 S6 黄金对照验收用的**合成数据**（虚构，不含任何真实研究数据）。

设计要点（这些"故意做出来的毛病"就是验收要抓的东西）：

1. 缺失值      —— 3 个数值留空，验证"缺失数"统计口径
2. 极端值      —— 1 个产量明显离谱（99.9），验证报告里的极值呈现
3. 平行样      —— 4 个样本的同一指标测了两次，验证平行样极差
4. 更正记录    —— 1 处誊写笔误走 correct（不覆盖原值），验证"原始值保留 + 分析用更正值"
5. 多级引用    —— 观测 → 样本 → 事件/单元 → 研究，验证跨表 join 与引用完整性

用法：
    python3 generate.py            # 写入 inputs/ 与 expected.json

输出是**确定性**的（不用随机数），任何人重跑都得到同样的字节。
"""

import csv
import json
import hashlib
from pathlib import Path

HERE = Path(__file__).resolve().parent
INPUTS = HERE / "inputs"
ASSETS = HERE / "assets"

# ── 试验设计（全部虚构）──────────────────────────────────────────────────
STUDY = {
    "study_id": "ST-2026-001",
    "name": "合成示例：水稻氮肥用量试验",
    "stage": "田间试验",
    "start_date": "2026-04-10",
    "end_date": "2026-09-20",
    "notes": "虚构数据，仅用于 Cercis 黄金对照验收",
}

TREATMENTS = {
    "T0": "不施氮",
    "T1": "低氮 90 kg/ha",
    "T2": "中氮 180 kg/ha",
    "T3": "高氮 270 kg/ha",
}
# 随机区组：3 个区组 × 4 个处理，处理顺序按区组轮换
UNIT_TREATMENTS = [
    "T0", "T1", "T2", "T3",
    "T2", "T3", "T0", "T1",
    "T1", "T0", "T3", "T2",
]

EVENTS = [
    {"event_id": "EV-001", "study_id": STUDY["study_id"], "date": "2026-04-10",
     "stage": "播种", "event_type": "田间操作", "title": "播种", "notes": ""},
    {"event_id": "EV-002", "study_id": STUDY["study_id"], "date": "2026-06-15",
     "stage": "分蘖期", "event_type": "取样", "title": "分蘖期土壤取样", "notes": ""},
    {"event_id": "EV-003", "study_id": STUDY["study_id"], "date": "2026-07-20",
     "stage": "抽穗期", "event_type": "取样", "title": "抽穗期植株取样", "notes": ""},
    {"event_id": "EV-004", "study_id": STUDY["study_id"], "date": "2026-09-18",
     "stage": "成熟期", "event_type": "收获", "title": "小区收获测产", "notes": ""},
]

# 每个处理的"真实"效应（合成，用来产生有规律的数字）
TREATMENT_EFFECT = {"T0": 0.0, "T1": 4.5, "T2": 8.0, "T3": 9.5}


def unit_id(i: int) -> str:
    return f"U-{i:03d}"


def build():
    units = []
    for i, trt in enumerate(UNIT_TREATMENTS, start=1):
        units.append({
            "unit_id": unit_id(i),
            "study_id": STUDY["study_id"],
            "treatment_id": trt,
            "notes": "",
        })

    # 样本：分蘖期土壤 12 个 + 抽穗期植株 12 个 + 1 组"混合样拆分"
    samples = []
    n = 0
    for i in range(1, 13):
        n += 1
        samples.append({
            "sample_id": f"S-{n:03d}",
            "event_id": "EV-002",
            "unit_id": unit_id(i),
            "parent_sample_id": "",
            "sample_type": "土壤",
            "notes": "",
        })
    for i in range(1, 13):
        n += 1
        samples.append({
            "sample_id": f"S-{n:03d}",
            "event_id": "EV-003",
            "unit_id": unit_id(i),
            "parent_sample_id": "",
            "sample_type": "植株",
            "notes": "",
        })
    # 混合样拆分成两个子样（parent_sample_id 指向 S-013）
    for k in (1, 2):
        n += 1
        samples.append({
            "sample_id": f"S-{n:03d}",
            "event_id": "EV-003",
            "unit_id": "U-004",
            "parent_sample_id": "S-013",
            "sample_type": "植株",
            "notes": f"混合样拆分（子样 {k}）",
        })

    obs = []           # 原始录入值（含 1 处笔误）
    corrections = []   # 更正记录
    o = 0

    def add(sample_id, trait, value, unit, batch, date, notes=""):
        nonlocal o
        o += 1
        obs.append({
            "obs_id": f"OB-{o:04d}",
            "sample_id": sample_id,
            "trait_id": trait,
            "value_num": value,
            "unit": unit,
            "batch_id": batch,
            "measured_at": date,
            "notes": notes,
        })
        return obs[-1]["obs_id"]

    # 分蘖期：土壤碱解氮（kg/ha），12 个样本
    for i, s in enumerate(samples[:12]):
        trt = UNIT_TREATMENTS[i]
        value = 62 + TREATMENT_EFFECT[trt] * 2.4 + (i % 3) * 1.7
        v = "" if s["sample_id"] == "S-003" else f"{value:.1f}"   # 故意缺失
        add(s["sample_id"], "soil_n_kg_ha", v, "kg/ha", "BATCH-2026-0615", "2026-06-15")

    # 抽穗期：株高 / SPAD / 小区产量，12 个样本（S-013 ~ S-024）
    plant = samples[12:24]
    for i, s in enumerate(plant):
        sid = s["sample_id"]
        trt = UNIT_TREATMENTS[i]
        height = 78 + TREATMENT_EFFECT[trt] * 2.6 + (i % 4) * 2.1
        spad = 34 + TREATMENT_EFFECT[trt] * 0.9 + (i % 3) * 0.8
        yield_kg = 5.4 + TREATMENT_EFFECT[trt] * 0.32 + (i % 3) * 0.21

        add(sid, "height_cm", f"{height:.1f}", "cm", "BATCH-2026-0720", "2026-07-20")

        spad_value = f"{spad:.2f}"
        if sid == "S-022":
            spad_value = ""                                        # 故意缺失
        obs_id = add(sid, "spad", spad_value, "SPAD", "BATCH-2026-0720", "2026-07-20")
        # 誊写笔误：把 40.50 记成了 34.50，留一条更正
        if sid == "S-014":
            obs[-1]["value_num"] = "34.50"
            corrections.append({
                "correction_id": "C-000001",
                "target_table": "observations",
                "target_id": obs_id,
                "field": "value_num",
                "old_value": "34.50",
                "new_value": spad_value,
                "reason": "誊写笔误，核对原始记录后更正（合成示例）",
                "source_ref": "verify/golden",
            })

        y = "" if sid == "S-021" else f"{yield_kg:.2f}"
        if sid == "S-024":
            y = "99.90"                                            # 故意极端值
        add(sid, "yield_kg_plot", y, "kg", "BATCH-2026-0918", "2026-09-18")

    # 平行样：S-017 ~ S-020 的 SPAD 各测两次
    for i, s in enumerate(plant):
        if s["sample_id"] in ("S-017", "S-018", "S-019", "S-020"):
            trt = UNIT_TREATMENTS[i]
            base = 34 + TREATMENT_EFFECT[trt] * 0.9 + (i % 3) * 0.8
            add(s["sample_id"], "spad", f"{base + 1.2:.2f}", "SPAD",
                "BATCH-2026-0720", "2026-07-20", "平行样复测")

    return units, samples, obs, corrections


def write_csv(path: Path, rows, columns):
    with path.open("w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=columns, lineterminator="\n")
        w.writeheader()
        for r in rows:
            w.writerow({c: r.get(c, "") for c in columns})


def to_float(v):
    return None if v in ("", None) else float(v)


def mean(xs):
    xs = [x for x in xs if x is not None]
    return round(sum(xs) / len(xs), 4) if xs else None


def rng(xs, digits=4):
    xs = [x for x in xs if x is not None]
    return None if not xs else round(max(xs) - min(xs), digits)


def expected(units, samples, obs, corrections):
    """地面真值：由生成器按"原始录入值 + 更正"两条口径各算一遍。"""
    by_id = {s["sample_id"]: s for s in samples}
    unit_trt = {u["unit_id"]: u["treatment_id"] for u in units}

    def treatment_of(row):
        sample = by_id[row["sample_id"]]
        return unit_trt[sample["unit_id"]]

    traits = ["soil_n_kg_ha", "height_cm", "spad", "yield_kg_plot"]
    raw, corrected = {}, {}
    for t in traits:
        rows = [r for r in obs if r["trait_id"] == t]
        raw[t] = {
            "count": sum(1 for r in rows if r["value_num"] != ""),
            "mean": mean([to_float(r["value_num"]) for r in rows]),
            "min": min([to_float(r["value_num"]) for r in rows if r["value_num"] != ""], default=None),
            "max": max([to_float(r["value_num"]) for r in rows if r["value_num"] != ""], default=None),
        }
        fix = {c["target_id"]: to_float(c["new_value"]) for c in corrections}
        values = [fix.get(r["obs_id"], to_float(r["value_num"])) for r in rows]
        corrected[t] = {
            "count": sum(1 for v in values if v is not None),
            "mean": mean(values),
            "min": min([v for v in values if v is not None], default=None),
            "max": max([v for v in values if v is not None], default=None),
        }

    # 按处理分组的均值（原始口径；分析口径在 R 里单独算）
    groups = {}
    for t in traits:
        g = {}
        for trt in TREATMENTS:
            vals = [to_float(r["value_num"]) for r in obs
                    if r["trait_id"] == t and treatment_of(r) == trt]
            g[trt] = mean(vals)
        groups[t] = g

    # 平行样极差：同一样本 + 同一指标 + 同一测定日期，测了多次
    pairs = {}
    for r in obs:
        if r["value_num"] == "":
            continue
        key = (r["sample_id"], r["trait_id"], r["measured_at"])
        pairs.setdefault(key, []).append(to_float(r["value_num"]))
    # 键 = 样本 | 指标 | 测定日期（R 侧用同样的键，便于逐项对账）
    parallel = {f"{k[0]}|{k[1]}|{k[2]}": round(max(v) - min(v), 4)
                for k, v in pairs.items() if len(v) > 1}

    return {
        "tables": {
            "studies": 1,
            "units": len(units),
            "events": len(EVENTS),
            "samples": len(samples),
            "observations": len(obs),
        },
        "observations": {
            "total": len(obs),
            "missing_value": sum(1 for r in obs if r["value_num"] == ""),
            "unique_obs_id": len({r["obs_id"] for r in obs}),
        },
        "raw": raw,
        "corrected": corrected,
        "treatment_means_raw": groups,
        "parallel_ranges": parallel,
        "correction": {
            "count": len(corrections),
            "target_id": corrections[0]["target_id"] if corrections else None,
            "old_value": corrections[0]["old_value"] if corrections else None,
            "new_value": corrections[0]["new_value"] if corrections else None,
        },
    }


def tiny_png(path: Path):
    """写一张 2×2 的合法 PNG（合成"田间照片"占位符）。"""
    import struct
    import zlib

    def chunk(tag, data):
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

    ihdr = struct.pack(">IIBBBBB", 2, 2, 8, 2, 0, 0, 0)
    raw = b"".join(b"\x00" + bytes([0x2E, 0x7D, 0x32] * 2) for _ in range(2))
    png = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr)
           + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))
    path.write_bytes(png)


def main():
    INPUTS.mkdir(parents=True, exist_ok=True)
    ASSETS.mkdir(parents=True, exist_ok=True)

    units, samples, obs, corrections = build()

    write_csv(INPUTS / "studies.csv", [STUDY],
              ["study_id", "name", "stage", "start_date", "end_date", "notes"])
    write_csv(INPUTS / "units.csv", units,
              ["unit_id", "study_id", "treatment_id", "notes"])
    write_csv(INPUTS / "events.csv", EVENTS,
              ["event_id", "study_id", "date", "stage", "event_type", "title", "notes"])
    write_csv(INPUTS / "samples.csv", samples,
              ["sample_id", "event_id", "unit_id", "parent_sample_id", "sample_type", "notes"])
    write_csv(INPUTS / "observations.csv", obs,
              ["obs_id", "sample_id", "trait_id", "value_num", "unit", "batch_id",
               "measured_at", "notes"])
    write_csv(INPUTS / "corrections.csv", corrections,
              ["correction_id", "target_table", "target_id", "field", "old_value",
               "new_value", "reason", "source_ref"])

    tiny_png(ASSETS / "field-photo-synthetic.png")

    exp = expected(units, samples, obs, corrections)
    (HERE / "expected.json").write_text(
        json.dumps(exp, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    print("已生成合成数据：")
    for f in sorted(INPUTS.glob("*.csv")):
        rows = sum(1 for _ in f.open(encoding="utf-8")) - 1
        digest = hashlib.sha256(f.read_bytes()).hexdigest()[:12]
        print(f"  {f.name:<20} {rows:>3} 行  sha256:{digest}")
    print(f"  期望值 expected.json 已写入（观测 {exp['observations']['total']} 行，"
          f"缺失 {exp['observations']['missing_value']} 个）")


if __name__ == "__main__":
    main()
