#!/bin/bash

# Gibbs计算设置脚本
echo "开始设置Gibbs计算..."

# 1. 创建Gibbs文件夹
if [ -d "Gibbs" ]; then
    echo "警告: Gibbs文件夹已存在，将删除并重新创建"
    rm -rf Gibbs
fi
mkdir Gibbs
echo "已创建Gibbs文件夹"

# 2. 复制必要文件到Gibbs文件夹
required_files=("INCAR" "CONTCAR" "KPOINTS" "POTCAR" "vasp_runscript")
for file in "${required_files[@]}"; do
    if [ -f "$file" ]; then
        cp "$file" Gibbs/
        echo "已复制 $file"
    else
        echo "错误: 找不到文件 $file"
        exit 1
    fi
done

# 进入Gibbs文件夹
cd Gibbs

# 3. 将CONTCAR重命名为POSCAR
if [ -f "CONTCAR" ]; then
    mv CONTCAR POSCAR
    echo "已将CONTCAR重命名为POSCAR"
else
    echo "错误: CONTCAR文件不存在"
    exit 1
fi

# 生成gamma点KPOINTS文件
echo "生成gamma点KPOINTS..."
echo -e "102\n2\n0" | vaspkit > /dev/null 2>&1
if [ -f "KPOINTS" ]; then
    echo "已生成gamma点KPOINTS文件"
else
    echo "警告: vaspkit可能未成功生成KPOINTS文件"
fi

# 4. 运行center-of-mass.py获取质心坐标
echo "运行center-of-mass.py计算质心..."

# 运行center-of-mass.py并提取质心坐标
output=$(center-of-mass.py POSCAR)
echo "$output"

# 提取[]内的内容作为dipol变量
dipol=$(echo "$output" | grep -o '\[.*\]' | sed 's/\[//g' | sed 's/\]//g' | tr -s ' ')
if [ -z "$dipol" ]; then
    echo "错误: 无法从center-of-mass.py输出中提取质心坐标"
    exit 1
fi
echo "提取的质心坐标: $dipol"

# 5. 修改INCAR文件中的DIPOL值
echo "修改INCAR文件..."
if [ -f "INCAR" ]; then
    # 只修改DIPOL行（不影响LDIPOL和IDIPOL）
    sed -i "s/^DIPOL\s*=.*/DIPOL = $dipol/" INCAR
    echo "已更新DIPOL = $dipol"
else
    echo "错误: INCAR文件不存在"
    exit 1
fi

# 6. 修改NSW和注释优化相关参数
echo "修改结构优化相关参数..."

# 将NSW改为1
sed -i 's/NSW\s*=\s*[0-9]*/NSW = 1/' INCAR
echo "已将NSW改为1"

# 注释掉IOPT = 7 ; POTIM = 0 ; IBRION = 3这一整行
sed -i 's/^IOPT = 7 ; POTIM = 0 ; IBRION = 3/#IOPT = 7 ; POTIM = 0 ; IBRION = 3/' INCAR
echo "已注释掉优化器设置行"

# 注释掉NEB相关参数（IMAGES, SPRING, LCLIMB, ICHAIN, IOPT开头的行）
sed -i 's/^IMAGES\s*=/#IMAGES =/' INCAR
sed -i 's/^SPRING\s*=/#SPRING =/' INCAR
sed -i 's/^LCLIMB\s*=/#LCLIMB =/' INCAR
sed -i 's/^ICHAIN\s*=/#ICHAIN =/' INCAR
sed -i 's/^IOPT\s*=/#IOPT =/' INCAR
echo "已注释掉NEB相关参数（IMAGES, SPRING, LCLIMB, ICHAIN, IOPT）"

# 修改EDIFF为1E-07
if grep -q "^EDIFF\s*=" INCAR; then
    sed -i 's/^EDIFF\s*=.*/EDIFF = 1E-07/' INCAR
    echo "已将EDIFF改为1E-07"
else
    echo "EDIFF = 1E-07" >> INCAR
    echo "已添加EDIFF = 1E-07"
fi

# 7. 设置Gibbs计算参数
echo "设置Gibbs计算参数..."

# 设置或修改IBRION为5
if grep -q "^IBRION\s*=" INCAR; then
    sed -i 's/^IBRION\s*=.*/IBRION = 5/' INCAR
else
    echo "IBRION = 5" >> INCAR
fi

# 设置或修改POTIM为0.015
if grep -q "^POTIM\s*=" INCAR; then
    sed -i 's/^POTIM\s*=.*/POTIM = 0.015/' INCAR
else
    echo "POTIM = 0.015" >> INCAR
fi

# 设置或修改NFREE为2
if grep -q "^NFREE\s*=" INCAR; then
    sed -i 's/^NFREE\s*=.*/NFREE = 2/' INCAR
else
    echo "NFREE = 2" >> INCAR
fi

# 设置或修改NWRITE为3
if grep -q "^NWRITE\s*=" INCAR; then
    sed -i 's/^NWRITE\s*=.*/NWRITE = 3/' INCAR
else
    echo "NWRITE = 3" >> INCAR
fi

echo "已设置IBRION = 5, POTIM = 0.015, NFREE = 2, NWRITE = 3"

# 8. 修改vasp_runscript中的VASP_EXE
echo "修改vasp_runscript..."
if [ -f "vasp_runscript" ]; then
    sed -i 's/VASP_EXE="vasp_std"/VASP_EXE="vasp_gam"/' vasp_runscript
    echo "已将VASP_EXE改为vasp_gam"
    
    # 修改SBATCH ntasks为128
    sed -i 's/^#SBATCH --ntasks=[0-9]*/#SBATCH --ntasks=128/' vasp_runscript
    echo "已将#SBATCH --ntasks改为128"
    
    # 修改SBATCH nodes为1
    sed -i 's/^#SBATCH --nodes=[0-9]*/#SBATCH --nodes=1/' vasp_runscript
    echo "已将#SBATCH --nodes改为1"
else
    echo "警告: vasp_runscript文件不存在"
fi

# 显示修改后的关键参数
echo ""
echo "=== INCAR关键参数检查 ==="
grep -E "^(DIPOL|NSW|IBRION|POTIM|NFREE|EDIFF)" INCAR
echo ""
echo "=== 被注释的行 ==="
grep "^#IOPT = 7" INCAR
grep "^#IMAGES\|^#SPRING\|^#LCLIMB\|^#ICHAIN\|^#IOPT" INCAR 2>/dev/null || echo "未找到被注释的NEB参数"
echo ""
echo "=== vasp_runscript中的关键设置 ==="
grep "VASP_EXE=" vasp_runscript 2>/dev/null || echo "未找到VASP_EXE设置"
grep "#SBATCH --ntasks=" vasp_runscript 2>/dev/null || echo "未找到ntasks设置"
grep "#SBATCH --nodes=" vasp_runscript 2>/dev/null || echo "未找到nodes设置"
echo ""

echo "Gibbs计算设置完成！"
echo "请检查Gibbs文件夹中的文件，然后运行vasp_runscript开始计算。"
