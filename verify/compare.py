#!/usr/bin/env python3
"""对账：把 R 的独立复算结果与生成器写下的"地面真值"逐项比对。

数据集是**多因素 · 多时期 · 多指标**设计，所以对账也按这个结构走：
表行数 → 观测总览 → 每指标统计 → **时期 × 指标** → **因素水平 × 指标** →
平行样 → 宽表 → 更正语义 → 说明书。

任一项不一致 → 退出码 1。
"""

import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
EXPECTED = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "synthetic" / "expected.json"
R_RESULTS = Path(sys.argv[2]) if len(sys.argv) > 2 else ROOT / "build" / "verify" / "r_results.json"
REPORT = Path(sys.argv[3]) if len(sys.argv) > 3 else ROOT / "build" / "verify" / "comparison.md"
TOL = 1e-6


class Check:
    def __init__(self):
        self.rows = []
        self.failed = 0

    def eq(self, name, got, want):
        self._add(name, got, want, got == want)

    def close(self, name, got, want):
        ok = (got is None and want is None) or (
            got is not None and want is not None and abs(float(got) - float(want)) <= TOL
        )
        self._add(name, got, want, ok)

    def _add(self, name, got, want, ok):
        if not ok:
            self.failed += 1
        self.rows.append((name, got, want, ok))


def main():
    exp = json.loads(Path(EXPECTED).read_text(encoding="utf-8"))
    r = json.loads(Path(R_RESULTS).read_text(encoding="utf-8"))
    c = Check()

    # 1. 表行数
    for t, want in exp["tables"].items():
        c.eq(f"行数 · {t}", r["tables"].get(t), want)

    # 2. 观测总览
    c.eq("观测总行数", r["observations"]["total"], exp["observations"]["total"])
    c.eq("缺失值个数", r["observations"]["missing_value"], exp["observations"]["missing_value"])
    c.eq("编号唯一数", r["observations"]["unique_obs_id"], exp["observations"]["unique_obs_id"])

    # 3. 每个指标的统计量（原始 / 更正后）
    for t in exp["raw"]:
        for stat in ("count", "mean", "min", "max"):
            c.close(f"原始 · {t} · {stat}", r["raw"][t][stat], exp["raw"][t][stat])
            c.close(f"更正后 · {t} · {stat}", r["corrected"][t][stat], exp["corrected"][t][stat])

    # 4. 时期 × 指标（多时期）
    for k, want in exp["by_stage"].items():
        c.close(f"时期均值 · {k}", r["by_stage"].get(k), want)

    # 5. 因素水平 × 指标（多因素边际均值）
    for k, want in exp["by_factor"].items():
        c.close(f"因素均值 · {k}", r["by_factor"].get(k), want)

    # 6. 平行样极差
    c.eq("平行样组数", len(r["parallel_ranges"]), len(exp["parallel_ranges"]))
    for k, want in exp["parallel_ranges"].items():
        c.close(f"平行样极差 · {k}", r["parallel_ranges"].get(k), want)

    # 7. 宽表
    c.eq("宽表与长表一致", r["wide"]["consistent_with_long"], True)
    c.eq("宽表行数（一样本一行）", r["wide"]["rows"], exp["wide"]["rows"])
    c.eq("宽表指标列数", r["wide"]["trait_columns"], exp["wide"]["trait_columns"])
    c.eq("宽表被合并的格数（平行样）", r["wide"]["conflicts"], exp["wide"]["conflicts"])

    # 8. 更正语义
    ce, cr = exp["correction"], r["correction"]
    c.eq("更正条数", cr["count"], ce["count"])
    c.eq("更正目标", cr["target_id"], ce["target_id"])
    c.eq("更正旧值", cr["old_value"], ce["old_value"])
    c.eq("更正新值", cr["new_value"], ce["new_value"])
    c.eq("原始值未被覆盖", cr["raw_kept_old"], True)
    c.eq("分析口径用新值", cr["analysis_uses_new"], True)

    # 9. 说明书
    readme = r["readme"]
    c.eq("说明书份数 ≥ 12", readme["files"] >= 12, True)
    c.eq("每份都有列字典", readme["with_column_dictionary"], readme["files"])
    c.eq("每份都有复现命令", readme["with_reproduce_command"], readme["files"])

    # ── 报告 ────────────────────────────────────────────────────────────
    d = exp["design"]
    lines = ["# 对账结果（R 复算 vs 地面真值）", ""]
    lines.append(f"- 数据集：{len(d['factors'])} 因素 × {d['treatments']} 处理 × {d['blocks']} 区组"
                 f" × {len(d['stages'])} 时期 × {len(d['traits'])} 指标")
    lines.append(f"- 地面真值：`{Path(EXPECTED).name}`（生成器写入）")
    lines.append(f"- 复算结果：`{R_RESULTS.name}`（R {r.get('r_version', '?')} 读导出 CSV 独立计算）")
    lines.append(f"- 比对项：**{len(c.rows)}** 项，失败 **{c.failed}** 项")
    lines.append("")
    lines.append("| 检查项 | R 复算 | 地面真值 | 结果 |")
    lines.append("|---|---|---|---|")
    for name, got, want, ok in c.rows:
        lines.append(f"| {name} | {fmt(got)} | {fmt(want)} | {'✅' if ok else '❌'} |")
    lines.append("")
    lines.append("## 结论")
    lines.append("")
    lines.append(
        "**通过**：导出数据经 R 独立复算后与生成数据时的地面真值逐项一致。"
        if c.failed == 0 else
        f"**不通过**：有 {c.failed} 项对不上，详见上表。"
    )
    REPORT.parent.mkdir(parents=True, exist_ok=True)
    REPORT.write_text("\n".join(lines) + "\n", encoding="utf-8")

    for name, got, want, ok in c.rows:
        if not ok or name.startswith(("行数 · ", "观测总行数", "缺失值个数", "宽表", "更正条数", "说明书份数")):
            print(f"  {'✅' if ok else '❌'} {name}: R={fmt(got)} 期望={fmt(want)}")
    print(f"\n对账：{len(c.rows)} 项，失败 {c.failed} 项 → {REPORT}")
    return 1 if c.failed else 0


def fmt(v):
    if isinstance(v, float):
        return f"{v:g}"
    return str(v)


if __name__ == "__main__":
    sys.exit(main())
