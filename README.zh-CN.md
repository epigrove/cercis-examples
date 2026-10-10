[English](README.md) | **中文**

# cercis-examples（合成示例与黄金对照验收）

> 愿瑟希斯捍卫你的思想。 / *May Cerces safeguard your thoughts.*

这里放着 Cercis 的**合成示例数据**与**黄金对照验收**：用一批虚构的田间试验数据跑通
"建项目 → 导入 → 更正 → 查询 → 导出 → 体检"的完整链路，再用 **R 独立复算**核对数字。

> **本仓库不含任何真实研究数据**，全部由脚本确定性生成，任何人重跑都得到同样的字节。
>
> 仓库根目录的 [`SYNTHETIC.md`](SYNTHETIC.md) 是给 **分享守卫**（`cercis guard`）看的标记：
> 有它，守卫才允许把数据类文件（`tables/*.csv`、`media/*`）打成分享包/发布物；
> 没有它，守卫一律按真实数据拒绝。发布前先跑一次：`cercis guard . --json`。

## 目录

```
examples/
├── synthetic/
│   ├── generate.py        合成数据生成器（确定性，零依赖）
│   ├── inputs/*.csv       生成出来的输入表（可直接查看）
│   ├── assets/*.png       合成"田间照片"占位符
│   └── expected.json      地面真值（生成器写下的统计量）
└── verify/
    ├── run.sh             跑完整链路（建项目→…→体检→负向验收→R 对账）
    ├── verify.R           R 独立复算（只读导出的 CSV）
    ├── compare.py         把 R 的结果与地面真值逐项对账
    └── REPORT.md          **S6 验收报告**（含发现清单）
```

## 怎么跑

```bash
# 前置：内核与基础工具包已构建
cd ../kernel && cargo build
cd ../kits/basic && cargo build

cd ../examples
python3 synthetic/generate.py     # 生成合成数据
bash verify/run.sh                # 全链路 + R 复算 + 对账（不通过则退出码非 0）
```

产物都在 `build/`（不进版本库）：`project/`（Cercis 项目）、`out/`（导出与说明书）、
`verify/`（日志、流水快照、`comparison.md` 对账表）。

## 合成数据里故意藏的"毛病"

验收要抓的就是这些，所以它们是**特意做出来的**：

| 设计 | 用来验证 |
|---|---|
| 3 个缺失值 | 缺失数统计口径 |
| 1 个极端值（产量 99.9） | 极值呈现（将来接模板的取值范围检查） |
| 4 组平行样复测 | 平行样极差 |
| 1 处誊写笔误走更正 | "原始值保留 + 分析用更正值"这条红线 |
| 多级引用（观测→样本→事件/单元→研究） | 跨表 join 与引用完整性 |

## 当前结论

见 [`verify/REPORT.md`](verify/REPORT.md)：**S6 通过**（157 项对账 0 失败），
过程中发现 6 处问题，其中"导出说明书里的复现命令失效"已修复并加了回归测试。

## 许可

Apache-2.0（见 `LICENSE`）；合成数据与文档同样可自由使用。
