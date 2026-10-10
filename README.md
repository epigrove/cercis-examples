# cercis-examples (synthetic example + golden-reference acceptance)

**English** | [中文](README.zh-CN.md)

> May Cerces safeguard your thoughts.

This repository holds a **synthetic example dataset** and the **golden-reference acceptance run**:
a batch of fictional field-trial data goes through the whole chain
"create project → import → correct → query → export → health check", and the numbers are then
re-computed **independently in R**.

> **This repository contains no real research data.** Everything is generated deterministically by
> a script, so anyone re-running it gets the same bytes.
>
> [`SYNTHETIC.md`](SYNTHETIC.md) at the repository root is the marker the **share guard**
> (`cercis guard`) looks for: with it, the guard allows data-like files (`tables/*.csv`,
> `media/*`) into a share/release package; without it, the guard rejects them as real data.
> Run `cercis guard . --json` before publishing.

## Layout

```
examples/
├── synthetic/
│   ├── generate.py        synthetic data generator (deterministic, zero dependencies)
│   ├── inputs/*.csv       the generated input tables (readable as-is)
│   ├── assets/*.png       synthetic "field photo" placeholders
│   └── expected.json      ground truth (the statistics the generator wrote down)
└── verify/
    ├── run.sh             the whole chain (project → … → health check → negative tests → R check)
    ├── verify.R           independent re-computation in R (reads the exported CSV only)
    ├── compare.py         compares every R result against the ground truth
    └── REPORT.md          **the acceptance report** (including the list of issues found)
```

## How to run it

```bash
# prerequisites: kernel and basic kit are built
cd ../kernel && cargo build
cd ../kits/basic && cargo build

cd ../examples
python3 synthetic/generate.py     # generate the synthetic data
bash verify/run.sh                # full chain + R re-computation + comparison (non-zero exit on failure)
```

Everything lands in `build/` (not version-controlled): `project/` (the Cercis project),
`out/` (exports and notes) and `verify/` (logs, log snapshots, `comparison.md` with every check).

## "Flaws" deliberately planted in the synthetic data

The acceptance run is meant to catch exactly these, so they are **on purpose**:

| Design | What it verifies |
|--------|------------------|
| 3 missing values | how missing counts are defined |
| 1 extreme value (yield 99.9) | how extremes show up (a template range check may follow) |
| 4 sets of replicate measurements | replicate spread |
| 1 transcription typo corrected | the red line "original value kept, analysis uses the correction" |
| multi-level references (observation → sample → event/plot → study) | cross-table joins and referential integrity |

## Current result

See [`verify/REPORT.md`](verify/REPORT.md): **accepted — 157 checks, 0 failures**.
Six issues were found along the way; the one where the reproduction command in an export note did
not work has been fixed and a regression test added.

## License

Apache-2.0 (see `LICENSE`); the synthetic data and documentation are equally free to use.
