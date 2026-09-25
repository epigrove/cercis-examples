#!/usr/bin/env Rscript
# 黄金对照验收：**独立复算**（R 不认识 Cercis，只读导出的 CSV）
#
# 数据集：4 因素 × 16 处理 × 3 区组 × 3 时期 × 7 指标
# 复算内容：
#   1. 各表行数、观测缺失数、编号唯一性
#   2. 每个指标的 原始/更正后 统计量
#   3. **时期 × 指标** 的均值（多时期）
#   4. **因素 × 水平 × 指标** 的边际均值（多因素，其余因素被平均掉）
#   5. 平行样极差；长表 ↔ 宽表一致性；宽表形状
#   6. 更正语义：原始值保留、分析口径用新值
#   7. 导出说明书是否含列字典与复现命令
#
# 用法：Rscript verify/verify.R [产物目录]

suppressMessages(library(jsonlite))

args <- commandArgs(trailingOnly = TRUE)
here <- normalizePath(dirname(sub("--file=", "", grep("--file=", commandArgs(), value = TRUE))))
out_dir <- if (length(args) >= 1) normalizePath(args[1]) else file.path(here, "..", "build", "out")
long_dir <- file.path(out_dir, "long")
wide_dir <- file.path(out_dir, "wide")
verify_dir <- file.path(here, "..", "build", "verify")
dir.create(verify_dir, showWarnings = FALSE, recursive = TRUE)

read_table <- function(name, dir = long_dir) {
  path <- file.path(dir, paste0(name, ".csv"))
  if (!file.exists(path)) stop("缺少导出文件：", path)
  read.csv(path, colClasses = "character", check.names = FALSE, encoding = "UTF-8")
}
num <- function(x) {
  x <- trimws(x); x[x == "" | x == "NA"] <- NA
  suppressWarnings(as.numeric(x))
}
stats_of <- function(v) {
  v <- v[!is.na(v)]
  list(count = length(v),
       mean = if (length(v)) round(mean(v), 4) else NULL,
       min = if (length(v)) min(v) else NULL,
       max = if (length(v)) max(v) else NULL)
}

studies <- read_table("studies")
factors <- read_table("factors")
treatments <- read_table("treatments")
treatment_factors <- read_table("treatment_factors")
units <- read_table("units")
events <- read_table("events")
samples <- read_table("samples")
obs <- read_table("observations")
corrections <- read_table("corrections")

obs$value <- num(obs$value_num)
fix <- setNames(num(corrections$new_value), corrections$target_id)
obs$value_corrected <- obs$value
hit <- !is.na(fix[obs$obs_id])
obs$value_corrected[hit] <- fix[obs$obs_id][hit]

traits <- sort(unique(obs$trait_id))
raw <- lapply(traits, function(t) stats_of(obs$value[obs$trait_id == t]))
corrected <- lapply(traits, function(t) stats_of(obs$value_corrected[obs$trait_id == t]))
names(raw) <- names(corrected) <- traits

# 观测 → 样本 → 事件（时期）/ 小区 → 处理 → 因素水平
long <- merge(obs, samples[, c("sample_id", "unit_id", "event_id")], by = "sample_id", all.x = TRUE)
long <- merge(long, events[, c("event_id", "stage")], by = "event_id", all.x = TRUE)
long <- merge(long, units[, c("unit_id", "treatment_id")], by = "unit_id", all.x = TRUE)
long <- merge(long, treatment_factors[, c("treatment_id", "factor_id", "level")],
              by = "treatment_id", all.x = TRUE, allow.cartesian = TRUE)

# 时期 × 指标
by_stage <- list()
for (t in traits) {
  for (st in unique(long$stage[long$trait_id == t])) {
    v <- long$value[long$trait_id == t & long$stage == st]
    by_stage[[paste(t, st, sep = "|")]] <- if (length(v[!is.na(v)])) round(mean(v, na.rm = TRUE), 4) else NULL
  }
}

# 因素 × 水平 × 指标（边际均值）
by_factor <- list()
for (i in seq_len(nrow(factors))) {
  fid <- factors$factor_id[i]
  for (lv in strsplit(factors$levels[i], ";")[[1]]) {
    for (t in traits) {
      v <- long$value[long$factor_id == fid & long$level == lv & long$trait_id == t]
      v <- v[!is.na(v)]
      if (length(v)) by_factor[[paste0(fid, "=", lv, "|", t)]] <- round(mean(v), 4)
    }
  }
}

# 平行样极差
key <- paste(obs$sample_id, obs$trait_id, obs$measured_at, sep = "|")
groups <- split(obs$value, key)
parallel <- groups[vapply(groups, function(v) sum(!is.na(v)) > 1, logical(1))]
parallel_ranges <- lapply(parallel, function(v) round(max(v, na.rm = TRUE) - min(v, na.rm = TRUE), 4))

# 宽表：形状 + 一致性
wide <- read.csv(file.path(wide_dir, "observations-wide.csv"),
                 colClasses = "character", check.names = FALSE, encoding = "UTF-8")
trait_cols <- intersect(traits, names(wide))
wide_values <- as.data.frame(lapply(wide[trait_cols], num), check.names = FALSE)
filled_per_row <- rowSums(!is.na(wide_values))
wide_shape <- list(
  rows = nrow(wide),
  trait_columns = length(trait_cols),
  rows_with_multiple_values = sum(filled_per_row > 1)
)
pair_keys <- paste(obs$sample_id, obs$trait_id, sep = "|")
pair_counts <- tapply(obs$value, pair_keys, function(v) sum(!is.na(v)))
wide_shape$conflicts <- sum(pair_counts > 1)

wide_ok <- TRUE
for (i in seq_len(nrow(wide))) {
  sid <- wide$sample_id[i]
  if (!(sid %in% obs$sample_id)) { wide_ok <- FALSE; break }
  for (tc in trait_cols) {
    wv <- wide_values[[tc]][i]
    lv <- obs$value[obs$sample_id == sid & obs$trait_id == tc]
    lv <- lv[!is.na(lv)]
    expect <- if (length(lv)) lv[length(lv)] else NA
    same <- (is.na(wv) && is.na(expect)) ||
      (!is.na(wv) && !is.na(expect) && abs(wv - expect) < 1e-9)
    if (!same) { wide_ok <- FALSE; break }
  }
  if (!wide_ok) break
}
if (wide_ok) wide_ok <- setequal(unique(obs$sample_id), wide$sample_id)

# 更正语义
correction_check <- list(
  count = nrow(corrections),
  target_id = if (nrow(corrections)) corrections$target_id[1] else NULL,
  old_value = if (nrow(corrections)) corrections$old_value[1] else NULL,
  new_value = if (nrow(corrections)) corrections$new_value[1] else NULL,
  raw_kept_old = if (nrow(corrections)) {
    all(obs$value_num[obs$obs_id == corrections$target_id[1]] == corrections$old_value[1])
  } else NA,
  analysis_uses_new = if (nrow(corrections)) {
    all(abs(obs$value_corrected[obs$obs_id == corrections$target_id[1]]
            - as.numeric(corrections$new_value[1])) < 1e-9)
  } else NA
)

# 说明书
readme_files <- c(
  list.files(long_dir, pattern = "\\.README\\.md$", full.names = TRUE),
  list.files(wide_dir, pattern = "\\.README\\.md$", full.names = TRUE)
)
readme_check <- list(
  files = length(readme_files),
  with_column_dictionary = sum(vapply(readme_files, function(f) {
    any(grepl("列字典", readLines(f, warn = FALSE, encoding = "UTF-8")))
  }, logical(1))),
  with_reproduce_command = sum(vapply(readme_files, function(f) {
    any(grepl("复现命令", readLines(f, warn = FALSE, encoding = "UTF-8")))
  }, logical(1)))
)

results <- list(
  r_version = R.version.string,
  tables = list(
    studies = nrow(studies), factors = nrow(factors), treatments = nrow(treatments),
    treatment_factors = nrow(treatment_factors), units = nrow(units),
    events = nrow(events), samples = nrow(samples), observations = nrow(obs)
  ),
  observations = list(
    total = nrow(obs),
    missing_value = sum(is.na(obs$value)),
    unique_obs_id = length(unique(obs$obs_id))
  ),
  raw = raw,
  corrected = corrected,
  by_stage = by_stage,
  by_factor = by_factor,
  parallel_ranges = parallel_ranges,
  wide = c(wide_shape, list(consistent_with_long = wide_ok)),
  correction = correction_check,
  readme = readme_check
)

dest <- file.path(verify_dir, "r_results.json")
write(toJSON(results, auto_unbox = TRUE, pretty = TRUE, null = "null"), file = dest)

cat("R 复算完成 →", dest, "\n")
cat(sprintf("  表：%d 张；观测 %d 条（缺失 %d、编号唯一 %d）\n",
            length(results$tables), results$observations$total,
            results$observations$missing_value, results$observations$unique_obs_id))
cat(sprintf("  指标 %d 个 × 时期分组 %d 个 × 因素水平分组 %d 个\n",
            length(traits), length(by_stage), length(by_factor)))
cat(sprintf("  平行样 %d 组；宽表 %d 行 × %d 列（冲突 %d、与长表一致 %s）\n",
            length(parallel_ranges), wide_shape$rows, wide_shape$trait_columns,
            wide_shape$conflicts, wide_ok))
