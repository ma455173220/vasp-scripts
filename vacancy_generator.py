#!/usr/bin/python3.12
"""
vacancy_generator.py
-----------------
识别 POSCAR/结构文件中不等价的 O 位点，生成含 N 个空穴的所有不等价组合结构。

核心思路（多空穴）：
  生成第一个空穴后，对新结构重新做对称性分析，再在剩余 O 中找不等价位点，
  以此递归。这样可以正确处理"第一个空穴降低对称性导致第二个空穴位点增多"
  的情况，避免遗漏或重复。

用法：
    python find_O_vacancy.py                  # 单空穴（默认）
    python find_O_vacancy.py --nvac 2         # 双空穴
    python find_O_vacancy.py --nvac 3         # 三空穴
    python find_O_vacancy.py --symprec 0.1    # 放宽对称精度（超胞畸变时）
    python find_O_vacancy.py --element Fe     # 其他元素
    python find_O_vacancy.py --nvac 2 --export      # 分析并写出文件

依赖：
    pip install spglib ase
"""

import argparse
import sys
from pathlib import Path

import numpy as np
import spglib
from ase.io import read, write


# ══════════════════════════════════════════════
# 基础工具
# ══════════════════════════════════════════════

def atoms_to_cell(atoms):
    return (atoms.get_cell()[:],
            atoms.get_scaled_positions(),
            atoms.get_atomic_numbers())


def get_dataset(atoms, symprec):
    ds = spglib.get_symmetry_dataset(atoms_to_cell(atoms), symprec=symprec)
    if ds is None:
        raise RuntimeError(
            f"spglib 无法识别对称性（symprec={symprec}）。"
            "请尝试增大 --symprec 或检查结构。"
        )
    return ds


def find_inequiv(atoms, element, symprec):
    """返回 element 在 atoms 中的不等价位点列表，以及 spglib dataset。"""
    ds      = get_dataset(atoms, symprec)
    equiv   = ds.equivalent_atoms
    wyckoff = ds.wyckoffs
    syms    = atoms.get_chemical_symbols()

    targets = [i for i, s in enumerate(syms) if s == element]
    if not targets:
        return [], ds

    groups = {}
    for idx in targets:
        rep = equiv[idx]
        groups.setdefault(rep, []).append(idx)

    result = []
    for rep, members in sorted(groups.items()):
        result.append({
            "wyckoff"       : wyckoff[rep],
            "equiv_indices" : sorted(members),
            "representative": members[0],
            "frac_coord"    : atoms.get_scaled_positions()[members[0]],
        })
    return result, ds


def remove_atom(atoms, global_idx):
    """删除指定全局索引的原子，返回新 Atoms 对象。"""
    mask = [i for i in range(len(atoms)) if i != global_idx]
    return atoms[mask]


# ══════════════════════════════════════════════
# 多空穴核心：递归枚举
# ══════════════════════════════════════════════

def enumerate_multi_vac(atoms, element, symprec, nvac, _depth=0, _prefix=()):
    """
    递归地枚举 nvac 个不等价空穴组合。

    每一层：
      1. 对当前结构做对称分析，找不等价 O 位点
      2. 对每个不等价位点删一个原子
      3. 递归处理剩余 nvac-1 个空穴

    Returns list of dict:
        label       : 位点标签，如 "site1(e)+site2(f)"
        atoms_final : 含 nvac 个空穴的 Atoms
        wyckoffs    : 每步 Wyckoff 字母列表
    """
    if nvac == 0:
        return [{"label": "", "atoms_final": atoms, "wyckoffs": []}]

    sites, _ = find_inequiv(atoms, element, symprec)
    if not sites:
        return []

    results = []
    for i, site in enumerate(sites):
        del_idx   = site["representative"]
        new_atoms = remove_atom(atoms, del_idx)

        sub = enumerate_multi_vac(
            new_atoms, element, symprec, nvac - 1,
            _depth + 1, _prefix + (del_idx,)
        )

        for s in sub:
            depth_label = f"site{i+1}({site['wyckoff']})"
            s["label"]   = depth_label + ("+" + s["label"] if s["label"] else "")
            s["wyckoffs"] = [site["wyckoff"]] + s["wyckoffs"]
            results.append(s)

    return results


# ══════════════════════════════════════════════
# 去重：基于最终结构的规范哈希
# ══════════════════════════════════════════════

def structure_key(atoms, symprec):
    """
    用 (空间群编号, 所有原子分数坐标排序后的规范形式) 作为结构哈希键。
    坐标规约到 [0,1) 并四舍五入到 4 位小数。
    """
    try:
        ds  = get_dataset(atoms, symprec)
        sgn = ds.number
    except RuntimeError:
        sgn = -1
    coords = tuple(sorted(
        tuple(np.round(fc % 1.0, 4))
        for fc in atoms.get_scaled_positions()
    ))
    return (sgn, coords)


def deduplicate(candidates, symprec):
    seen, unique = {}, []
    for cand in candidates:
        key = structure_key(cand["atoms_final"], symprec)
        if key not in seen:
            seen[key] = True
            unique.append(cand)
    return unique


# ══════════════════════════════════════════════
# 打印 & 输出
# ══════════════════════════════════════════════

def print_single_summary(atoms, sites, ds, element):
    n_elem = sum(1 for s in atoms.get_chemical_symbols() if s == element)
    print("=" * 65)
    print("  结构分析报告")
    print("=" * 65)
    print(f"  总原子数        : {len(atoms)}")
    print(f"  {element} 原子总数    : {n_elem}")
    print(f"  空间群          : {ds.international} (No. {ds.number})")
    print(f"  不等价 {element} 位点数: {len(sites)}")
    print("=" * 65)
    print()
    print(f"  {'#':>3}  {'Wyckoff':>8}  {'等价数':>6}  {'分数坐标 (x,y,z)':>30}  代表原子（1-based）")
    print("  " + "-" * 80)
    for i, s in enumerate(sites):
        fc = s["frac_coord"]
        print(f"  {i+1:>3}  {s['wyckoff']:>8}  {len(s['equiv_indices']):>6}  "
              f"({fc[0]:7.4f},{fc[1]:7.4f},{fc[2]:7.4f})  {s['representative']+1}")
    print()


def print_multi_summary(unique, nvac, element, symprec):
    print("=" * 70)
    print(f"  不等价 {nvac} 空穴组合（去重后）")
    print("=" * 70)
    print(f"  共 {len(unique)} 种不等价组合\n")
    print(f"  {'#':>4}  {'组合标签':<42}  {'最终空间群'}")
    print("  " + "-" * 75)
    for i, cand in enumerate(unique):
        try:
            ds = get_dataset(cand["atoms_final"], symprec)
            sg = f"{ds.international} (No.{ds.number})"
        except Exception:
            sg = "未知"
        print(f"  {i+1:>4}  {cand['label']:<42}  {sg}")
    print()


def write_structures(unique, nvac, element, outdir):
    outdir = Path(outdir)
    outdir.mkdir(parents=True, exist_ok=True)
    for i, cand in enumerate(unique):
        wyk_str = "-".join(cand["wyckoffs"])
        fname   = outdir / f"POSCAR_{element}vac{nvac}_{i+1:03d}_{wyk_str}"
        write(str(fname), cand["atoms_final"], format="vasp", direct=True)
        print(f"  [写出] {i+1:>3}  {cand['label']:<42} → {fname.name}")


# ══════════════════════════════════════════════
# 主程序
# ══════════════════════════════════════════════

def main():
    parser = argparse.ArgumentParser(
        description="枚举超胞中不等价的 N 个空穴组合，生成对应 POSCAR。"
    )
    parser.add_argument("-f", "--file", default="POSCAR", help="输入结构文件（默认：POSCAR）")
    parser.add_argument("--element", "-e", default="O",
        help="目标元素（默认：O）")
    parser.add_argument("--nvac", "-n", type=int, default=1,
        help="空穴数量（默认：1）")
    parser.add_argument("--symprec", "-s", type=float, default=1e-2,
        help="spglib 对称精度 Å（默认：0.01）。超胞畸变时可设 0.1")
    parser.add_argument("--outdir", "-o", default=None,
        help="输出目录（默认：{element}_vac{nvac}/）")
    parser.add_argument("--export", action="store_true",
        help="写出空穴结构文件（默认只分析打印）")
    args = parser.parse_args()

    outdir = args.outdir or f"{args.element}_vac{args.nvac}"

    # ── 读取结构 ──
    try:
        atoms = read(args.file)
        if "momenta" in atoms.arrays:  # 清除 POSCAR Cartesian 块被 ASE 误读为速度的情况
            del atoms.arrays["momenta"]
    except Exception as e:
        print(f"[错误] 读取结构失败：{e}", file=sys.stderr)
        sys.exit(1)

    print(f"\n读取结构：{args.file}  ({len(atoms)} 原子)\n")

    # ── 原始结构不等价位点展示 ──
    sites, ds = find_inequiv(atoms, args.element, args.symprec)
    if not sites:
        print(f"[错误] 结构中没有 {args.element} 原子。", file=sys.stderr)
        sys.exit(1)
    print_single_summary(atoms, sites, ds, args.element)

    # ── 单空穴 ──
    if args.nvac == 1:
        unique = [{"label"      : f"site{i+1}({s['wyckoff']})",
                   "atoms_final": remove_atom(atoms, s["representative"]),
                   "wyckoffs"   : [s["wyckoff"]]}
                  for i, s in enumerate(sites)]
        if args.export:
            print(f"正在生成单空穴结构 → {outdir}/")
            write_structures(unique, 1, args.element, outdir)
            print(f"\n完成！共生成 {len(unique)} 个结构。\n")
        return

    # ── 多空穴 ──
    n_elem = sum(1 for s in atoms.get_chemical_symbols() if s == args.element)
    if args.nvac > n_elem:
        print(f"[错误] 请求 {args.nvac} 个空穴，但只有 {n_elem} 个 {args.element}。",
              file=sys.stderr)
        sys.exit(1)

    print(f"枚举 {args.nvac} 空穴组合（递归对称分析）...")
    candidates = enumerate_multi_vac(atoms, args.element, args.symprec, args.nvac)
    print(f"  枚举完毕，原始候选数：{len(candidates)}")

    unique = deduplicate(candidates, args.symprec)
    print(f"  去重后唯一结构数：{len(unique)}\n")

    print_multi_summary(unique, args.nvac, args.element, args.symprec)

    if args.export:
        print(f"正在写出结构 → {outdir}/")
        write_structures(unique, args.nvac, args.element, outdir)
        print(f"\n完成！共生成 {len(unique)} 个不等价 {args.nvac} 空穴结构。\n")


if __name__ == "__main__":
    main()
