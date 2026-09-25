#!/usr/bin/env python3
"""生成 S6/S7/S8 黄金对照验收用的**合成数据**（虚构，不含任何真实研究数据）。

设计目标：**通用性**——不是"能跑通一个小例子"，而是覆盖真实田间试验的常见形态：

1. **多因素**：4 个因素（氮肥 / 磷肥 / 密度 / 品种），2^4 = 16 个处理组合
2. **有重复**：3 个区组 → 48 个小区（实验单元）
3. **多时期**：分蘖期 / 抽穗期 / 成熟期 —— 每个时期各测各的指标
4. **多指标**：9 个指标（株高 / SPAD / 分蘖数 / 叶面积 / 产量 / 千粒重 / 生物量）
5. **多级引用**：观测 → 样本 → 事件（时期）→ 小区 → 处理 → 因素水平 → 研究
6. **故意藏的毛病**：缺失值、极端值、平行样复测、誊写笔误（走更正）

输出是**确定性**的（不用随机数），任何人重跑都得到同样的字节。

用法：
    python3 generate.py            # 写入 inputs/ 与 expected.json
"""

import csv
import json
import hashlib
import itertools
import math
from pathlib import Path

HERE = Path(__file__).resolve().parent
INPUTS = HERE / "inputs"
ASSETS = HERE / "assets"

STUDY = {
    "study_id": "ST-2026-001",
    "name": "合成示例：水稻四因素田间试验",
    "crop": "水稻",
    "design": "随机区组",
    "location": "合成试验站（虚构）",
    "start_date": "2026-04-10",
    "end_date": "2026-09-25",
    "notes": "虚构数据，用于 Cercis 黄金对照验收：4 因素 × 3 区组 × 3 时期 × 9 指标",
}

# ── 4 个因素（2 水平全因子 = 16 个处理组合）─────────────────────────────
FACTORS = [
    {"factor_id": "nitrogen", "name": "氮肥", "kind": "定量", "unit": "kg/ha", "levels": "0;180",
     "level_amount": {"0": "", "180": "180"}},
    {"factor_id": "phosphorus", "name": "磷肥", "kind": "定量", "unit": "kg/ha", "levels": "0;60",
     "level_amount": {"0": "", "60": "60"}},
    {"factor_id": "density", "name": "密度", "kind": "定量", "unit": "万株/ha", "levels": "15;22.5",
     "level_amount": {"15": "", "22.5": ""}},
    {"factor_id": "variety", "name": "品种", "kind": "定性", "unit": "", "levels": "V1;V2",
     "level_amount": {"V1": "", "V2": ""}},
]
LEVELS = {f["factor_id"]: f["levels"].split(";") for f in FACTORS}
BLOCKS = ["B1", "B2", "B3"]

# 因素对指标的真实效应（合成，用来产生有规律、可复算的数字）
EFFECT = {
    "nitrogen": {"180": {"plant_height_cm": 6.0, "spad": 3.5, "tiller_number": 1.2,
                         "leaf_area_cm2": 90.0, "grain_yield_kg_plot": 1.8,
                         "thousand_grain_weight_g": 0.9, "biomass_kg_plot": 2.0}},
    "phosphorus": {"60": {"plant_height_cm": 1.6, "spad": 1.0, "tiller_number": 0.5,
                          "leaf_area_cm2": 25.0, "grain_yield_kg_plot": 0.6,
                          "thousand_grain_weight_g": 0.3, "biomass_kg_plot": 0.7}},
    "density": {"22.5": {"plant_height_cm": 2.0, "spad": -0.4, "tiller_number": -1.6,
                         "leaf_area_cm2": 20.0, "grain_yield_kg_plot": -0.35,
                         "thousand_grain_weight_g": -0.2, "biomass_kg_plot": 0.3}},
    "variety": {"V2": {"plant_height_cm": -4.0, "spad": 0.6, "tiller_number": 0.9,
                       "leaf_area_cm2": 10.0, "grain_yield_kg_plot": 0.9,
                       "thousand_grain_weight_g": 1.1, "biomass_kg_plot": 0.5}},
}
BLOCK_EFFECT = {"B1": 0.25, "B2": -0.15, "B3": -0.10}

# ── 3 个时期 × 各时期指标 ────────────────────────────────────────────────
PERIODS = [
    {"event_id": "EV-001", "date": "2026-04-10", "stage": "播种", "event_type": "田间操作",
     "title": "播种", "traits": []},
    {"event_id": "EV-002", "date": "2026-06-15", "stage": "分蘖期", "event_type": "取样",
     "title": "分蘖期取样与测定",
     "traits": ["plant_height_cm", "spad", "tiller_number"]},
    {"event_id": "EV-003", "date": "2026-07-20", "stage": "抽穗期", "event_type": "取样",
     "title": "抽穗期取样与测定",
     "traits": ["plant_height_cm", "spad", "leaf_area_cm2"]},
    {"event_id": "EV-004", "date": "2026-09-18", "stage": "成熟期", "event_type": "测产",
     "title": "成熟期测产",
     "traits": ["grain_yield_kg_plot", "thousand_grain_weight_g", "biomass_kg_plot"]},
]

# 指标基线值与单位（合成）
TRAIT_BASE = {
    "plant_height_cm": (62.0, "cm"),
    "spad": (33.0, "SPAD"),
    "tiller_number": (11.0, "个/株"),
    "leaf_area_cm2": (420.0, "cm2"),
    "grain_yield_kg_plot": (6.2, "kg"),
    "thousand_grain_weight_g": (24.5, "g"),
    "biomass_kg_plot": (12.0, "kg"),
}
ALL_TRAITS = list(TRAIT_BASE.keys())


def build_units_and_treatments():
    """16 个处理组合 × 3 区组 = 48 个小区（随机区组：组合顺序按区组轮换）。"""
    combos = list(itertools.product(*[LEVELS[f["factor_id"]] for f in FACTORS]))
    treatments, treatment_factors = [], []
    for i, combo in enumerate(combos, start=1):
        tid = f"TRT-{i:02d}"
        label = "".join(
            f"{f['factor_id'][:1].upper()}{level}" for f, level in zip(FACTORS, combo)
        )
        treatments.append({
            "treatment_id": tid,
            "study_id": STUDY["study_id"],
            "label": label,
            "notes": "、".join(f"{f['name']}={lv}" for f, lv in zip(FACTORS, combo)),
        })
        for f, level in zip(FACTORS, combo):
            treatment_factors.append({
                "treatment_id": tid,
                "factor_id": f["factor_id"],
                "level": level,
                "amount": f["level_amount"].get(level, ""),
                "notes": "",
            })

    units = []
    n = 0
    for b, block in enumerate(BLOCKS):
        # 区组内轮换顺序，避免处理与位置系统性相关
        order = combos[b:] + combos[:b]
        for combo in order:
            n += 1
            idx = combos.index(combo) + 1
            units.append({
                "unit_id": f"U-{n:03d}",
                "study_id": STUDY["study_id"],
                "block": block,
                "treatment_id": f"TRT-{idx:02d}",
                "area_m2": "12.5",
                "notes": "",
            })
    return treatments, treatment_factors, units, combos


def level_of(combo, factor_id):
    idx = [f["factor_id"] for f in FACTORS].index(factor_id)
    return combo[idx]


def truth(combo, block, trait, phase):
    """一个小区在某指标上的"真实值"：基线 + 各因素效应 + 区组效应 + 小区微差。"""
    base = TRAIT_BASE[trait][0]
    value = base
    for f in FACTORS:
        lv = level_of(combo, f["factor_id"])
        value += EFFECT[f["factor_id"]].get(lv, {}).get(trait, 0.0)
    value += BLOCK_EFFECT[block] * (1.0 + 0.1 * phase)
    # 确定性微差：让同一处理的不同小区不完全相同（模拟小区差异）
    value += ((hash((combo, block)) % 7) - 3) * 0.06 * base * 0.02
    return value


def build():
    treatments, treatment_factors, units, combos = build_units_and_treatments()
    combo_of = {u["treatment_id"]: combos[int(u["treatment_id"][-2:]) - 1] for u in units}

    events = [{
        "event_id": STUDY["study_id"] and p["event_id"],
        "study_id": STUDY["study_id"],
        "date": p["date"],
        "stage": p["stage"],
        "event_type": p["event_type"],
        "title": p["title"],
        "operator": f"记录员{(i % 3) + 1}",
        "notes": "",
    } for i, p in enumerate(PERIODS)]

    samples, observations, corrections = [], [], []
    s_no = o_no = 0

    for unit in units:
        combo = combo_of[unit["treatment_id"]]
        for p_index, period in enumerate(PERIODS):
            if not period["traits"]:
                continue
            s_no += 1
            sample_id = f"S-{s_no:03d}"
            samples.append({
                "sample_id": sample_id,
                "event_id": period["event_id"],
                "unit_id": unit["unit_id"],
                "parent_sample_id": "",
                "sample_type": "植株",
                "depth_cm": "",
                "fresh_weight_g": f"{180 + (s_no % 23) * 4.5:.1f}",
                "notes": "",
            })
            for trait in period["traits"]:
                o_no += 1
                value = truth(combo, unit["block"], trait, p_index)
                text = f"{value:.1f}" if trait != "plant_height_cm" else f"{value:.1f}"
                # 故意缺失：每 37 条留一个空值
                if o_no % 37 == 0:
                    text = ""
                # 故意极端值：第 200 条产量明显离谱
                if o_no == 200 and trait == "grain_yield_kg_plot":
                    text = "99.9"
                observations.append({
                    "obs_id": f"OB-{o_no:04d}",
                    "sample_id": sample_id,
                    "trait_id": trait,
                    "value_num": text,
                    "unit": TRAIT_BASE[trait][1],
                    "method_id": "M-001" if trait == "spad" else "",
                    "batch_id": f"BATCH-{period['date'].replace('-', '')}",
                    "measured_at": period["date"],
                    "operator": f"测定员{(o_no % 4) + 1}",
                    "notes": "",
                })
                # 誊写笔误：第 50 条 SPAD 改正
                if o_no == 50 and trait == "spad":
                    wrong = f"{float(text) - 4.0:.1f}"
                    observations[-1]["value_num"] = wrong
                    corrections.append({
                        "correction_id": "C-000001",
                        "target_table": "observations",
                        "target_id": observations[-1]["obs_id"],
                        "field": "value_num",
                        "old_value": wrong,
                        "new_value": text,
                        "reason": "誊写笔误，核对原始记录后更正（合成示例）",
                        "source_ref": "verify/golden",
                    })

    # 平行样：挑 12 个分蘖期样本的 SPAD 复测一次（第二次读数值略有差异）
    spad_samples = [s for s in samples if s["event_id"] == "EV-002"]
    for s in spad_samples[:12]:
        unit = next(u for u in units if u["unit_id"] == s["unit_id"])
        combo = combo_of[unit["treatment_id"]]
        base = truth(combo, unit["block"], "spad", 0)
        o_no += 1
        observations.append({
            "obs_id": f"OB-{o_no:04d}",
            "sample_id": s["sample_id"],
            "trait_id": "spad",
            "value_num": f"{base + 1.4:.1f}",
            "unit": "SPAD",
            "method_id": "M-001",
            "batch_id": "BATCH-20260615",
            "measured_at": "2026-06-15",
            "operator": "复测员",
            "notes": "平行样复测",
        })

    # 混合样拆分成两个子样（父样本引用，F-02 的检查点）
    for k in (1, 2):
        s_no += 1
        samples.append({
            "sample_id": f"S-{s_no:03d}",
            "event_id": "EV-003",
            "unit_id": "U-001",
            "parent_sample_id": "S-001",
            "sample_type": "植株",
            "depth_cm": "",
            "fresh_weight_g": "205.0",
            "notes": f"混合样拆分（子样 {k}）",
        })

    return treatments, treatment_factors, units, events, samples, observations, corrections


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


def stats(values):
    nums = [v for v in values if v is not None]
    return {
        "count": len(nums),
        "mean": mean(nums),
        "min": min(nums) if nums else None,
        "max": max(nums) if nums else None,
    }


def expected(treatments, treatment_factors, units, events, samples, obs, corrections):
    """地面真值：按"原始口径"与"更正后口径"各算一遍，并给出多因素/多时期的切片。"""
    sample_of = {s["sample_id"]: s for s in samples}
    unit_of = {u["unit_id"]: u for u in units}
    stage_of_event = {e["event_id"]: e["stage"] for e in events}
    # 处理 → {因素: 水平}
    levels_of = {}
    for tf in treatment_factors:
        levels_of.setdefault(tf["treatment_id"], {})[tf["factor_id"]] = tf["level"]

    fix = {c["target_id"]: to_float(c["new_value"]) for c in corrections}

    def values(trait, corrected, predicate=None):
        out = []
        for r in obs:
            if r["trait_id"] != trait:
                continue
            if predicate and not predicate(r):
                continue
            v = fix.get(r["obs_id"], to_float(r["value_num"])) if corrected else to_float(r["value_num"])
            out.append(v)
        return out

    def stage_of(r):
        return stage_of_event[sample_of[r["sample_id"]]["event_id"]]

    def factors_of(r):
        unit = unit_of[sample_of[r["sample_id"]]["unit_id"]]
        return levels_of[unit["treatment_id"]]

    by_trait_raw = {t: stats(values(t, False)) for t in ALL_TRAITS}
    by_trait_corrected = {t: stats(values(t, True)) for t in ALL_TRAITS}

    # 时期 × 指标
    by_stage = {}
    for t in ALL_TRAITS:
        for stage in {stage_of(r) for r in obs if r["trait_id"] == t}:
            by_stage[f"{t}|{stage}"] = mean(values(t, False, lambda r, s=stage: stage_of(r) == s))

    # 因素 × 水平 × 指标（边际均值：其余因素、区组、时期的效应被平均掉）
    by_factor = {}
    for f in FACTORS:
        fid = f["factor_id"]
        for level in LEVELS[fid]:
            for t in ALL_TRAITS:
                v = values(t, False, lambda r, fid=fid, lv=level: factors_of(r).get(fid) == lv)
                if v:
                    by_factor[f"{fid}={level}|{t}"] = mean(v)

    # 平行样极差（同样本 + 同指标 + 同测定日期）
    pairs = {}
    for r in obs:
        if r["value_num"] == "":
            continue
        key = (r["sample_id"], r["trait_id"], r["measured_at"])
        pairs.setdefault(key, []).append(to_float(r["value_num"]))
    parallel = {
        f"{k[0]}|{k[1]}|{k[2]}": round(max(v) - min(v), 4)
        for k, v in pairs.items()
        if len(v) > 1
    }

    # 宽表形态：一样本一行（行身份 = sample_id）
    by_sample = {}
    conflicts = 0
    for r in obs:
        cell = by_sample.setdefault(r["sample_id"], {})
        if r["value_num"] == "":
            continue
        if cell.get(r["trait_id"]):
            conflicts += 1
        cell[r["trait_id"]] = r["value_num"]

    return {
        "tables": {
            "studies": 1,
            "factors": len(FACTORS),
            "treatments": len(treatments),
            "treatment_factors": len(treatment_factors),
            "units": len(units),
            "events": len(events),
            "samples": len(samples),
            "observations": len(obs),
        },
        "observations": {
            "total": len(obs),
            "missing_value": sum(1 for r in obs if r["value_num"] == ""),
            "unique_obs_id": len({r["obs_id"] for r in obs}),
        },
        "raw": by_trait_raw,
        "corrected": by_trait_corrected,
        "by_stage": by_stage,
        "by_factor": by_factor,
        "parallel_ranges": parallel,
        "wide": {
            "rows": len(by_sample),
            "trait_columns": len(ALL_TRAITS),
            "conflicts": conflicts,
        },
        "correction": {
            "count": len(corrections),
            "target_id": corrections[0]["target_id"] if corrections else None,
            "old_value": corrections[0]["old_value"] if corrections else None,
            "new_value": corrections[0]["new_value"] if corrections else None,
        },
        "design": {
            "factors": [f["factor_id"] for f in FACTORS],
            "treatments": len(treatments),
            "blocks": len(BLOCKS),
            "stages": [p["stage"] for p in PERIODS if p["traits"]],
            "traits": ALL_TRAITS,
        },
    }


def main():
    INPUTS.mkdir(parents=True, exist_ok=True)
    ASSETS.mkdir(parents=True, exist_ok=True)

    treatments, treatment_factors, units, events, samples, obs, corrections = build()

    write_csv(INPUTS / "studies.csv", [STUDY],
              ["study_id", "name", "crop", "design", "location", "start_date", "end_date", "notes"])
    write_csv(INPUTS / "factors.csv",
              [{k: v for k, v in f.items() if k != "level_amount"} for f in FACTORS],
              ["factor_id", "name", "kind", "unit", "levels", "notes"])
    write_csv(INPUTS / "treatments.csv", treatments,
              ["treatment_id", "study_id", "label", "notes"])
    write_csv(INPUTS / "treatment_factors.csv", treatment_factors,
              ["treatment_id", "factor_id", "level", "amount", "notes"])
    write_csv(INPUTS / "units.csv", units,
              ["unit_id", "study_id", "block", "treatment_id", "area_m2", "notes"])
    write_csv(INPUTS / "events.csv", events,
              ["event_id", "study_id", "date", "stage", "event_type", "title", "operator", "notes"])
    write_csv(INPUTS / "samples.csv", samples,
              ["sample_id", "event_id", "unit_id", "parent_sample_id", "sample_type",
               "depth_cm", "fresh_weight_g", "notes"])
    write_csv(INPUTS / "observations.csv", obs,
              ["obs_id", "sample_id", "trait_id", "value_num", "unit", "method_id",
               "batch_id", "measured_at", "operator", "notes"])
    write_csv(INPUTS / "corrections.csv", corrections,
              ["correction_id", "target_table", "target_id", "field", "old_value",
               "new_value", "reason", "source_ref"])
    # 观测里用到了方法 M-001（观测 → 方法文档 的引用），所以索引行必须存在
    write_csv(INPUTS / "methods.csv", [{
        "method_id": "M-001",
        "title": "SPAD 测定 SOP（合成示例）",
        "category": "SOP",
        "version": "v1.1",
        "file": "",
        "effective_date": "2026-05-01",
        "notes": "每叶测 3 点取平均；同叶重复测定差值 > 2 需复测",
    }], ["method_id", "title", "category", "version", "file", "effective_date", "notes"])

    exp = expected(treatments, treatment_factors, units, events, samples, obs, corrections)
    (HERE / "expected.json").write_text(
        json.dumps(exp, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    print("已生成合成数据（多因素 · 多时期 · 多指标）：")
    print(f"  设计：{len(FACTORS)} 因素 × {len(treatments)} 处理 × {len(BLOCKS)} 区组 "
          f"= {exp['tables']['units']} 小区")
    print(f"  时期：{'、'.join(exp['design']['stages'])}")
    print(f"  指标：{len(ALL_TRAITS)} 个（{'、'.join(ALL_TRAITS)}）")
    for f in sorted(INPUTS.glob("*.csv")):
        rows = sum(1 for _ in f.open(encoding="utf-8")) - 1
        digest = hashlib.sha256(f.read_bytes()).hexdigest()[:12]
        print(f"  {f.name:<24} {rows:>4} 行  sha256:{digest}")
    print(f"  观测 {exp['observations']['total']} 条，缺失 {exp['observations']['missing_value']} 个；"
          f"地面真值已写入 expected.json")


if __name__ == "__main__":
    main()
