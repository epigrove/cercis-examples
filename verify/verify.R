#!/usr/bin/env Rscript
# S6 黄金对照验收：**独立复算**（R 不认识 Cercis，只读导出的 CSV）
#
# 用法：Rscript verify/verify.R [产物目录]
#   默认读 ../build/out，写 ../build/verify/r_results.json
#
# 复算内容：
#   1. 各表行数、观测缺失数、编号唯一性
#   2. 每个指标的 原始/更正后 统计量（count / mean / min / max）
#   3. 按处理分组的均值（观测 → 样本 → 实验单元 → 处理）
#   4. 平行样极差（同样本 + 同指标 + 同测定日期多次测定的极差）
#   5. 长表 ↔ 宽表一致性，以及宽表的"形状"检查
#   6. 更正是否只改分析口径、不动原始值
#   7. 导出的说明书是否包含列字典与复现命令

suppressMessages(library(jsonlite))

args <- commandArgs(trailingOnly = TRUE)
here <- normalizePath(dirname(sub("--file=", "", grep("--file=", commandArgs(), value = TRUE))))
out_dir <- if (length(args) >= 1) args[1] else file.path(here, "..", "build", "out")
out_dir <- normalizePath(out_dir)
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
  x <- trimws(x)
  x[x == "" | x == "NA"] <- NA
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
units <- read_table("units")
events <- read_table("events")
samples <- read_table("samples")
obs <- read_table("observations")
corrections <- read_table("corrections")

obs$value <- num(obs$value_num)

# 更正值按 obs_id 覆盖到"分析口径"上（原始列保持不动）
fix <- setNames(num(corrections$new_value), corrections$target_id)
obs$value_corrected <- obs$value
hit <- !is.na(fix[obs$obs_id])
obs$value_corrected[hit] <- fix[obs$obs_id][hit]

traits <- c("soil_n_kg_ha", "height_cm", "spad", "yield_kg_plot")
raw <- lapply(traits, function(t) stats_of(obs$value[obs$trait_id == t]))
corrected <- lapply(traits, function(t) stats_of(obs$value_corrected[obs$trait_id == t]))
names(raw) <- names(corrected) <- traits

# 按处理分组的均值：观测 → 样本 → 实验单元 → 处理
joined <- merge(obs, samples[, c("sample_id", "unit_id")], by = "sample_id", all.x = TRUE)
joined <- merge(joined, units[, c("unit_id", "treatment_id")], by = "unit_id", all.x = TRUE)
treatment_means <- lapply(traits, function(t) {
  sub <- joined[joined$trait_id == t, ]
  vals <- lapply(c("T0", "T1", "T2", "T3"), function(trt) {
    v <- sub$value[sub$treatment_id == trt]
    v <- v[!is.na(v)]
    if (length(v)) round(mean(v), 4) else NULL
  })
  names(vals) <- c("T0", "T1", "T2", "T3")
  vals
})
names(treatment_means) <- traits

# 平行样极差（键 = 样本 | 指标 | 测定日期，与生成器的地面真值同格式）
key <- paste(obs$sample_id, obs$trait_id, obs$measured_at, sep = "|")
groups <- split(obs$value, key)
parallel <- groups[vapply(groups, function(v) sum(!is.na(v)) > 1, logical(1))]
parallel_ranges <- lapply(parallel, function(v) round(max(v, na.rm = TRUE) - min(v, na.rm = TRUE), 4))

# 宽表：形状 + 与长表的一致性
wide <- read.csv(file.path(wide_dir, "observations-wide.csv"),
                 colClasses = "character", check.names = FALSE, encoding = "UTF-8")
trait_cols <- intersect(traits, names(wide))
wide_values <- as.data.frame(lapply(wide[trait_cols], num), check.names = FALSE)
filled_per_row <- rowSums(!is.na(wide_values))

# 一行只应有一个指标的读数（说明宽表行身份含 obs_id，见报告 F-04）
wide_shape <- list(
  rows = nrow(wide),
  trait_columns = length(trait_cols),
  rows_with_multiple_values = sum(filled_per_row > 1)
)

wide_ok <- TRUE
for (i in seq_len(nrow(wide))) {
  oid <- wide$obs_id[i]
  long_row <- obs[obs$obs_id == oid, ]
  if (nrow(long_row) == 0) { wide_ok <- FALSE; break }
  for (tc in trait_cols) {
    wv <- wide_values[[tc]][i]
    lv <- long_row$value[long_row$trait_id == tc]
    if (is.na(wv)) {
      if (length(lv) == 1 && !is.na(lv)) { wide_ok <- FALSE }
    } else if (length(lv) != 1 || is.na(lv) || abs(wv - lv) > 1e-9) {
      wide_ok <- FALSE
    }
  }
}

# 更正：原始值必须还在，分析口径必须换成新值
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

# 说明书：列字典 + 复现命令
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
    studies = nrow(studies), units = nrow(units), events = nrow(events),
    samples = nrow(samples), observations = nrow(obs)
  ),
  observations = list(
    total = nrow(obs),
    missing_value = sum(is.na(obs$value)),
    unique_obs_id = length(unique(obs$obs_id))
  ),
  raw = raw,
  corrected = corrected,
  treatment_means_raw = treatment_means,
  parallel_ranges = parallel_ranges,
  wide = c(wide_shape, list(consistent_with_long = wide_ok)),
  correction = correction_check,
  readme = readme_check
)

dest <- file.path(verify_dir, "r_results.json")
write(toJSON(results, auto_unbox = TRUE, pretty = TRUE, null = "null"), file = dest)

cat("R 复算完成 →", dest, "\n")
cat(sprintf("  观测：%d 行，缺失 %d，编号唯一 %d\n",
            results$observations$total, results$observations$missing_value,
            results$observations$unique_obs_id))
for (t in traits) {
  cat(sprintf("  %-14s 原始均值 %-8s → 更正后 %-8s（n=%d）\n",
              t, format(results$raw[[t]]$mean), format(results$corrected[[t]]$mean),
              results$raw[[t]]$count))
}
cat(sprintf("  平行样：%d 组；宽表：%d 行 × %d 个指标列（多值行 %d，与长表一致 %s）\n",
            length(results$parallel_ranges), wide_shape$rows, wide_shape$trait_columns,
            wide_shape$rows_with_multiple_values, wide_ok))
