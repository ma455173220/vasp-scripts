#!/bin/bash

# ==================== 用户配置区 ====================
# 要复制的文件列表（空格分隔）
FILES_TO_COPY="sxdefectalign2d_iterative-gam.py system.sx sxdefect_job"

# 文件夹前缀列表（空格分隔）
FOLDER_PREFIXES="v_S v_Zr S_Zr Zr_S S_i_C3v_Zr2.29 Zr_i_C3v_S2.22"

# 次级文件夹名称
SUBFOLDER_NAME="vasp_gam_lreal-false"

# 要执行的命令
COMMAND="sbatch --qos=high sxdefect_job"

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
        for file in $FILES_TO_COPY; do
            if [ -f "$file" ]; then
                if [ "$file" == "system.sx" ]; then
                    # 特殊处理 system.sx 文件
                    echo "  Copying and modifying $file..."
                    sed "s/Q = [^;]*/Q = $q_value/" "$file" > "$target_dir/$file"
                else
                    # 普通复制
                    echo "  Copying $file..."
                    cp "$file" "$target_dir/"
                fi
            else
                echo "  Warning: $file not found in current directory"
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
