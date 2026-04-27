#!/usr/bin/env python3
"""
vacancy_generator.py
--------------------
识别 POSCAR/结构文件中不等价位点，生成含 N 个空穴或置换缺陷的所有不等价组合结构。
可选：复制 VASP 输入文件、生成 POTCAR、添加原子微扰、提交 SLURM/PBS 任务。

用法：
    python vacancy_generator.py                         # 单空穴（默认）
    python vacancy_generator.py --nvac 2                # 双空穴
    python vacancy_generator.py --sub Fe                # O→Fe 置换
    python vacancy_generator.py --nvac 2 --export       # 枚举并写出文件
    python vacancy_generator.py --nvac 2 --export --interactive  # 交互式完整流程

依赖：
    pip install spglib ase
"""

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

import numpy as np
import spglib
from ase.io import read, write


# ══════════════════════════════════════════════════════════════════════════════
# 基础工具
# ══════════════════════════════════════════════════════════════════════════════

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


def substitute_atom(atoms, global_idx, new_element):
    """将指定索引的原子替换为 new_element，保持位置不变。"""
    new_atoms = atoms.copy()
    syms = list(new_atoms.get_chemical_symbols())
    syms[global_idx] = new_element
    new_atoms.set_chemical_symbols(syms)
    return new_atoms


# ══════════════════════════════════════════════════════════════════════════════
# 多缺陷核心：递归枚举（vacancy 或 substitution）
# ══════════════════════════════════════════════════════════════════════════════

def enumerate_multi_defect(atoms, element, symprec, nvac, sub_element=None,
                           _depth=0, _prefix=()):
    """
    递归枚举 nvac 个不等价缺陷组合。

    sub_element=None  → vacancy（删除原子）
    sub_element='Fe'  → substitution（原子替换）

    Returns list of dict:
        label        : 位点标签，如 "site1(e)+site2(f)"
        atoms_final  : 含 nvac 个缺陷的 Atoms
        wyckoffs     : 每步 Wyckoff 字母列表
        defect_indices_frac : 每步缺陷位置（分数坐标，用于后续微扰）
    """
    if nvac == 0:
        return [{"label": "", "atoms_final": atoms,
                 "wyckoffs": [], "defect_frac": []}]

    sites, _ = find_inequiv(atoms, element, symprec)
    if not sites:
        return []

    results = []
    for i, site in enumerate(sites):
        del_idx   = site["representative"]
        frac_pos  = atoms.get_scaled_positions()[del_idx].copy()

        if sub_element is None:
            new_atoms = remove_atom(atoms, del_idx)
            # 置换后递归时索引会偏移，vacancy 需要修正
            sub = enumerate_multi_defect(
                new_atoms, element, symprec, nvac - 1, sub_element,
                _depth + 1, _prefix + (del_idx,)
            )
        else:
            new_atoms = substitute_atom(atoms, del_idx, sub_element)
            sub = enumerate_multi_defect(
                new_atoms, element, symprec, nvac - 1, sub_element,
                _depth + 1, _prefix + (del_idx,)
            )

        for s in sub:
            depth_label = f"site{i+1}({site['wyckoff']})"
            s["label"]   = depth_label + ("+" + s["label"] if s["label"] else "")
            s["wyckoffs"] = [site["wyckoff"]] + s["wyckoffs"]
            s["defect_frac"] = [frac_pos] + s["defect_frac"]
            results.append(s)

    return results


# ══════════════════════════════════════════════════════════════════════════════
# 去重
# ══════════════════════════════════════════════════════════════════════════════

def structure_key(atoms, symprec):
    """
    (空间群编号, 元素符号列表排序, 所有原子分数坐标排序) 作为哈希键。
    """
    try:
        ds  = get_dataset(atoms, symprec)
        sgn = ds.number
    except RuntimeError:
        sgn = -1
    syms_coords = tuple(sorted(
        (sym, tuple(np.round(fc % 1.0, 4)))
        for sym, fc in zip(atoms.get_chemical_symbols(),
                           atoms.get_scaled_positions())
    ))
    return (sgn, syms_coords)


def deduplicate(candidates, symprec):
    seen, unique = {}, []
    for cand in candidates:
        key = structure_key(cand["atoms_final"], symprec)
        if key not in seen:
            seen[key] = True
            unique.append(cand)
    return unique


# ══════════════════════════════════════════════════════════════════════════════
# 功能 3：原子微扰（symmetry breaking perturbation）
# ══════════════════════════════════════════════════════════════════════════════

def apply_perturbation(atoms, defect_frac_list, amplitude=0.05,
                       radius=3.0, seed=None):
    """
    对缺陷位点邻近原子施加随机微扰以打破对称性。

    参数：
        atoms          : ASE Atoms 对象
        defect_frac_list : 缺陷位置的分数坐标列表（vacancy 取删除前坐标）
        amplitude      : 最大位移幅度（Å），默认 0.05 Å
        radius         : 微扰半径（Å），默认 3.0 Å（仅影响此范围内原子）
        seed           : 随机种子（可重复性）

    只扰动 Cartesian 坐标，不改变晶胞参数。
    """
    rng       = np.random.default_rng(seed)
    new_atoms = atoms.copy()
    cell      = atoms.get_cell()
    cart_pos  = atoms.get_positions()
    n_atoms   = len(atoms)

    # 将缺陷分数坐标转为 Cartesian
    defect_carts = [cell.T @ frac for frac in defect_frac_list]

    perturbed_mask = np.zeros(n_atoms, dtype=bool)

    for d_cart in defect_carts:
        for i in range(n_atoms):
            # 最小镜像距离
            diff = cart_pos[i] - d_cart
            # 粗略 MIC（单胞尺度合理）
            frac_diff = np.linalg.solve(cell.T, diff)
            frac_diff -= np.round(frac_diff)
            mic_dist  = np.linalg.norm(cell.T @ frac_diff)
            if mic_dist < radius:
                perturbed_mask[i] = True

    # 对受影响原子施加各向同性随机位移
    displacements = rng.uniform(-amplitude, amplitude, (n_atoms, 3))
    displacements[~perturbed_mask] = 0.0
    new_atoms.set_positions(cart_pos + displacements)
    return new_atoms, int(perturbed_mask.sum())


# ══════════════════════════════════════════════════════════════════════════════
# 打印
# ══════════════════════════════════════════════════════════════════════════════

def print_single_summary(atoms, sites, ds, element):
    n_elem = sum(1 for s in atoms.get_chemical_symbols() if s == element)
    print("=" * 65)
    print("  结构分析报告")
    print("=" * 65)
    print(f"  总原子数          : {len(atoms)}")
    print(f"  {element} 原子总数      : {n_elem}")
    print(f"  空间群            : {ds.international} (No. {ds.number})")
    print(f"  不等价 {element} 位点数  : {len(sites)}")
    print("=" * 65)
    print()
    print(f"  {'#':>3}  {'Wyckoff':>8}  {'等价数':>6}  {'分数坐标 (x,y,z)':>30}  代表原子（1-based）")
    print("  " + "-" * 80)
    for i, s in enumerate(sites):
        fc = s["frac_coord"]
        print(f"  {i+1:>3}  {s['wyckoff']:>8}  {len(s['equiv_indices']):>6}  "
              f"({fc[0]:7.4f},{fc[1]:7.4f},{fc[2]:7.4f})  {s['representative']+1}")
    print()


def print_multi_summary(unique, nvac, element, symprec, sub_element=None):
    mode = f"→{sub_element} 置换" if sub_element else "空穴"
    print("=" * 70)
    print(f"  不等价 {nvac} {element} {mode}组合（去重后）")
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


# ══════════════════════════════════════════════════════════════════════════════
# 功能 1：写出结构 + 复制输入文件 + 生成 POTCAR + 提交任务
# ══════════════════════════════════════════════════════════════════════════════

def ask_yes_no(prompt, default=True):
    """交互式 yes/no 询问。"""
    hint = "[Y/n]" if default else "[y/N]"
    while True:
        ans = input(f"  {prompt} {hint}: ").strip().lower()
        if ans == "":
            return default
        if ans in ("y", "yes"):
            return True
        if ans in ("n", "no"):
            return False
        print("  请输入 y 或 n。")


def ask_str(prompt, default=None):
    hint = f"（默认：{default}）" if default else ""
    ans = input(f"  {prompt}{hint}: ").strip()
    return ans if ans else default


def interactive_setup():
    """
    交互式询问：
      - 是否复制 INCAR / KPOINTS / 运行脚本
      - 是否生成 POTCAR
      - 是否添加微扰
      - 是否提交任务
    返回配置 dict。
    """
    print()
    print("━" * 55)
    print("  交互式配置")
    print("━" * 55)

    cfg = {}

    # ── VASP 输入文件 ──
    cfg["copy_inputs"] = ask_yes_no("复制 INCAR / KPOINTS / 运行脚本到各子目录？")
    if cfg["copy_inputs"]:
        cfg["incar"]    = ask_str("INCAR 路径", "INCAR")
        cfg["kpoints"]  = ask_str("KPOINTS 路径", "KPOINTS")
        cfg["runscript"]= ask_str("运行脚本路径（空=跳过）", "")

    # ── POTCAR ──
    cfg["gen_potcar"] = ask_yes_no("用 vaspkit 自动生成 POTCAR（在每个缺陷目录内运行）？")

    # ── 微扰 ──
    cfg["perturb"] = ask_yes_no("对缺陷邻域添加随机微扰（打破对称性）？")
    if cfg["perturb"]:
        amp_str = ask_str("最大微扰幅度 Å", "0.05")
        rad_str = ask_str("微扰半径 Å", "3.0")
        cfg["perturb_amplitude"] = float(amp_str)
        cfg["perturb_radius"]    = float(rad_str)
        cfg["perturb_seed"]      = 42   # 固定种子保证可重复

    # ── 提交 ──
    cfg["submit"] = ask_yes_no("写出文件后自动提交任务？")
    if cfg["submit"]:
        cfg["scheduler"]   = ask_str("调度器（slurm/pbs）", "slurm")
        cfg["submit_cmd"]  = ask_str("提交命令", "sbatch")
        cfg["submit_script"]= ask_str("提交脚本名", cfg.get("runscript", "run.sh") or "run.sh")

    print()
    return cfg



def generate_potcar(workdir):
    """
    在 workdir 内运行 `echo -e "103\n" | vaspkit` 生成 POTCAR。
    vaspkit 会读取当前目录的 POSCAR 自动判断元素顺序，因此必须在
    POSCAR 已写出之后、进入该目录再调用。
    """
    cmd = 'echo -e "103\n" | vaspkit'
    try:
        result = subprocess.run(
            cmd, shell=True, cwd=str(workdir),
            capture_output=True, text=True, timeout=60
        )
        potcar_path = Path(workdir) / "POTCAR"
        if potcar_path.exists():
            print(f"  [POTCAR] vaspkit 生成成功 → {workdir.name}/POTCAR")
        else:
            print(f"  [警告] vaspkit 未生成 POTCAR（检查 vaspkit 配置）")
            if result.stdout:
                print(f"    stdout: {result.stdout.strip()[:200]}")
            if result.stderr:
                print(f"    stderr: {result.stderr.strip()[:200]}")
    except subprocess.TimeoutExpired:
        print(f"  [错误] vaspkit 超时（workdir: {workdir}）")
    except FileNotFoundError:
        print("  [错误] 找不到 vaspkit，请确认已加载对应模块或在 PATH 中")


def write_structures(unique, nvac, element, outdir, sub_element=None, cfg=None):
    """写出结构，并根据 cfg 复制输入文件、生成 POTCAR、提交任务。"""
    outdir = Path(outdir)
    outdir.mkdir(parents=True, exist_ok=True)

    defect_tag = f"{element}sub{sub_element}{nvac}" if sub_element else f"{element}vac{nvac}"

    for i, cand in enumerate(unique):
        wyk_str = "-".join(cand["wyckoffs"])
        dirname = outdir / f"{defect_tag}_{i+1:03d}_{wyk_str}"
        dirname.mkdir(parents=True, exist_ok=True)

        # ── 微扰 ──
        final_atoms = cand["atoms_final"]
        if cfg and cfg.get("perturb") and cand.get("defect_frac"):
            final_atoms, n_perturbed = apply_perturbation(
                final_atoms,
                cand["defect_frac"],
                amplitude=cfg["perturb_amplitude"],
                radius=cfg["perturb_radius"],
                seed=cfg.get("perturb_seed"),
            )
            print(f"  [微扰] {dirname.name}: 影响 {n_perturbed} 个原子")

        # ── 写 POSCAR ──
        poscar_out = dirname / "POSCAR"
        write(str(poscar_out), final_atoms, format="vasp", direct=True)
        print(f"  [写出] {i+1:>3}  {cand['label']:<42} → {dirname.name}/POSCAR")

        # ── 复制输入文件 ──
        if cfg and cfg.get("copy_inputs"):
            for key, fname in [("incar", "INCAR"), ("kpoints", "KPOINTS")]:
                src = cfg.get(key, "")
                if src and Path(src).exists():
                    shutil.copy(src, dirname / fname)
                    print(f"         复制 {fname} → {dirname.name}/")
                elif src:
                    print(f"  [警告] 找不到 {src}，跳过复制 {fname}")

            rs = cfg.get("runscript", "")
            if rs and Path(rs).exists():
                dst_name = Path(rs).name
                shutil.copy(rs, dirname / dst_name)
                print(f"         复制 {dst_name} → {dirname.name}/")
            elif rs:
                print(f"  [警告] 找不到运行脚本 {rs}")

        # ── 生成 POTCAR（在 POSCAR 写出后、在该目录内运行 vaspkit）──
        if cfg and cfg.get("gen_potcar"):
            generate_potcar(dirname)

        # ── 提交任务 ──
        if cfg and cfg.get("submit"):
            script = cfg.get("submit_script", "run.sh")
            script_path = dirname / Path(script).name
            if script_path.exists():
                cmd = [cfg.get("submit_cmd", "sbatch"), str(script_path.name)]
                try:
                    result = subprocess.run(
                        cmd, cwd=str(dirname),
                        capture_output=True, text=True, check=True
                    )
                    print(f"  [提交] {dirname.name}: {result.stdout.strip()}")
                except subprocess.CalledProcessError as e:
                    print(f"  [错误] 提交失败 {dirname.name}: {e.stderr.strip()}")
            else:
                print(f"  [警告] 提交脚本不存在：{script_path}，跳过提交")


# ══════════════════════════════════════════════════════════════════════════════
# 主程序
# ══════════════════════════════════════════════════════════════════════════════

def main():
    parser = argparse.ArgumentParser(
        description="枚举超胞中不等价的 N 个空穴/置换缺陷组合，生成对应 POSCAR。"
    )
    parser.add_argument("-f", "--file", default="POSCAR",
        help="输入结构文件（默认：POSCAR）")
    parser.add_argument("--element", "-e", default="O",
        help="目标元素（默认：O）")
    parser.add_argument("--nvac", "-n", type=int, default=1,
        help="缺陷数量（默认：1）")
    parser.add_argument("--sub", default=None, metavar="ELEMENT",
        help="置换目标元素（默认：None 即 vacancy）。如 --sub Fe 表示 O→Fe 置换")
    parser.add_argument("--symprec", "-s", type=float, default=1e-2,
        help="spglib 对称精度 Å（默认：0.01）")
    parser.add_argument("--outdir", "-o", default=None,
        help="输出目录（默认：{element}_vac{nvac}/ 或 {element}_sub{sub}{nvac}/）")
    parser.add_argument("--export", action="store_true",
        help="写出缺陷结构文件（默认只分析打印）")
    parser.add_argument("--interactive", "-i", action="store_true",
        help="交互式配置：复制输入文件 / 生成 POTCAR / 微扰 / 提交任务")
    # 非交互式微扰参数
    parser.add_argument("--perturb", action="store_true",
        help="对缺陷邻域添加随机微扰（非交互式，配合 --amplitude / --radius）")
    parser.add_argument("--amplitude", type=float, default=0.05,
        help="微扰幅度 Å（默认：0.05）")
    parser.add_argument("--radius", type=float, default=3.0,
        help="微扰半径 Å（默认：3.0）")
    args = parser.parse_args()

    sub_element = args.sub
    defect_tag  = (f"{args.element}_sub{sub_element}{args.nvac}"
                   if sub_element else f"{args.element}_vac{args.nvac}")
    outdir      = args.outdir or defect_tag

    # ── 读取结构 ──
    try:
        atoms = read(args.file)
        if "momenta" in atoms.arrays:
            del atoms.arrays["momenta"]
    except Exception as e:
        print(f"[错误] 读取结构失败：{e}", file=sys.stderr)
        sys.exit(1)

    mode_str = f"O→{sub_element} 置换" if sub_element else "O 空穴"
    print(f"\n读取结构：{args.file}  ({len(atoms)} 原子)")
    print(f"缺陷模式：{mode_str}  ×{args.nvac}\n")

    # ── 原始结构不等价位点 ──
    sites, ds = find_inequiv(atoms, args.element, args.symprec)
    if not sites:
        print(f"[错误] 结构中没有 {args.element} 原子。", file=sys.stderr)
        sys.exit(1)
    print_single_summary(atoms, sites, ds, args.element)

    # ── 交互式配置 ──
    cfg = None
    if args.interactive and args.export:
        cfg = interactive_setup()
    elif args.perturb:
        # 非交互式微扰
        cfg = {
            "perturb"          : True,
            "perturb_amplitude": args.amplitude,
            "perturb_radius"   : args.radius,
            "perturb_seed"     : 42,
        }

    # ── 单缺陷快速路径 ──
    if args.nvac == 1:
        unique = []
        for i, s in enumerate(sites):
            if sub_element is None:
                fa = remove_atom(atoms, s["representative"])
            else:
                fa = substitute_atom(atoms, s["representative"], sub_element)
            unique.append({
                "label"      : f"site{i+1}({s['wyckoff']})",
                "atoms_final": fa,
                "wyckoffs"   : [s["wyckoff"]],
                "defect_frac": [s["frac_coord"]],
            })
        if args.export:
            print(f"正在生成单缺陷结构 → {outdir}/\n")
            write_structures(unique, 1, args.element, outdir, sub_element, cfg)
            print(f"\n完成！共生成 {len(unique)} 个结构。\n")
        else:
            print(f"  共 {len(unique)} 个不等价位点（使用 --export 写出结构）\n")
        return

    # ── 多缺陷枚举 ──
    n_elem = sum(1 for s in atoms.get_chemical_symbols() if s == args.element)
    if args.nvac > n_elem:
        print(f"[错误] 请求 {args.nvac} 个缺陷，但只有 {n_elem} 个 {args.element}。",
              file=sys.stderr)
        sys.exit(1)

    print(f"枚举 {args.nvac} 缺陷组合（递归对称分析）...")
    candidates = enumerate_multi_defect(
        atoms, args.element, args.symprec, args.nvac, sub_element
    )
    print(f"  枚举完毕，原始候选数：{len(candidates)}")

    unique = deduplicate(candidates, args.symprec)
    print(f"  去重后唯一结构数：{len(unique)}\n")

    print_multi_summary(unique, args.nvac, args.element, args.symprec, sub_element)

    if args.export:
        print(f"正在写出结构 → {outdir}/\n")
        write_structures(unique, args.nvac, args.element, outdir, sub_element, cfg)
        print(f"\n完成！共生成 {len(unique)} 个不等价缺陷结构。\n")
    else:
        print("  使用 --export 写出结构文件。\n")


if __name__ == "__main__":
    main()
