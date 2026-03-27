#!/usr/bin/env bash
# =============================================================================
# vasp_param_test.sh
# 用途：对 VASP INCAR 中的指定参数生成多组测试文件夹，并可选择性提交任务
#
# 用法：
#   bash vasp_param_test.sh -p PARAM -v "none val1 val2 ..." [-f "file1 file2 ..."] [-i INCAR] [-j JOBSCRIPT]
#
# 参数：
#   -p  （必填）要测试的 INCAR 参数名，如 NUPDOWN
#   -v  （必填）测试值列表，空格分隔，引号括起；"none" 表示注释掉该参数
#   -f  （可选）要复制到测试文件夹的文件，空格分隔；省略则复制当前目录所有文件
#   -i  （可选）INCAR 文件路径（默认：./INCAR）
#   -j  （可选）提交脚本文件名（如 job.sh）；指定后生成完询问是否提交，自动检测 PBS/Slurm
#   -h  显示此帮助
#
# 示例：
#   bash vasp_param_test.sh -p NUPDOWN -v "none 1 3"
#   bash vasp_param_test.sh -p NUPDOWN -v "none 1 3" -f "POSCAR POTCAR KPOINTS job.sh" -j job.sh
#   bash vasp_param_test.sh -p ENCUT   -v "400 520 600" -f "POSCAR POTCAR KPOINTS" -j job.sh
# =============================================================================

set -euo pipefail

# ---------- 默认值 ----------
INCAR_FILE="./INCAR"
PARAM=""
VALUES=()
EXTRA_FILES=()
JOB_SCRIPT=""

# ---------- 帮助与错误处理 ----------
SCRIPT_NAME="$(basename "$0")"

usage() {
    sed -n '3,22p' "$0" | sed 's/^# \{0,1\}//'
}

error_usage() {
    echo ""
    echo "  [错误] $1"
    echo ""
    usage
    exit 1
}

# ---------- 解析参数 ----------
while getopts ":p:v:f:i:j:h" opt; do
    case $opt in
        p) PARAM="$OPTARG" ;;
        v) read -ra VALUES <<< "$OPTARG" ;;
        f) read -ra EXTRA_FILES <<< "$OPTARG" ;;
        i) INCAR_FILE="$OPTARG" ;;
        j) JOB_SCRIPT="$OPTARG" ;;
        h) usage; exit 0 ;;
        :) error_usage "选项 -$OPTARG 需要参数" ;;
        \?) error_usage "未知选项 -$OPTARG" ;;
    esac
done

# ---------- 输入校验 ----------
[[ -z "$PARAM" ]]         && error_usage "请用 -p 指定参数名"
[[ ${#VALUES[@]} -eq 0 ]] && error_usage "请用 -v 指定至少一个测试值"
[[ ! -f "$INCAR_FILE" ]]  && error_usage "找不到 INCAR 文件：$INCAR_FILE"
[[ -n "$JOB_SCRIPT" && ! -f "$JOB_SCRIPT" ]] && error_usage "找不到提交脚本：$JOB_SCRIPT"

# ---------- 默认文件列表：当前目录所有普通文件（排除脚本自身）+ symlink ----------
EXTRA_LINKS=()   # 始终自动收集当前目录所有 symlink
mapfile -t EXTRA_LINKS < <(find . -maxdepth 1 -type l -printf '%f\n' | sort)

if [[ ${#EXTRA_FILES[@]} -eq 0 ]]; then
    mapfile -t EXTRA_FILES < <(find . -maxdepth 1 -type f ! -name "$SCRIPT_NAME" -printf '%f\n' | sort)
    echo "[提示] 未指定 -f，将复制当前目录所有文件（共 ${#EXTRA_FILES[@]} 个）"
fi

for f in "${EXTRA_FILES[@]}"; do
    [[ ! -f "$f" && ! -L "$f" ]] && echo "  [警告] 找不到文件：$f，将跳过"
done

echo "========================================"
echo "  参数：$PARAM"
echo "  测试值：${VALUES[*]}"
echo "  附加文件（${#EXTRA_FILES[@]} 个）：${EXTRA_FILES[*]:-（无）}"
[[ ${#EXTRA_LINKS[@]} -gt 0 ]] && echo "  软链接（${#EXTRA_LINKS[@]} 个）：${EXTRA_LINKS[*]}"
echo "  源 INCAR：$INCAR_FILE"
[[ -n "$JOB_SCRIPT" ]] && echo "  提交脚本：$JOB_SCRIPT"
echo "========================================"

# 辅助函数：grep -c 但不让非零退出码触发 set -e
count_lines() {
    local pattern="$1" file="$2"
    { grep -cE "$pattern" "$file"; } || true
}

# ---------- 检测调度系统 ----------
detect_scheduler() {
    if command -v qsub &>/dev/null; then
        echo "pbs"
    elif command -v sbatch &>/dev/null; then
        echo "slurm"
    else
        echo "none"
    fi
}

# ---------- 主循环 ----------
GENERATED_DIRS=()

for val in "${VALUES[@]}"; do

    # 确定文件夹名
    if [[ "$val" == "none" ]]; then
        dir_name="${PARAM}_none"
    else
        dir_name="${PARAM}_${val}"
    fi

    # 创建文件夹（已存在则提示覆盖）
    if [[ -d "$dir_name" ]]; then
        echo "[警告] 文件夹已存在，将覆盖：$dir_name"
    else
        mkdir -p "$dir_name"
    fi

    # ---------- 修改 INCAR ----------
    target_incar="${dir_name}/INCAR"

    active_count=$(count_lines "^[[:space:]]*${PARAM}[[:space:]]*=" "$INCAR_FILE")
    commented_count=$(count_lines "^[[:space:]]*#[[:space:]]*${PARAM}[[:space:]]*=" "$INCAR_FILE")

    if [[ "$val" == "none" ]]; then
        if [[ "$active_count" -gt 0 ]]; then
            sed -E "s|^([[:space:]]*)${PARAM}([[:space:]]*=)|\1# ${PARAM}\2|" \
                "$INCAR_FILE" > "$target_incar"
            echo "  [${dir_name}] 已注释激活行 ${PARAM}"
        else
            cp "$INCAR_FILE" "$target_incar"
            echo "  [${dir_name}] ${PARAM} 已为注释/不存在，原样复制"
        fi

    else
        if [[ "$active_count" -gt 0 ]]; then
            sed -E "s|^([[:space:]]*${PARAM}[[:space:]]*=)[[:space:]]*[^#[:space:]]*(.*)|\\1 ${val}  \\2|" \
                "$INCAR_FILE" > "$target_incar"
            echo "  [${dir_name}] 替换激活行 ${PARAM} = ${val}"

        elif [[ "$commented_count" -gt 0 ]]; then
            sed -E "s|^([[:space:]]*)#[[:space:]]*(${PARAM}[[:space:]]*=)[[:space:]]*[^#[:space:]]*(.*)|\\1\\2 ${val}  \\3|" \
                "$INCAR_FILE" > "$target_incar"
            echo "  [${dir_name}] 取消注释并设置 ${PARAM} = ${val}"

        else
            cp "$INCAR_FILE" "$target_incar"
            printf "\n%s = %s\n" "${PARAM}" "${val}" >> "$target_incar"
            echo "  [${dir_name}] 追加新行 ${PARAM} = ${val}"
        fi
    fi

    # ---------- 复制附加文件（跳过 INCAR，已由脚本生成）----------
    incar_basename="$(basename "$INCAR_FILE")"
    for f in "${EXTRA_FILES[@]}"; do
        if [[ "$(basename "$f")" == "$incar_basename" ]]; then
            continue
        fi
        if [[ -f "$f" ]]; then
            cp "$f" "${dir_name}/"
            echo "  [${dir_name}] 已复制 $f"
        fi
    done

    # ---------- 重建软链接（指向上层目录中的同名 symlink）----------
    for lnk in "${EXTRA_LINKS[@]}"; do
        ln -sf "../${lnk}" "${dir_name}/${lnk}"
        echo "  [${dir_name}] 已建立软链接 ${lnk} → ../${lnk}"
    done

    GENERATED_DIRS+=("$dir_name")
    echo "  → 完成：$dir_name/"
    echo ""

done

echo "========================================"
echo "  全部完成，共生成 ${#VALUES[@]} 个测试文件夹"
echo "========================================"

# ---------- 询问是否提交任务 ----------
if [[ -z "$JOB_SCRIPT" ]]; then
    exit 0
fi

echo ""
echo "  生成的目录："
for d in "${GENERATED_DIRS[@]}"; do
    echo "    - $d"
done
echo ""

# 检测调度系统
SCHEDULER=$(detect_scheduler)
case "$SCHEDULER" in
    pbs)   SUBMIT_CMD="qsub";   SCHED_NAME="PBS" ;;
    slurm) SUBMIT_CMD="sbatch"; SCHED_NAME="Slurm" ;;
    none)
        echo "  [警告] 未检测到 qsub 或 sbatch，无法提交任务"
        exit 0
        ;;
esac

echo "  检测到调度系统：${SCHED_NAME}（${SUBMIT_CMD}）"
echo ""
printf "  是否提交全部 %d 个任务？[y/N] " "${#GENERATED_DIRS[@]}"
read -r answer

case "$answer" in
    [yY]|[yY][eE][sS])
        echo ""
        for d in "${GENERATED_DIRS[@]}"; do
            job_path="${d}/${JOB_SCRIPT}"
            if [[ ! -f "$job_path" ]]; then
                echo "  [跳过] 找不到提交脚本：${job_path}"
                continue
            fi
            job_id=$(cd "$d" && $SUBMIT_CMD "$JOB_SCRIPT" 2>&1)
            echo "  [已提交] ${d}  →  ${job_id}"
        done
        echo ""
        echo "  全部任务已提交完毕"
        ;;
    *)
        echo "  已跳过提交"
        ;;
esac
