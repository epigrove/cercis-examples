# S6 黄金对照验收报告

> 日期：2026-09-25（**修订版**：修复 F-01/F-03/F-04 后重跑，对账 74 项 0 失败）
> 范围：内核 + 基础工具包（4 个插件）+ Agent 技能包
> 数据：**全部为合成数据**（`synthetic/generate.py` 生成，无任何真实研究数据）
> 一键复跑：`python3 synthetic/generate.py && bash verify/run.sh`

## 一、结论

| 验收项（需求文档 §16 S6） | 结果 | 证据 |
|---|---|---|
| 用合成数据走完整链路 | ✅ 通过 | `verify/run.sh` 全程无中断，产物见 `build/` |
| 用 R 复算，结果与预期一致 | ✅ 通过 | **74 项对账、0 失败**（`build/verify/comparison.md`） |
| 导出清单可回溯到数据版本 | ✅ 通过 | 5 条导入批次 + 6 条导出留痕，均带 `source_ref`（`build/verify/change_log.json`） |
| 装技能包后由新会话独立走通 | ⏳ 待人工确认 | 技能包已生成并校验（12 条命令、六个配方、红线齐全）；冷启动清单见第六节 |

**结论：S6 通过。** 过程中发现 6 处问题：**F-01、F-03、F-04、F-06 已修复并加了回归测试**；F-02、F-05 记入 S7。

## 二、环境

| 项 | 值 |
|---|---|
| 内核 | `cercis` 0.1.0（`kernel/target/debug/cercis`） |
| 工具包 | `cercis-plugin-{wizard,entry,transfer,health}` 0.1.0 |
| R | R version 4.6.1 (2026-06-24)，用 `jsonlite` 写结果 |
| Python | 3.9.6（只用标准库：生成器、对账脚本） |
| 合成数据指纹 | 见 `build/verify/run.log` 第 0 节 |

## 三、跑了什么（链路）

```
0  前置检查（二进制存在、合成数据存在）
1  建项目 + 装模板            cercis init / install-template --name example-study
2  导入 5 张表（按引用顺序）     cercis-plugin-transfer import × 5（先检查、再一次性写入 + 生成导入报告）
3  记录一条更正（不覆盖原值）    cercis correct --target OB-0017 --old 34.50 --new 38.85
4  附件挂接                    cercis-plugin-entry attach（复制进 media/ 并写索引行）
5  查询（筛选 + 排序）          cercis query --filter trait_id eq height_cm --sort value_num:desc
6  导出                        cercis-plugin-transfer export（长表 6 张【含系统表 corrections】+ 宽表 1 张 + 说明书 7 份）
7  体检                        cercis-plugin-health（此时 0 问题、0 提醒、4 提示）
8  校验 + 流水快照              cercis validate / log
9  生成 Agent 技能包            cercis skill --out build/skill
10 负向验收（红线）             断链引用 / 孤儿文件 / 索引断链
11 R 独立复算 + 对账            Rscript verify.R → compare.py
```

数据规模：研究 1 · 实验单元 12（4 处理 × 3 区组）· 事件 4 · 样本 26 · 观测 52（含平行样复测 4 条）。

> 修复 F-01 之前，`corrections` 这类**模板外的系统表**导不出来（只能手工复制文件）；现在它与普通表一样走插件导出。

## 四、R 复算与对账（核心证据）

R **不认识 Cercis**：它只读导出的 CSV，独立算出统计量，再与生成数据时写下的"地面真值"逐项比对。

| 指标 | R 复算（原始） | R 复算（更正后） | 地面真值 |
|---|---|---|---|
| `soil_n_kg_ha` | n=11，均值 76.2 | 均值 76.2 | 一致 ✅ |
| `height_cm` | n=12，均值 95.45 | 均值 95.45 | 一致 ✅ |
| `spad` | n=15，均值 40.1633 | **均值 40.4533** | 一致 ✅ |
| `yield_kg_plot` | n=11，均值 15.7（最大 99.9） | 均值 15.7 | 一致 ✅ |

同时核对：表行数 6 张全对；缺失值 3 个；编号唯一性 52/52；**按处理分组的均值**（观测→样本→实验单元→处理，4 指标 × 4 处理）全对；**平行样极差** 4 组（均 1.2）全对；**长表↔宽表逐格一致**。

**宽表形态**（F-04 修复后的验收点）：**24 行 × 4 个指标列**——一行一个样本（长表里出现过的样本都占一行，哪怕值全空），其中 12 行一行有多个指标值；平行样造成的"同格多值"4 处被合并并记入 `pivot_conflicts`，说明书里同时写明**行身份列**与**被合并掉的列**。

**更正语义**（需求文档红线）：原始 CSV 里 `OB-0017` 仍是 `34.50`（未被覆盖），`corrections.csv` 记录 `34.50 → 38.85`，分析口径取新值——两条口径的 `spad` 均值差 0.29，R 两边都算对账通过。

## 五、可追溯性

| 证据 | 内容 |
|---|---|
| 导入留痕 | 5 条 `import`，每条带 `batch_id` 与 `source_ref`（指向原始 CSV 路径） |
| 导出留痕 | 6 条 `export`（长表 5 + 宽表 1），记录时间、行数与输出路径 |
| 校验 | `cercis validate` 通过（引用完整性 + 字段规则，0 错误 0 警告） |
| 复现 | 每份导出说明书都带列字典与复现命令（F-06 修复后命令可直接执行） |

## 六、技能包（冷启动）

- 生成：`cercis skill <项目> --out build/skill` → `build/skill/cercis/{SKILL.md,reference.md}`
- 校验：12 条命令与 `ai_contract.json` 同源；六个操作配方齐全；红线与禁止事项齐全
- **待人工确认的一步**：把技能包装进 AI 宿主后**新开一个会话**，只凭技能包 + 项目内三份文件走一遍：

```bash
cercis skill <项目> --install codex      # 或 --install claude
# 新会话里依次验证（技能包第 1~5 节）：
#   1) 读 AGENTS.md / manifest.json / ai_contract.json
#   2) 查数：cercis query … --json
#   3) 试运行：cercis-plugin-transfer import … --dry-run
#   4) 确认写入：去掉 --dry-run
#   5) 导出：cercis-plugin-transfer export … --readme
```

> 这一步本质上是"人机协作"测试，机器无法自证；清单刻意写成可直接照做的五步。

## 七、负向验收（该拦的必须拦住）

| 场景 | 期望 | 实测 |
|---|---|---|
| `observations.sample_id` 指向不存在的样本 `S-999` | 拒绝写入 | ✅ 退出码 1，报错点名 `S-999`，并提示"引用检查未通过，导入已取消" |
| 照片被手工复制进 `media/`，没有任何行引用 | 报孤儿 | ✅ `[warn] media.orphan` |
| 索引行指向不存在的文件 | 报断链 | ✅ `[error] media.missing` |

## 八、发现清单

| 编号 | 级别 | 发现 | 状态 |
|---|---|---|---|
| **F-06** | **真 bug** | 导出说明书与导入报告里的复现命令仍写着 **`cercis-basic data export/import`** —— 工具包拆成四个插件后该二进制已不存在，照做必然失败（直接违反"说明书半年后可读"） | ✅ **已修**：改为从 `CARGO_BIN_NAME` 取当前命令名，并加回归测试 `generated_docs_use_current_binary_name`（工具包 21 个测试全绿） |
| **F-01** | 设计缺口 | `query` / `export` **拒绝模板外的表**（`corrections`、`change_log` 等系统表，以及 attach 自动建的 `media_files`），但 `show` 与体检却能读 → 同一份数据"能读不能用" | ✅ **已修**（方案 A）：内核改为"模板里有按模板，模板没有但文件存在就按现有 CSV 读"；**读放宽、写不放松**，真不存在的表仍报错。回归测试：`tests/untemplated_read.rs` |
| **F-04** | 设计缺口 | 宽表透视把 `obs_id`、`unit`、`batch_id` 等**逐行字段**当成了行身份 → 宽表退化成"每个观测一行、每行只有一个指标有值"（52 行 × 4 列，多值行 0）；用户通常想要的"一样本一行、各指标成列"做不到 | ✅ **已修**（方案 C）：默认按**模板的引用列（外键）**推断行身份，可用 `--index <列…>` 显式指定；结果与说明书都会写明"行身份"和"被合并的列"。修复后：24 行 × 4 列、多值行 12 |
| **F-02** | 模板问题 | `example-study` 模板里 `samples.parent_sample_id` **没有声明引用**，所以"子样本指向不存在的父样本"检不出来 | 记入 S7（科研模板）一并补 |
| **F-03** | CLI 不一致（小） | `append-many` 有 `--allow-new-columns`，`append` 没有；而 `append` 的报错却让用户"先扩展表结构"，命令行里没有别的扩展手段 | ✅ **已修**：`append` 支持 `--allow-new-columns`（按这一行扩展表结构），未加参数时的报错也会提示该开关 |
| **F-05** | 体验（信息级） | `init` 时按通用模板建的 `records` 空表，在装 `example-study` 后仍留在项目里，体检报 `table.extra` 提示（不是错误）；"换模板后的旧表"缺一个清理/标注入口 | 记入 S7 向导 |

## 九、复跑方式

```bash
# 需要：内核与基础工具包已 cargo build；R 已安装
cd examples
python3 synthetic/generate.py     # 生成合成数据（确定性，字节可复现）
bash verify/run.sh                # 跑完整链路 + R 复算 + 对账（失败则退出码非 0）
```

产物：`build/project/`（项目）、`build/out/`（导出与说明书）、`build/verify/`（日志、流水快照、对账报告）。

## 十、修订记录

| 轮次 | 时间 | 内容 | 结果 |
|---|---|---|---|
| 第 1 轮 | 2026-09-25 | 首次验收 | 对账 72 项，发现 F-01～F-06 |
| **第 2 轮** | 2026-09-25 | 修复 F-06（说明书命令失效）、F-01（模板外表可读）、F-03（`append` 可扩展列）、F-04（宽表行身份）后重跑 | **对账 74 项、0 失败**；宽表 24 行 × 4 列；F-02/F-05 留 S7 |

修复带来的测试增量：内核 46 个测试（新增 `untemplated_read.rs` 2 个）、基础工具包 23 个测试（新增宽表行身份 2 个 + 说明书命令名回归 1 个）。
