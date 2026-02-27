#!/usr/bin/env bash
# =============================================================================
# vasp_param_test.sh
# 用途：对 VASP INCAR 中的指定参数生成多组测试文件夹
#
# 用法：
#   bash vasp_param_test.sh -p PARAM -v "none val1 val2 ..." [-f "file1 file2 ..."] [-i INCAR]
#
# 参数：
#   -p  （必填）要测试的 INCAR 参数名，如 NUPDOWN
#   -v  （必填）测试值列表，空格分隔，引号括起；"none" 表示注释掉该参数
#   -f  （可选）要复制到测试文件夹的文件，空格分隔；省略则复制当前目录所有文件
#   -i  （可选）INCAR 文件路径（默认：./INCAR）
#   -h  显示此帮助
#
# 示例：
#   bash vasp_param_test.sh -p NUPDOWN -v "none 1 3"
#   bash vasp_param_test.sh -p NUPDOWN -v "none 1 3" -f "POSCAR POTCAR KPOINTS job.sh"
#   bash vasp_param_test.sh -p ENCUT   -v "400 520 600" -f "POSCAR POTCAR KPOINTS"
# =============================================================================

set -euo pipefail

# ---------- 默认值 ----------
INCAR_FILE="./INCAR"
PARAM=""
VALUES=()
EXTRA_FILES=()

# ---------- 帮助与错误处理 ----------
SCRIPT_NAME="$(basename "$0")"

usage() {
    sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'
}

error_usage() {
    echo ""
    echo "  [错误] $1"
    echo ""
    usage
    exit 1
}

# ---------- 解析参数 ----------
while getopts ":p:v:f:i:h" opt; do
    case $opt in
        p) PARAM="$OPTARG" ;;
        v) read -ra VALUES <<< "$OPTARG" ;;
        f) read -ra EXTRA_FILES <<< "$OPTARG" ;;
        i) INCAR_FILE="$OPTARG" ;;
        h) usage; exit 0 ;;
        :) error_usage "选项 -$OPTARG 需要参数" ;;
        \?) error_usage "未知选项 -$OPTARG" ;;
    esac
done

# ---------- 输入校验 ----------
[[ -z "$PARAM" ]]         && error_usage "请用 -p 指定参数名"
[[ ${#VALUES[@]} -eq 0 ]] && error_usage "请用 -v 指定至少一个测试值"
[[ ! -f "$INCAR_FILE" ]]  && error_usage "找不到 INCAR 文件：$INCAR_FILE"

# ---------- 默认文件列表：当前目录所有文件（排除脚本自身） ----------
if [[ ${#EXTRA_FILES[@]} -eq 0 ]]; then
    mapfile -t EXTRA_FILES < <(find . -maxdepth 1 -type f ! -name "$SCRIPT_NAME" -printf '%f\n' | sort)
    echo "[提示] 未指定 -f，将复制当前目录所有文件（共 ${#EXTRA_FILES[@]} 个）"
fi

for f in "${EXTRA_FILES[@]}"; do
    [[ ! -f "$f" ]] && echo "  [警告] 找不到文件：$f，将跳过"
done

echo "========================================"
echo "  参数：$PARAM"
echo "  测试值：${VALUES[*]}"
echo "  附加文件（${#EXTRA_FILES[@]} 个）：${EXTRA_FILES[*]:-（无）}"
echo "  源 INCAR：$INCAR_FILE"
echo "========================================"

# 辅助函数：grep -c 但不让非零退出码触发 set -e
# grep -c 在无匹配时输出 0 并以退出码 1 退出；用子组 + || true 抑制退出码
count_lines() {
    local pattern="$1" file="$2"
    { grep -cE "$pattern" "$file"; } || true
}

# ---------- 主循环 ----------
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
            # 激活行 → 注释掉：PARAM = x  →  # PARAM = x
            sed -E "s|^([[:space:]]*)${PARAM}([[:space:]]*=)|\1# ${PARAM}\2|" \
                "$INCAR_FILE" > "$target_incar"
            echo "  [${dir_name}] 已注释激活行 ${PARAM}"
        else
            # 已是注释或不存在，原样复制
            cp "$INCAR_FILE" "$target_incar"
            echo "  [${dir_name}] ${PARAM} 已为注释/不存在，原样复制"
        fi

    else
        if [[ "$active_count" -gt 0 ]]; then
            # 激活行存在：替换值，保留行内注释
            # PARAM = oldval   #(comment)  →  PARAM = newval  #(comment)
            sed -E "s|^([[:space:]]*${PARAM}[[:space:]]*=)[[:space:]]*[^#[:space:]]*(.*)|\\1 ${val}  \\2|" \
                "$INCAR_FILE" > "$target_incar"
            echo "  [${dir_name}] 替换激活行 ${PARAM} = ${val}"

        elif [[ "$commented_count" -gt 0 ]]; then
            # 注释行存在：取消注释并替换值
            # # PARAM = oldval  →  PARAM = newval
            sed -E "s|^([[:space:]]*)#[[:space:]]*(${PARAM}[[:space:]]*=)[[:space:]]*[^#[:space:]]*(.*)|\\1\\2 ${val}  \\3|" \
                "$INCAR_FILE" > "$target_incar"
            echo "  [${dir_name}] 取消注释并设置 ${PARAM} = ${val}"

        else
            # 参数不存在：追加到文件末尾
            cp "$INCAR_FILE" "$target_incar"
            printf "\n%s = %s\n" "${PARAM}" "${val}" >> "$target_incar"
            echo "  [${dir_name}] 追加新行 ${PARAM} = ${val}"
        fi
    fi

    # ---------- 复制附加文件（跳过 INCAR，已由脚本生成）----------
    incar_basename="$(basename "$INCAR_FILE")"
    for f in "${EXTRA_FILES[@]}"; do
        if [[ "$(basename "$f")" == "$incar_basename" ]]; then
            continue  # INCAR 已由脚本修改生成，跳过原文件避免覆盖
        fi
        if [[ -f "$f" ]]; then
            cp "$f" "${dir_name}/"
            echo "  [${dir_name}] 已复制 $f"
        fi
    done

    echo "  → 完成：$dir_name/"
    echo ""

done

echo "========================================"
echo "  全部完成，共生成 ${#VALUES[@]} 个测试文件夹"
echo "========================================"
