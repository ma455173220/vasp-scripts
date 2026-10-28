#!/usr/bin/env bash
# =============================================================================
# vasp_para_conv.sh
# 用途：对 VASP INCAR 中的指定参数生成多组测试文件夹，并可选择性提交任务
#
# 用法：
#   bash vasp_para_conv.sh -p PARAM -v "none val1 val2 ..." [-f "file1 file2 ..."] [-i INCAR] [-j JOBSCRIPT] [-s SEP]
#
# 参数：
#   -p  （必填）要测试的 INCAR 参数名，如 NUPDOWN
#   -v  （必填）测试值列表，空格分隔，引号括起；"none" 表示注释掉该参数
#   -f  （可选）要复制到测试文件夹的文件，空格分隔；省略则复制当前目录所有文件
#       （不含 WAVECAR/CHGCAR/CHG/AECCAR*/vaspout.h5/vasprun.xml/OUTCAR/XDATCAR/PROCAR/
#        DOSCAR/EIGENVAL/OSZICAR/LOCPOT/ELFCAR 及 *_OUTCAR 备份）
#   -i  （可选）INCAR 文件路径（默认：./INCAR）
#   -j  （可选）提交脚本文件名（如 job.sh）；指定后生成完询问是否提交，自动检测 PBS/Slurm
#   -s  （可选）-v 中测试值的分隔符（默认空格）；多值参数用它，如 -s , -v "4*1 4*0,8*0"
#       文件夹名中的空格替换为 _
#   -h  显示此帮助
#
# 示例：
#   bash vasp_para_conv.sh -p NUPDOWN -v "none 1 3"
#   bash vasp_para_conv.sh -p NUPDOWN -v "none 1 3" -f "POSCAR POTCAR KPOINTS job.sh" -j job.sh
#   bash vasp_para_conv.sh -p ENCUT   -v "400 520 600" -f "POSCAR POTCAR KPOINTS" -j job.sh
#   bash vasp_para_conv.sh -p MAGMOM  -s , -v "4*1 4*0,4*-1 4*0"
#
# 每个测试文件夹里写 generation_info.txt（参数、值、生成顺序）；
# 算完后汇总分析：vasp_para_conv_analyse.py -p PARAM（能量、ΔE/atom、受力、压力、收敛判断）
# =============================================================================

set -euo pipefail

# ---------- 默认值 ----------
INCAR_FILE="./INCAR"
PARAM=""
VALUES=()
EXTRA_FILES=()
JOB_SCRIPT=""
VALUE_SEP=""
VALUES_RAW=""

# ---------- 帮助与错误处理 ----------
SCRIPT_NAME="$(basename "$0")"

usage() {
    sed -n '3,30p' "$0" | sed 's/^# \{0,1\}//'
}

error_usage() {
    echo ""
    echo "  [错误] $1"
    echo ""
    usage
    exit 1
}

# ---------- 解析参数 ----------
while getopts ":p:v:f:i:j:s:h" opt; do
    case $opt in
        p) PARAM="$OPTARG" ;;
        v) VALUES_RAW="$OPTARG" ;;
        f) read -ra EXTRA_FILES <<< "$OPTARG" ;;
        i) INCAR_FILE="$OPTARG" ;;
        j) JOB_SCRIPT="$OPTARG" ;;
        s) VALUE_SEP="$OPTARG" ;;
        h) usage; exit 0 ;;
        :) error_usage "选项 -$OPTARG 需要参数" ;;
        \?) error_usage "未知选项 -$OPTARG" ;;
    esac
done

if [[ -n "$VALUE_SEP" ]]; then
    IFS="$VALUE_SEP" read -ra VALUES <<< "$VALUES_RAW"
else
    read -ra VALUES <<< "$VALUES_RAW"
fi

# ---------- 输入校验 ----------
[[ -z "$PARAM" ]]         && error_usage "请用 -p 指定参数名"
[[ ${#VALUES[@]} -eq 0 ]] && error_usage "请用 -v 指定至少一个测试值"
[[ ! -f "$INCAR_FILE" ]]  && error_usage "找不到 INCAR 文件：$INCAR_FILE"
[[ -n "$JOB_SCRIPT" && ! -f "$JOB_SCRIPT" ]] && error_usage "找不到提交脚本：$JOB_SCRIPT"

# ---------- 默认文件列表：当前目录所有普通文件（排除脚本自身）+ symlink ----------
EXTRA_LINKS=()   # 始终自动收集当前目录所有 symlink
mapfile -t EXTRA_LINKS < <(find . -maxdepth 1 -type l -printf '%f\n' | sort)

if [[ ${#EXTRA_FILES[@]} -eq 0 ]]; then
    # VASP 输出 / 大文件不复制
    mapfile -t EXTRA_FILES < <(find . -maxdepth 1 -type f ! -name "$SCRIPT_NAME" \
        ! -name WAVECAR ! -name CHGCAR ! -name CHG ! -name 'AECCAR*' ! -name vaspout.h5 \
        ! -name vasprun.xml ! -name OUTCAR ! -name '*_OUTCAR' ! -name XDATCAR ! -name PROCAR \
        ! -name DOSCAR ! -name EIGENVAL ! -name OSZICAR ! -name LOCPOT ! -name ELFCAR \
        -printf '%f\n' | sort)
    echo "[提示] 未指定 -f，将复制当前目录所有文件（不含 VASP 输出，共 ${#EXTRA_FILES[@]} 个）"
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

# Shared helpers (vasp_common.sh): next to this script, else on PATH
_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/vasp_common.sh"; [ -f "$_lib" ] || _lib=$(command -v vasp_common.sh || true)
[ -n "$_lib" ] || { echo "ERROR: vasp_common.sh not found (next to this script or on PATH)" >&2; exit 1; }
source "$_lib"


# ---------- 主循环 ----------
GENERATED_DIRS=()

for val in "${VALUES[@]}"; do

    # 确定文件夹名
    if [[ "$val" == "none" ]]; then
        dir_name="${PARAM}_none"
    else
        dir_name="${PARAM}_${val// /_}"
    fi

    # 创建文件夹（已存在则提示覆盖）
    if [[ -d "$dir_name" ]]; then
        echo "[警告] 文件夹已存在，将覆盖：$dir_name"
    else
        mkdir -p "$dir_name"
    fi

    # ---------- 修改 INCAR（vasp_common.sh：整值替换、只取消注释一行、处理 ; 行）----------
    target_incar="${dir_name}/INCAR"
    cp "$INCAR_FILE" "$target_incar"

    if [[ "$val" == "none" ]]; then
        if incar_get "$PARAM" "$target_incar" >/dev/null; then
            incar_comment "$PARAM" "$target_incar"
            echo "  [${dir_name}] 已注释激活行 ${PARAM}"
        else
            echo "  [${dir_name}] ${PARAM} 已为注释/不存在，原样复制"
        fi

    else
        if incar_get "$PARAM" "$target_incar" >/dev/null; then
            echo "  [${dir_name}] 替换激活行 ${PARAM} = ${val}"
        elif grep -qiE "^[[:space:]]*[#!]+[[:space:]]*${PARAM}[[:space:]]*=" "$target_incar"; then
            echo "  [${dir_name}] 取消注释并设置 ${PARAM} = ${val}"
        else
            echo "  [${dir_name}] 追加新行 ${PARAM} = ${val}"
        fi
        incar_set "$PARAM" "$val" "$target_incar"
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

    # 机器可读的生成信息（vasp_para_conv_analyse.py 用它找目录并保持生成顺序）
    cat > "${dir_name}/generation_info.txt" <<EOF
source_incar=${INCAR_FILE}
modified_param=${PARAM}
modified_value=${val}
generated_dir=${dir_name}
generation_index=${#GENERATED_DIRS[@]}
EOF

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
# 调度系统：按提交脚本头（#PBS / #SBATCH），否则看系统中的 sbatch / qsub
SCHEDULER=$(sched_of "$JOB_SCRIPT" || true)
case "$SCHEDULER" in
    pbs)   SUBMIT_CMD="qsub";   SCHED_NAME="PBS" ;;
    slurm) SUBMIT_CMD="sbatch"; SCHED_NAME="Slurm" ;;
esac
if ! command -v "$SUBMIT_CMD" &>/dev/null; then
    echo "  [警告] 未检测到 $SUBMIT_CMD，无法提交任务"
    exit 0
fi

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
