#!/usr/bin/env python3
"""
make_supercell.py
-----------------
从 primitive cell 建超胞，并根据原胞的 MAGMOM 自动生成超胞的 MAGMOM。

原理：
  超胞的每个原子都能追溯到原胞中的某个原子（通过 ASE make_supercell 的映射），
  直接继承该原子在原胞中的磁矩即可。对于 G-AFM 体系，
  周期性平移会自动保证近邻反平行，无需手动逐个指定。

用法：
    # 最常用：2x2x2 超胞
    python make_supercell.py -f POSCAR --supercell 2 2 2

    # 非等比扩胞
    python make_supercell.py -f POSCAR --supercell 2 2 1

    # 自定义矩阵扩胞（适合斜方超胞）
    python make_supercell.py -f POSCAR --matrix "2 0 0 / 0 2 0 / 0 0 2"

    # 指定 MAGMOM（原胞原子顺序，空格分隔）
    python make_supercell.py -f POSCAR --supercell 2 2 2 --magmom "4 -4 0 0 0 0 0 0 0"

    # 只打印 MAGMOM，不写文件
    python make_supercell.py -f POSCAR --supercell 2 2 2 --no-export

依赖：
    pip install ase spglib numpy
"""

import argparse
import sys
import numpy as np
from ase.io import read, write
from ase.build import make_supercell


# ══════════════════════════════════════════════
# 核心函数
# ══════════════════════════════════════════════

def parse_magmom(magmom_str, natoms):
    """解析 MAGMOM 字符串，支持 VASP 格式如 '4 -4 6*0'。"""
    tokens = magmom_str.split()
    values = []
    for t in tokens:
        if '*' in t:
            count, val = t.split('*')
            values.extend([float(val)] * int(count))
        else:
            values.append(float(t))
    if len(values) != natoms:
        raise ValueError(
            f"MAGMOM 长度 {len(values)} 与原胞原子数 {natoms} 不符。"
        )
    return np.array(values)


def read_magmom_from_incar(incar_path):
    """尝试从 INCAR 文件读取 MAGMOM。"""
    try:
        with open(incar_path) as f:
            for line in f:
                line = line.split('#')[0].strip()
                if line.upper().startswith('MAGMOM'):
                    val_str = line.split('=', 1)[1].strip()
                    return val_str
    except FileNotFoundError:
        pass
    return None


def build_supercell_matrix(supercell_arg):
    """将 '2 2 2' 参数转成对角矩阵。"""
    a, b, c = supercell_arg
    return np.diag([a, b, c])


def parse_matrix_arg(matrix_str):
    """解析 '2 0 0 / 0 2 0 / 0 0 2' 格式的矩阵。"""
    rows = matrix_str.split('/')
    mat = []
    for row in rows:
        mat.append([float(x) for x in row.split()])
    M = np.array(mat, dtype=int)
    if M.shape != (3, 3):
        raise ValueError("矩阵必须是 3x3，格式如：'2 0 0 / 0 2 0 / 0 0 2'")
    return M


def expand_magmom(prim_magmom, prim_atoms, super_atoms):
    """
    将原胞 MAGMOM 扩展到超胞。

    ASE make_supercell 生成超胞时，原子顺序是按原胞原子顺序平铺的：
    [prim_atom_0 × n_repeats, prim_atom_1 × n_repeats, ...]
    但实际上 ASE 是交错排列的，需要用 get_tags() 或位置匹配来追溯。

    这里用最可靠的方法：通过超胞原子的分数坐标 mod 1 匹配原胞原子。
    """
    prim_frac  = prim_atoms.get_scaled_positions() % 1.0
    prim_syms  = prim_atoms.get_chemical_symbols()

    # 超胞的分数坐标需要转换到原胞的坐标系
    # 即：super_frac_in_prim = super_cart @ inv(prim_cell)
    prim_cell_inv = np.linalg.inv(prim_atoms.get_cell()[:])
    super_cart    = super_atoms.get_positions()
    super_frac_in_prim = (super_cart @ prim_cell_inv) % 1.0

    super_syms = super_atoms.get_chemical_symbols()
    super_magmom = np.zeros(len(super_atoms))

    for i, (frac, sym) in enumerate(zip(super_frac_in_prim, super_syms)):
        # 找原胞中同元素、坐标最近的原子
        best_idx  = None
        best_dist = 1e10
        for j, (pfrac, psym) in enumerate(zip(prim_frac, prim_syms)):
            if sym != psym:
                continue
            diff = (frac - pfrac) % 1.0
            diff = np.where(diff > 0.5, diff - 1.0, diff)
            dist = np.linalg.norm(diff)
            if dist < best_dist:
                best_dist = dist
                best_idx  = j

        if best_idx is None or best_dist > 0.1:
            print(f"  [警告] 超胞原子 {i+1}({sym}) 无法匹配原胞原子，磁矩设为 0。")
            super_magmom[i] = 0.0
        else:
            super_magmom[i] = prim_magmom[best_idx]

    return super_magmom


def format_magmom_vasp(magmom_arr, atoms):
    """
    生成 VASP INCAR 风格的 MAGMOM 字符串，连续相同值压缩为 N*val。
    """
    syms = atoms.get_chemical_symbols()
    tokens = []
    i = 0
    while i < len(magmom_arr):
        val   = magmom_arr[i]
        count = 1
        while i + count < len(magmom_arr) and magmom_arr[i + count] == val:
            count += 1
        if count > 1:
            tokens.append(f"{count}*{val:g}")
        else:
            tokens.append(f"{val:g}")
        i += count
    return " ".join(tokens)


# ══════════════════════════════════════════════
# 主程序
# ══════════════════════════════════════════════


def sort_atoms(atoms, magmom=None):
    """按元素排序，保持 POSCAR 同种元素连续，同步重排 MAGMOM。"""
    syms  = atoms.get_chemical_symbols()
    # 保持原胞中元素出现的先后顺序
    seen, order = [], []
    for s in syms:
        if s not in seen:
            seen.append(s)
    idx_sorted = sorted(range(len(syms)), key=lambda i: seen.index(syms[i]))
    sorted_atoms = atoms[idx_sorted]
    sorted_magmom = magmom[idx_sorted] if magmom is not None else None
    return sorted_atoms, sorted_magmom


def main():
    parser = argparse.ArgumentParser(
        description="从 primitive cell 建超胞并自动生成 MAGMOM。"
    )
    parser.add_argument("-f", "--file", default="POSCAR",
        help="输入结构文件（默认：POSCAR）")
    parser.add_argument("--supercell", "-s", type=int, nargs=3,
        metavar=("A", "B", "C"), default=[1, 1, 1],
        help="沿 a/b/c 方向的扩胞倍数，如 --supercell 2 2 2")
    parser.add_argument("--matrix", "-m", type=str, default=None,
        help="自定义扩胞矩阵，如 --matrix '2 0 0 / 0 2 0 / 0 0 2'")
    parser.add_argument("--magmom", type=str, default=None,
        help="原胞 MAGMOM，空格分隔，支持 N*val 格式，"
             "如 '4 -4 6*0'。若不指定则尝试读取同目录 INCAR。")
    parser.add_argument("--incar", type=str, default="INCAR",
        help="INCAR 文件路径（用于自动读取 MAGMOM，默认：INCAR）")
    parser.add_argument("--outfile", "-o", type=str, default="POSCAR_super",
        help="输出文件名（默认：POSCAR_super）")
    parser.add_argument("--export", action="store_true",
        help="写出超胞 POSCAR（默认只打印 MAGMOM）")
    args = parser.parse_args()

    # ── 读取结构 ──
    try:
        prim = read(args.file)
    except Exception as e:
        print(f"[错误] 读取结构失败：{e}", file=sys.stderr)
        sys.exit(1)
    if "momenta" in prim.arrays:
        del prim.arrays["momenta"]

    natoms_prim = len(prim)
    print(f"\n原胞：{args.file}  ({natoms_prim} 原子)")
    print(f"  元素：{prim.get_chemical_formula()}")

    # ── 构建扩胞矩阵 ──
    if args.matrix:
        try:
            M = parse_matrix_arg(args.matrix)
        except ValueError as e:
            print(f"[错误] {e}", file=sys.stderr)
            sys.exit(1)
    else:
        M = build_supercell_matrix(args.supercell)

    print(f"  扩胞矩阵：\n{M}\n")

    # ── 建超胞 ──
    super_atoms = make_supercell(prim, M)
    if "momenta" in super_atoms.arrays:
        del super_atoms.arrays["momenta"]
    # 按元素排序（VASP 要求同种元素连续）
    super_atoms, _ = sort_atoms(super_atoms)
    n_repeat = abs(int(round(np.linalg.det(M))))
    print(f"超胞：{len(super_atoms)} 原子  ({n_repeat}× 原胞)")
    print(f"  元素：{super_atoms.get_chemical_formula()}\n")

    # ── 处理 MAGMOM ──
    magmom_str = args.magmom

    # 没有指定就尝试读 INCAR
    if magmom_str is None:
        magmom_str = read_magmom_from_incar(args.incar)
        if magmom_str:
            print(f"  从 {args.incar} 读取 MAGMOM：{magmom_str}")

    if magmom_str is None:
        print("  [提示] 未提供 MAGMOM，也未找到 INCAR。")
        print("         请用 --magmom '4 -4 0 0 0 0 0 0 0' 指定原胞磁矩。\n")
        # 仍然写出结构，只是没有 MAGMOM
        if args.export:
            write(args.outfile, super_atoms, format="vasp", direct=True)
            print(f"已写出超胞结构（无 MAGMOM）→ {args.outfile}")
        sys.exit(0)

    try:
        prim_magmom = parse_magmom(magmom_str, natoms_prim)
    except ValueError as e:
        print(f"[错误] {e}", file=sys.stderr)
        sys.exit(1)

    print("原胞 MAGMOM：")
    syms = prim.get_chemical_symbols()
    for i, (s, m) in enumerate(zip(syms, prim_magmom)):
        print(f"  原子 {i+1:>3} ({s}): {m:+.1f}")

    # ── 扩展 MAGMOM 到超胞 ──
    super_magmom = expand_magmom(prim_magmom, prim, super_atoms)

    # ── 打印结果 ──
    # 同步排序结构和 MAGMOM
    super_atoms, super_magmom = sort_atoms(super_atoms, super_magmom)
    vasp_magmom = format_magmom_vasp(super_magmom, super_atoms)
    total_mag   = super_magmom.sum()

    print(f"\n超胞 MAGMOM（共 {len(super_atoms)} 个值）：")
    print(f"  {vasp_magmom}")
    print(f"\n  总磁矩：{total_mag:+.1f} μB  ", end="")
    print("✓ 抵消（AFM）" if abs(total_mag) < 0.1 else "⚠ 未完全抵消，请检查！")

    print(f"\n写入 INCAR 时使用：")
    print(f"  MAGMOM = {vasp_magmom}\n")

    # ── 写出结构 ──
    if args.export:
        write(args.outfile, super_atoms, format="vasp", direct=True)
        print(f"已写出超胞结构 → {args.outfile}")


if __name__ == "__main__":
    main()
