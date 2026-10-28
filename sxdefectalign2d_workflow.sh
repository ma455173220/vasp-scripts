#!/bin/bash

# ==================== 用户配置区 ====================
# 作业脚本名称（在当前目录中查找）
SXDEFECT_JOB="${SXDEFECT_JOB:-sxdefect_job}"

# 要复制的文件列表（空格分隔），格式: 源文件名:目标文件名
# 查找顺序: 当前目录中的目标文件名（用户自定义版本）→ 本脚本所在目录的源文件 → 当前目录的源文件
# 注意: sxdefectalign2d_iterative.py 需要参考 LOCPOT: --vref <路径> 或环境变量 VREF_LOCPOT
FILES_TO_COPY="sxdefectalign2d_iterative.py:sxdefectalign2d_iterative-gam.py sxdefectalign2d_system.sx:system.sx $SXDEFECT_JOB:$SXDEFECT_JOB"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 文件夹前缀列表（空格分隔）
FOLDER_PREFIXES="v_S v_Zr S_Zr Zr_S S_i_C3v_Zr2.29 Zr_i_C3v_S2.22"

# 次级文件夹名称
SUBFOLDER_NAME="vasp_gam_lreal-false"

# 要执行的命令
COMMAND="sbatch --qos=high $SXDEFECT_JOB"

# 是否实际执行命令 (true/false)
EXECUTE_COMMAND=true
# ===================================================

# 提取电荷数的函数
extract_charge() {
    local folder_name=$1
    # 匹配模式: folder_+数字 或 folder_-数字 或 folder_0
    if [[ $folder_name =~ _\+([0-9]+)$ ]]; then
        echo "+${BASH_REMATCH[1]}"
    elif [[ $folder_name =~ _-([0-9]+)$ ]]; then
        echo "-${BASH_REMATCH[1]}"
    elif [[ $folder_name =~ _0$ ]]; then
        echo "0"
    else
        echo ""
    fi
}

# 查找源文件: 当前目录的目标名 → 脚本目录的源名 → 当前目录的源名
resolve_file() {
    local src=$1 dest=$2
    if [ -f "$dest" ]; then
        echo "$dest"
    elif [ -f "$SCRIPT_DIR/$src" ]; then
        echo "$SCRIPT_DIR/$src"
    elif [ -f "$src" ]; then
        echo "$src"
    fi
}

# 反转电荷符号的函数
reverse_charge() {
    local charge=$1
    if [[ $charge == "0" ]]; then
        echo "0"
    elif [[ $charge == +* ]]; then
        echo "-${charge#+}"
    elif [[ $charge == -* ]]; then
        echo "+${charge#-}"
    else
        echo ""
    fi
}

# 主处理循环
for prefix in $FOLDER_PREFIXES; do
    echo "========================================="
    echo "Processing folders with prefix: $prefix"
    echo "========================================="

    # 查找所有匹配前缀的文件夹
    for folder in ${prefix}_*; do
        # 检查是否是目录
        if [ ! -d "$folder" ]; then
            continue
        fi

        # 提取电荷数
        charge=$(extract_charge "$folder")
        if [ -z "$charge" ]; then
            echo "Warning: Cannot extract charge from folder name: $folder, skipping..."
            continue
        fi

        # 跳过电荷为0的文件夹
        if [ "$charge" == "0" ]; then
            echo "Skipping $folder (charge = 0)"
            continue
        fi

        # 目标路径
        target_dir="$folder/$SUBFOLDER_NAME"

        # 检查次级文件夹是否存在
        if [ ! -d "$target_dir" ]; then
            echo "Warning: $target_dir does not exist, skipping..."
            continue
        fi

        echo ""
        echo "Processing: $folder -> $target_dir"

        # 计算Q值（电荷的负值）
        q_value=$(reverse_charge "$charge")
        echo "  Detected charge: $charge, Q value will be: $q_value"

        # 复制文件
        for entry in $FILES_TO_COPY; do
            src_name=${entry%%:*}
            file=${entry#*:}
            src=$(resolve_file "$src_name" "$file")
            if [ -n "$src" ]; then
                if [ "$file" == "system.sx" ]; then
                    # 特殊处理 system.sx 文件
                    echo "  Copying and modifying $src -> $file..."
                    sed "s/Q = [^;]*/Q = $q_value/" "$src" > "$target_dir/$file"
                else
                    # 普通复制
                    echo "  Copying $src -> $file..."
                    cp "$src" "$target_dir/$file"
                fi
            else
                echo "  Warning: $file ($src_name) not found in current directory or $SCRIPT_DIR"
            fi
        done

        # 执行命令
        if [ "$EXECUTE_COMMAND" = true ]; then
            echo "  Executing command in $target_dir..."
            cd "$target_dir"
            eval $COMMAND
            cd - > /dev/null
        fi

        echo "  ✓ Done with $folder"
    done
done

echo ""
echo "========================================="
echo "All processing complete!"
echo "========================================="
