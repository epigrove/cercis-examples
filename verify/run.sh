#!/usr/bin/env bash
# S6 黄金对照验收：用合成数据跑通完整链路（建项目 → 模板 → 导入 → 更正 → 查询 → 导出 → 体检）
#
# 用法：
#   bash verify/run.sh                 # 自动找工作区里的内核与插件
#   CERCIS_BIN=... KIT_BIN=... bash verify/run.sh
#
# 产物都在 build/（不进版本库）：
#   build/project/          跑出来的 Cercis 项目
#   build/out/              导出文件（长表 / 宽表 / 说明书）
#   build/verify/           日志、变更流水快照、负向验收结果
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"                 # examples/
CERCIS_ROOT="${CERCIS_ROOT:-$(cd "$ROOT/.." && pwd)}"   # 工作区根（Cercis/）
KERNEL="${CERCIS_BIN:-$CERCIS_ROOT/kernel/target/debug/cercis}"
KIT="${KIT_BIN:-$CERCIS_ROOT/kits/basic/target/debug}"
INPUTS="$ROOT/synthetic/inputs"
ASSETS="$ROOT/synthetic/assets"
BUILD="$ROOT/build"
PROJECT="$BUILD/project"
OUT="$BUILD/out"
VERIFY="$BUILD/verify"
LOG="$VERIFY/run.log"
cd "$ROOT"

TP="$KIT/cercis-plugin-transfer"
EP="$KIT/cercis-plugin-entry"
HP="$KIT/cercis-plugin-health"

mkdir -p "$VERIFY"
: > "$LOG"

say() { printf '%s\n' "$*" | tee -a "$LOG"; }

# 执行一条命令：命令与输出都进日志，同时回显到终端（只显示前几行）
run() {
  { echo; echo "\$ $*"; } >> "$LOG"
  if "$@" >> "$LOG" 2>&1; then
    tail -n 3 "$LOG" | sed 's/^/    /'
  else
    say "  ✗ 命令失败：$*（详见 run.log）"
    tail -n 15 "$LOG" | sed 's/^/    /'
    exit 1
  fi
}

# 执行一条命令并把它的输出同时存成文件（用于要留档的 JSON）
run_capture() {
  out="$1"; shift
  { echo; echo "\$ $*   # → $(basename "$out")"; } >> "$LOG"
  if "$@" > "$out" 2>>"$LOG"; then
    cat "$out" >> "$LOG"
    tail -n 2 "$out" | sed 's/^/    /'
  else
    say "  ✗ 命令失败：$*（详见 run.log）"
    tail -n 15 "$LOG" | sed 's/^/    /'
    exit 1
  fi
}

# 期望失败的命令（负向验收）：返回退出码与最后一行输出
expect_fail() {
  { echo; echo "\$ $*   # 期望失败"; } >> "$LOG"
  set +e
  "$@" >> "$LOG" 2>&1
  code=$?
  set -e
  echo "$code"
}

say "═ S6 黄金对照验收 ═"
say "内核：$KERNEL"
say "插件：$KIT"
say "时间：$(date '+%Y-%m-%d %H:%M:%S')"
say ""

# ── 0. 前置检查 ─────────────────────────────────────────────────────────
for f in "$KERNEL" "$TP" "$EP" "$HP"; do
  [ -x "$f" ] || { say "缺少可执行文件：${f}（先 cargo build）"; exit 1; }
done
[ -f "$INPUTS/observations.csv" ] || { say "缺少合成数据：先跑 python3 synthetic/generate.py"; exit 1; }

say "── 0. 环境 ──"
say "内核版本：$("$KERNEL" version --json | tr -d '\n')"
say "R 版本：$(Rscript --version 2>&1 | head -1)"
say "合成数据指纹：$(python3 - "$INPUTS" <<'PY'
import hashlib, pathlib, sys
h = hashlib.sha256()
for p in sorted(pathlib.Path(sys.argv[1]).glob("*.csv")):
    h.update(p.read_bytes())
print(h.hexdigest()[:16])
PY
  )"

rm -rf "$BUILD"
mkdir -p "$PROJECT" "$OUT/long" "$OUT/wide" "$VERIFY"

# ── 1. 建项目 + 装模板（内核）────────────────────────────────────────────
say ""
say "── 1. 建项目与装模板 ──"
run "$KERNEL" init "$PROJECT" --name "合成示例：水稻氮肥用量试验（虚构）" --user golden-test --record-device --json
run "$KERNEL" install-template "$PROJECT" --name example-study --json

# ── 2. 导入（通用导入导出插件，逐表按引用顺序）──────────────────────────
say ""
say "── 2. 导入合成数据（走插件：先检查、再一次性写入）──"
for t in studies units events samples; do
  run "$TP" import --project "$PROJECT" --table "$t" \
      --file "$INPUTS/$t.csv" --report "$OUT/import-$t.md" \
      --allow-write --cercis "$KERNEL" --json
done
run "$TP" import --project "$PROJECT" --table observations \
    --file "$INPUTS/observations.csv" --report "$OUT/import-observations.md" \
    --allow-write --cercis "$KERNEL" --json

# ── 3. 更正（内核通道：不覆盖原值）──────────────────────────────────────
say ""
say "── 3. 记录一条更正（誊写笔误）──"
run "$KERNEL" correct "$PROJECT" --table observations --target OB-0017 \
    --field value_num --old 34.50 --new 38.85 \
    --reason "誊写笔误，核对原始记录后更正（合成示例）" \
    --source verify/golden --json

# ── 4. 附件挂接（录入插件）+ 一张"手工放进来的"孤儿照片 ─────────────────
say ""
say "── 4. 附件挂接 ──"
run "$EP" attach --project "$PROJECT" --table media_files \
    --file "$ASSETS/field-photo-synthetic.png" \
    --set media_id="ME-000001" --allow-write --cercis "$KERNEL" --json

# ── 5. 查询（内核原语）──────────────────────────────────────────────────
say ""
say "── 5. 查询（筛选 + 排序）──"
run "$KERNEL" query "$PROJECT" --table observations \
    --filter trait_id eq height_cm --sort value_num:desc --limit 5 --json

# ── 6. 导出（长表 / 宽表 / 说明书）──────────────────────────────────────
say ""
say "── 6. 导出 ──"
for t in studies units events samples observations; do
  run "$TP" export --project "$PROJECT" --table "$t" --out "$OUT/long" \
      --format csv --readme --allow-write --cercis "$KERNEL" --json
done

# 更正表是内核自动建的**系统表**，不在模板里 → 目前 query/export 会拒绝（发现 F-01）。
# 这里直接复制项目内的文件：R 校验读"项目原始文件"反而更独立。
{ echo; echo "\$ cp tables/corrections.csv → $OUT/long/corrections.csv   # 见报告 F-01"; } >> "$LOG"
cp "$PROJECT/tables/corrections.csv" "$OUT/long/corrections.csv"
say "    corrections：模板外系统表，直接复制项目文件（发现 F-01，见报告）"
run "$TP" export --project "$PROJECT" --table observations --out "$OUT/wide" \
    --format csv --wide trait_id --value value_num --readme \
    --allow-write --cercis "$KERNEL" --json

# ── 7. 体检（只读插件）──────────────────────────────────────────────────
say ""
say "── 7. 体检（此时应当是：0 问题、0 提醒）──"
run_capture "$VERIFY/health-clean.json" "$HP" --project "$PROJECT" --cercis "$KERNEL" --json
python3 - "$VERIFY/health-clean.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))["summary"]
print(f"    问题 {d['errors']}、提醒 {d['warnings']}、提示 {d['infos']}")
PY

# ── 8. 校验 + 变更流水快照（可追溯性）────────────────────────────────────
say ""
say "── 8. 校验与流水快照 ──"
"$KERNEL" validate "$PROJECT" --json > "$VERIFY/validate.json" || true
"$KERNEL" log "$PROJECT" --limit 200 --json > "$VERIFY/change_log.json"
python3 - "$VERIFY/validate.json" "$VERIFY/change_log.json" <<'PY'
import json, sys
v = json.load(open(sys.argv[1]))
log = json.load(open(sys.argv[2]))
print(f"    校验：{'通过' if v.get('ok') else '有问题'}（错误 {len(v.get('errors', []))}、警告 {len(v.get('warnings', []))}）")
print(f"    流水：{len(log['entries'])} 条，其中 import {sum(1 for e in log['entries'] if e['action']=='import')} 条、correct {sum(1 for e in log['entries'] if e['action']=='correct')} 条、export {sum(1 for e in log['entries'] if e['action']=='export')} 条")
PY

# ── 9. 技能包 ───────────────────────────────────────────────────────────
say ""
say "── 9. 生成 Agent 技能包（供冷启动使用）──"
run_capture "$VERIFY/skill.json" "$KERNEL" skill "$PROJECT" --out "$BUILD/skill" --json

# ── 10. 负向验收（红线）：断链、孤儿、断链文件 ──────────────────────────
say ""
say "── 10. 负向验收（该拦的必须拦住）──"
# (a) 断链引用：observations.sample_id 指向不存在的样本，必须被拦下
#     （注意：samples 表并不引用别的样本，所以"样本编号是新的"本身是合法的）
cat > "$VERIFY/bad-reference.csv" <<'CSV'
obs_id,sample_id,trait_id,value_num,unit,batch_id,measured_at,notes
OB-9001,S-999,height_cm,99.9,cm,BATCH-BAD,2026-07-20,引用不存在的样本
CSV
BAD_CODE=$(expect_fail "$TP" import --project "$PROJECT" --table observations \
    --file "$VERIFY/bad-reference.csv" --allow-write --cercis "$KERNEL" --json)
say "    (a) 断链引用导入 → 退出码 ${BAD_CODE}（期望非 0）"
tail -n 8 "$LOG" | sed 's/^/    /'
if [ "$BAD_CODE" -eq 0 ]; then
  say "    ✗ 红线被突破：断链引用居然写进了项目"
  exit 1
fi

# (b) 孤儿文件：照片被手工复制进 media/，但没有任何一行引用它
mkdir -p "$PROJECT/media/2026/09/25"
cp "$ASSETS/field-photo-synthetic.png" "$PROJECT/media/2026/09/25/orphan-by-hand.png"

# (c) 断链文件：索引行指向一个不存在的文件
run "$KERNEL" append "$PROJECT" --table media_files \
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
missing = ("media.missing", "error") in codes
orphan = ("media.orphan", "warn") in codes
if not (missing and orphan):
    print(f"    ✗ 期望体检报出 media.missing（问题）与 media.orphan（提醒），实际只有：{sorted(codes)}")
    sys.exit(1)
PY

say ""
say "── 11. R 独立复算 + 对账 ──"
Rscript "$HERE/verify.R" "$OUT" >> "$LOG" 2>&1 || { say "  ✗ R 复算失败（详见 run.log）"; exit 1; }
tail -n 8 "$LOG" | sed 's/^/    /'
python3 "$HERE/compare.py" >> "$LOG" 2>&1 || { say "  ✗ 对账不通过（详见 run.log 与 comparison.md）"; tail -n 20 "$LOG" | sed 's/^/    /'; exit 1; }
grep -E "^  (✅|❌)" "$LOG" | tail -n 6 | sed 's/^/    /'
say ""
say "── 完成：产物在 $BUILD ──"
say "   对账报告：$VERIFY/comparison.md"
say "   运行日志：$LOG"
