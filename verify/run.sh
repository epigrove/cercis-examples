#!/usr/bin/env bash
# 黄金对照验收：用合成数据跑通完整链路 → R 独立复算 → 逐项对账
#
# 数据集是**多因素 · 多时期 · 多指标**的通用设计（见 synthetic/generate.py）：
#   4 个因素 × 16 个处理 × 3 个区组 = 48 个小区
#   3 个时期（分蘖/抽穗/成熟）× 7 个指标 = 444 条观测
#
# 用法：bash verify/run.sh     （需要内核、基础工具包、科研工具包都已 cargo build；R 已安装）
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CERCIS_ROOT="${CERCIS_ROOT:-$(cd "$ROOT/.." && pwd)}"
KERNEL="${CERCIS_BIN:-$CERCIS_ROOT/kernel/target/debug/cercis}"
KIT="${KIT_BIN:-$CERCIS_ROOT/kits/basic/target/debug}"
RESEARCH_KIT="${CERCIS_RESEARCH_DIR:-$CERCIS_ROOT/kits/research}"
INPUTS="$ROOT/synthetic/inputs"
ASSETS="$ROOT/synthetic/assets"
BUILD="$ROOT/build"
PROJECT="$BUILD/project"
OUT="$BUILD/out"
VERIFY="$BUILD/verify"
LOG="$VERIFY/run.log"

TP="$KIT/cercis-plugin-transfer"
EP="$KIT/cercis-plugin-entry"
HP="$KIT/cercis-plugin-health"
TEMPLATE="$RESEARCH_KIT/templates/field-trial.yaml"
TERMS="$RESEARCH_KIT/terms/agriculture.yaml"

mkdir -p "$VERIFY"
: > "$LOG"
say() { printf '%s\n' "$*" | tee -a "$LOG"; }

run() {
  { echo; echo "\$ $*"; } >> "$LOG"
  if "$@" >> "$LOG" 2>&1; then
    tail -n 3 "$LOG" | sed 's/^/    /'
  else
    say "  ✗ 命令失败：$*（详见 run.log）"
    tail -n 20 "$LOG" | sed 's/^/    /'
    exit 1
  fi
}

run_capture() {
  out="$1"; shift
  { echo; echo "\$ $*   # → $(basename "$out")"; } >> "$LOG"
  if "$@" > "$out" 2>>"$LOG"; then
    cat "$out" >> "$LOG"
    tail -n 2 "$out" | sed 's/^/    /'
  else
    say "  ✗ 命令失败：$*"
    exit 1
  fi
}

expect_fail() {
  { echo; echo "\$ $*   # 期望失败"; } >> "$LOG"
  set +e
  "$@" >> "$LOG" 2>&1
  code=$?
  set -e
  echo "$code"
}

say "═ 黄金对照验收（多因素 · 多时期 · 多指标）═"
say "内核：$KERNEL"
say "科研模板：$TEMPLATE"
say "时间：$(date '+%Y-%m-%d %H:%M:%S')"

# ── 0. 前置检查 ─────────────────────────────────────────────────────────
for f in "$KERNEL" "$TP" "$EP" "$HP"; do
  [ -x "$f" ] || { say "缺少可执行文件：${f}（先 cargo build）"; exit 1; }
done
[ -f "$INPUTS/observations.csv" ] || { say "缺少合成数据：先跑 python3 synthetic/generate.py"; exit 1; }
[ -f "$TEMPLATE" ] || { say "找不到科研模板：$TEMPLATE（需要 cercis-kits-research）"; exit 1; }

say ""
say "── 0. 环境 ──"
say "内核版本：$("$KERNEL" version --json | tr -d '\n')"
say "R 版本：$(Rscript --version 2>&1 | head -1)"

rm -rf "$BUILD"
mkdir -p "$PROJECT" "$OUT/long" "$OUT/wide" "$VERIFY"

# ── 1. 建项目 + 装科研模板 + 选农业术语 ─────────────────────────────────
say ""
say "── 1. 建项目与装科研模板 ──"
run "$KERNEL" init "$PROJECT" --name "合成示例：水稻四因素田间试验（虚构）" --user golden-test --record-device --json
run "$KERNEL" install-template "$PROJECT" --file "$TEMPLATE" --json
run "$KERNEL" terms "$PROJECT" --file "$TERMS" --json

# ── 2. 导入（按引用顺序；走通用导入导出插件，含检查与报告）──────────────
say ""
say "── 2. 导入合成数据 ──"
for t in studies factors treatments treatment_factors units events methods samples; do
  run "$TP" import --project "$PROJECT" --table "$t" \
      --file "$INPUTS/$t.csv" --report "$OUT/import-$t.md" \
      --allow-write --cercis "$KERNEL" --json
done
run "$TP" import --project "$PROJECT" --table observations \
    --file "$INPUTS/observations.csv" --report "$OUT/import-observations.md" \
    --allow-write --cercis "$KERNEL" --json

# ── 3. 更正（不覆盖原值；参数从合成数据里读，保证两边一致）──────────────
say ""
say "── 3. 记录一条更正 ──"
read -r CORR_TARGET CORR_OLD CORR_NEW < <(python3 - "$INPUTS/corrections.csv" <<'PY'
import csv, sys
with open(sys.argv[1], encoding="utf-8") as f:
    row = next(csv.DictReader(f))
print(row["target_id"], row["old_value"], row["new_value"])
PY
)
run "$KERNEL" correct "$PROJECT" --table observations --target "$CORR_TARGET" \
    --field value_num --old "$CORR_OLD" --new "$CORR_NEW" \
    --reason "誊写笔误，核对原始记录后更正（合成示例）" --source verify/golden --json

# ── 4. 附件挂接（科研模板自带 media 表，会自动填 fingerprint 与模式）────
say ""
say "── 4. 附件挂接 ──"
run "$EP" attach --project "$PROJECT" --table media \
    --file "$ASSETS/field-photo-synthetic.png" \
    --set media_id=ME-000001 --set event_id=EV-002 --set kind=照片 --set consent=否 \
    --allow-write --cercis "$KERNEL" --json

# ── 5. 查询（多条件组合）────────────────────────────────────────────────
say ""
say "── 5. 查询：成熟期产量最高的 5 条 ──"
run "$KERNEL" query "$PROJECT" --table observations \
    --filter trait_id eq grain_yield_kg_plot --sort value_num:desc --limit 5 --json

# ── 6. 导出（长表 + 宽表 + 说明书）──────────────────────────────────────
say ""
say "── 6. 导出 ──"
for t in studies factors treatments treatment_factors units events methods samples media corrections observations; do
  run "$TP" export --project "$PROJECT" --table "$t" --out "$OUT/long" \
      --format csv --readme --allow-write --cercis "$KERNEL" --json
done
# 宽表：默认行身份 = 必填引用列（observations 的 sample_id）→ 一样本一行、指标成列
run "$TP" export --project "$PROJECT" --table observations --out "$OUT/wide" \
    --format csv --wide trait_id --value value_num --readme \
    --allow-write --cercis "$KERNEL" --json

# ── 7. 体检（干净状态应当 0 问题 0 提醒）────────────────────────────────
say ""
say "── 7. 体检 ──"
run_capture "$VERIFY/health-clean.json" "$HP" --project "$PROJECT" --cercis "$KERNEL" --json
python3 - "$VERIFY/health-clean.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))["summary"]
print(f"    问题 {d['errors']}、提醒 {d['warnings']}、提示 {d['infos']}")
PY

# ── 8. 校验 + 流水快照 ──────────────────────────────────────────────────
say ""
say "── 8. 校验与流水 ──"
"$KERNEL" validate "$PROJECT" --json > "$VERIFY/validate.json" || true
"$KERNEL" log "$PROJECT" --limit 300 --json > "$VERIFY/change_log.json"
python3 - "$VERIFY/validate.json" "$VERIFY/change_log.json" <<'PY'
import json, sys
v = json.load(open(sys.argv[1]))
log = json.load(open(sys.argv[2]))
print(f"    校验：{'通过' if v.get('ok') else '有问题'}（错误 {len(v.get('errors', []))}、警告 {len(v.get('warnings', []))}）")
print(f"    流水：{len(log['entries'])} 条")
PY

# ── 9. 技能包 ───────────────────────────────────────────────────────────
say ""
say "── 9. 生成 Agent 技能包 ──"
run_capture "$VERIFY/skill.json" "$KERNEL" skill "$PROJECT" --out "$BUILD/skill" --json

# ── 10. 负向验收（该拦的必须拦住）───────────────────────────────────────
say ""
say "── 10. 负向验收 ──"
cat > "$VERIFY/bad-reference.csv" <<'CSV'
obs_id,sample_id,trait_id,value_num,unit,method_id,batch_id,measured_at,operator,notes
OB-9001,S-999,plant_height_cm,99.9,cm,,BATCH-BAD,2026-06-15,测试,引用不存在的样本
CSV
BAD_CODE=$(expect_fail "$TP" import --project "$PROJECT" --table observations \
    --file "$VERIFY/bad-reference.csv" --allow-write --cercis "$KERNEL" --json)
say "    (a) 断链引用导入 → 退出码 ${BAD_CODE}（期望非 0）"
tail -n 8 "$LOG" | sed 's/^/    /'
if [ "$BAD_CODE" -eq 0 ]; then
  say "    ✗ 红线被突破：断链引用居然写进了项目"; exit 1
fi

mkdir -p "$PROJECT/media/2026/09/25"
cp "$ASSETS/field-photo-synthetic.png" "$PROJECT/media/2026/09/25/orphan-by-hand.png"
run "$KERNEL" append "$PROJECT" --table media \
    --set media_id=ME-000002 --set path=media/2026/09/25/missing-file.jpg \
    --target ME-000002 --summary "负向验收：索引指向不存在的文件" --json

run_capture "$VERIFY/health-negative.json" "$HP" --project "$PROJECT" --cercis "$KERNEL" --json
python3 - "$VERIFY/health-negative.json" <<'PY' || exit 1
import json, sys
d = json.load(open(sys.argv[1]))
codes = {(f["code"], f["level"]) for f in d["findings"]}
print(f"    (b)(c) 负向体检：问题 {d['summary']['errors']}、提醒 {d['summary']['warnings']}")
for f in d["findings"]:
    if f["code"] in ("media.orphan", "media.missing"):
        print(f"      [{f['level']}] {f['code']}：{f['target']}")
if not (("media.missing", "error") in codes and ("media.orphan", "warn") in codes):
    print(f"    ✗ 期望报出 media.missing 与 media.orphan，实际：{sorted(codes)}"); sys.exit(1)
PY

# ── 11. R 独立复算 + 对账 ───────────────────────────────────────────────
say ""
say "── 11. R 独立复算 + 对账 ──"
Rscript "$HERE/verify.R" "$OUT" >> "$LOG" 2>&1 || { say "  ✗ R 复算失败（详见 run.log）"; exit 1; }
tail -n 10 "$LOG" | sed 's/^/    /'
python3 "$HERE/compare.py" >> "$LOG" 2>&1 || {
  say "  ✗ 对账不通过（详见 run.log 与 comparison.md）"; tail -n 20 "$LOG" | sed 's/^/    /'; exit 1; }
grep -E "^  (✅|❌)" "$LOG" | tail -n 8 | sed 's/^/    /'

say ""
say "── 完成：产物在 $BUILD ──"
say "   对账报告：$VERIFY/comparison.md"
say "   运行日志：$LOG"
