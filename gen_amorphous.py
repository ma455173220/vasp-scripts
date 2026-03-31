#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gen_amorphous.py — 非晶初始结构生成器
======================================

功能
----
从任意晶体结构出发，随机删除指定元素的原子（模拟空位缺陷），
并对剩余原子施加随机位移（打破长程序），生成适合 AIMD 非晶化
退火的初始结构，输出 VASP POSCAR 格式。

适用场景举例
------------
  · 电化学/辐照导致的氧化物非晶化（如 BFO、STO、LiCoO₂）
  · 离子嵌脱引起的结构无序（如 LiCoO₂ 大量脱 Li）
  · 高浓度空位缺陷超胞的批量生成
  · 任何需要"晶体 + 大量随机缺陷 + 大幅扰动"作为 AIMD 起点的场景

由于实验上空位浓度往往未知，脚本支持 --scan-concentration 模式，
一次性生成多个浓度的结构，后续通过 AIMD 结果筛选最合理的浓度。

依赖
----
    pip install ase numpy
    pip install spglib   # 可选，用于对称性去重

典型用法
--------
  【重要】请在运行脚本前自行建好超胞，脚本直接在输入结构上操作，
  不做任何扩胞。推荐用 vaspkit 或 ASE 建超胞：

    # vaspkit
    vaspkit -task 401   # 输入 3 3 3

    # ASE
    python3 -c "
    from ase.io import read, write
    write('POSCAR_333', read('POSCAR').repeat((3,3,3)), format='vasp', direct=True, vasp5=True)
    "

  【模式一】单一浓度
    python gen_amorphous.py \\
        --input      POSCAR_333 \\
        --target     O \\
        --concentration 0.25 \\
        --nstruct    3 \\
        --rattle     0.4 \\
        --seed       42 \\
        --outdir     amorphous

  【模式二】浓度扫描（推荐，用于浓度未知时）
    python gen_amorphous.py \\
        --input      POSCAR_333 \\
        --target     O \\
        --scan-concentration 0.25 0.375 0.50 \\
        --nstruct    3 \\
        --rattle     0.4 \\
        --seed       42 \\
        --outdir     amorphous_scan

参数说明
--------
--input                 输入结构文件（POSCAR / CIF / xyz 等 ASE 可读格式）
                        请提前建好超胞再传入，脚本不做扩胞
--target                要生成空位的元素符号，如 O、Li、N
--concentration         单一空位浓度（与 --scan-concentration 二选一）
                        相对于目标元素总数，如 0.25 = 删除 25% 的目标原子
--scan-concentration    浓度扫描列表，如 0.125 0.25 0.375 0.50
--nstruct               每个浓度生成的独立结构数，默认 3
--rattle                原子随机位移幅度（Å），默认 0.4
                          0.01–0.05 Å：普通缺陷晶体（打破对称性）
                          0.10–0.20 Å：轻度无序
                          0.30–0.50 Å：非晶初始结构（推荐）
                          > 0.5  Å：可能产生大量 overlap，不建议
--min-sep               空位间最小距离（Å），高浓度时建议不设
--seed                  全局随机种子，用于复现结果
--symprec               对称性去重容差（Å），高浓度非晶结构通常不需要
--outdir                输出根目录，默认 amorphous_structures
--max-attempts          单次 min-sep 约束最大重试次数，默认 5000
--overlap-hard          硬截断系数，默认 0.5
                        原子对距离 < 系数 × (r_cov_i + r_cov_j) 时丢弃重试
                        共价半径自动从 ASE 内置表读取，无需手动指定
--overlap-warn          软警告系数，默认 0.75，须大于 --overlap-hard
                        原子对距离 < 系数 × (r_cov_i + r_cov_j) 时保留结构
                        但在 summary.json 中记录违规原子对，方便事后筛查

输出目录结构
------------
  单一浓度模式：
    amorphous/
    ├── struct_000/POSCAR
    ├── struct_001/POSCAR
    ├── struct_002/POSCAR
    └── summary.json

  扫描模式：
    amorphous_scan/
    ├── conc_12.5%/
    │   ├── struct_000/POSCAR
    │   ├── struct_001/POSCAR
    │   ├── struct_002/POSCAR
    │   └── summary.json          ← 该浓度的详细记录
    ├── conc_25.0%/
    │   └── ...
    └── scan_summary.json         ← 所有浓度的汇总表

注意事项
--------
1. 高浓度（>37.5%）时建议不设 --min-sep，否则约束难以满足。
2. overlap 硬拒率高时（脚本会提示），可尝试减小 --rattle 或 --overlap-hard。
3. 建议 AIMD 使用高温退火（1500–2000 K）再淬火，而非直接在目标温度运行。
4. summary.json 中的 n_atoms_after 可直接用于核对生成的 POSCAR 原子数。
5. 软警告结构（overlap_status: warn）仍可提交 AIMD，VASP 通常能处理，
   但初始力可能较大，注意 IBRION/NSW 设置。
"""

import argparse
import json
import sys
from collections import Counter
from pathlib import Path

import numpy as np
from ase.data import covalent_radii, atomic_numbers
from ase.io import read, write
from ase.neighborlist import neighbor_list


# ---------------------------------------------------------------------------
# 参数解析与校验
# ---------------------------------------------------------------------------

def parse_args():
    parser = argparse.ArgumentParser(
        description="从晶体结构出发生成高空位浓度的 AIMD 非晶初始结构。",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument("--input", required=True,
                        help="输入结构文件（POSCAR / CIF / xyz 等）")
    parser.add_argument("--target", required=True,
                        help="要生成空位的元素符号，如 O、Li、N")

    conc_group = parser.add_mutually_exclusive_group(required=True)
    conc_group.add_argument("--concentration", type=float,
                            help="单一空位浓度，如 0.25")
    conc_group.add_argument("--scan-concentration", type=float, nargs="+",
                            metavar="CONC",
                            help="浓度扫描列表，如 0.125 0.25 0.375 0.50")

    parser.add_argument("--nstruct", type=int, default=3,
                        help="每个浓度生成的结构数，默认 3")
    parser.add_argument("--rattle", type=float, default=0.4,
                        help="原子随机位移幅度（Å），非晶化建议 0.3–0.5，默认 0.4")
    parser.add_argument("--min-sep", type=float, default=None,
                        help="空位间最小距离（Å），高浓度时建议不设")
    parser.add_argument("--seed", type=int, default=None,
                        help="全局随机种子，不指定则随机")
    parser.add_argument("--symprec", type=float, default=None,
                        help="对称性去重容差（Å），非晶结构通常不需要")
    parser.add_argument("--outdir", default="amorphous_structures",
                        help="输出根目录，默认 amorphous_structures")
    parser.add_argument("--max-attempts", type=int, default=5000,
                        help="单次 min-sep 约束最大重试次数，默认 5000")
    parser.add_argument("--overlap-hard", type=float, default=0.5,
                        help="硬截断系数（默认 0.5）：距离 < 系数×共价半径和时丢弃重试")
    parser.add_argument("--overlap-warn", type=float, default=0.75,
                        help="软警告系数（默认 0.75，须 > --overlap-hard）")
    return parser.parse_args()


def validate_args(args):
    """参数合理性检查，早于任何计算执行。"""
    errors = []
    if args.overlap_warn <= args.overlap_hard:
        errors.append(
            f"--overlap-warn ({args.overlap_warn}) 必须大于 "
            f"--overlap-hard ({args.overlap_hard})"
        )
    if args.rattle > 0.8:
        errors.append(
            f"--rattle={args.rattle} Å 过大（> 0.8 Å 会产生大量 overlap），"
            f"建议不超过 0.5 Å"
        )
    elif args.rattle > 0.5:
        print(
            f"[警告] --rattle={args.rattle} Å 较大（文档建议 ≤ 0.5 Å），"
            f"可能产生较多 overlap，请留意 overlap 拒绝率。",
            file=sys.stderr,
        )
    if args.nstruct < 1:
        errors.append(f"--nstruct 须 >= 1，当前值：{args.nstruct}")
    if args.max_attempts < 1:
        errors.append(f"--max-attempts 须 >= 1，当前值：{args.max_attempts}")
    # 提前校验浓度范围，避免在计算阶段才报错
    # mutually_exclusive_group(required=True) 保证两者恰好有一个非 None
    conc_list = args.scan_concentration if args.scan_concentration is not None \
                else [args.concentration]
    for c in conc_list:
        if not (0.0 < c <= 1.0):
            errors.append(f"浓度值 {c} 超出范围 (0, 1]，请检查 --concentration 或 --scan-concentration")
        elif c == 1.0:
            print(
                f"[警告] 浓度 {c} 将删除所有目标元素原子，"
                f"请确认这是期望的行为。",
                file=sys.stderr,
            )
    if errors:
        for e in errors:
            print(f"[参数错误] {e}", file=sys.stderr)
        sys.exit(1)


# ---------------------------------------------------------------------------
# 核心功能函数
# ---------------------------------------------------------------------------

def get_target_indices(atoms, symbol):
    """返回指定元素的原子索引列表。"""
    indices = [i for i, a in enumerate(atoms) if a.symbol == symbol]
    if not indices:
        raise ValueError(
            f"元素 '{symbol}' 在结构中不存在。"
            f"现有元素：{sorted(set(atoms.get_chemical_symbols()))}"
        )
    return indices


def compute_n_vac(n_target, conc):
    """根据浓度计算空位数量。"""
    if not (0.0 < conc <= 1.0):
        raise ValueError(f"浓度应在 (0, 1] 之间，当前值：{conc}")
    n = max(int(round(n_target * conc)), 1)
    if n > n_target:
        raise ValueError(
            f"空位数 {n} 超过目标元素总数 {n_target}，请降低浓度。"
        )
    return n


def check_min_sep(atoms, indices, min_sep):
    """检查选中空位位点两两距离是否满足最小间距（mic）。

    向量化实现：一次性提取所选位点坐标，用矩阵运算完成所有对的 MIC
    距离计算，避免 O(n_vac^2) 次标量 get_distance 调用。
    """
    indices = list(indices)   # 统一为列表：兼容任意可迭代输入，降级路径可安全下标访问
    if len(indices) < 2:
        return True
    pos = atoms.get_positions()[indices]          # (n, 3)
    cell = atoms.cell[:]                          # (3, 3)，行向量
    diff = pos[:, None, :] - pos[None, :, :]      # (n, n, 3) 笛卡尔差矢
    n = len(indices)
    diff_flat = diff.reshape(-1, 3)               # (n^2, 3)
    try:
        # 正确的笛卡尔→分数坐标：r_frac = r_cart @ inv(cell)
        # ASE 约定 cell 行向量：r_cart = r_frac @ cell
        # solve(cell.T, diff.T).T 等价于 diff @ inv(cell).T，对非正交晶胞结果错误
        inv_cell = np.linalg.inv(cell)
        frac_flat = diff_flat @ inv_cell          # (n^2, 3) 分数坐标
    except np.linalg.LinAlgError:
        # 奇异晶胞降级为逐对计算
        for i in range(n):
            for j in range(i + 1, n):
                if atoms.get_distance(indices[i], indices[j], mic=True) < min_sep:
                    return False
        return True
    frac_flat -= np.round(frac_flat)              # 最近镜像
    cart_flat = frac_flat @ cell                  # (n^2, 3)
    dist = np.linalg.norm(cart_flat.reshape(n, n, 3), axis=-1)  # (n, n)
    np.fill_diagonal(dist, np.inf)
    return float(dist.min()) >= min_sep


def choose_sites(atoms, indices_arr, n_vac, min_sep, rng, max_attempts):
    """从目标元素位点中随机选取 n_vac 个空位，可选 min-sep 约束。"""
    if n_vac > len(indices_arr):
        raise ValueError(
            f"请求空位数 ({n_vac}) 超过可用位点数 ({len(indices_arr)})。"
        )
    if min_sep is None:
        chosen = rng.choice(len(indices_arr), size=n_vac, replace=False)
        return sorted(int(indices_arr[i]) for i in chosen)

    for _ in range(max_attempts):
        chosen_idx = rng.choice(len(indices_arr), size=n_vac, replace=False)
        trial = sorted(int(indices_arr[i]) for i in chosen_idx)
        if check_min_sep(atoms, trial, min_sep):
            return trial

    raise RuntimeError(
        f"经过 {max_attempts} 次尝试，无法满足 --min-sep={min_sep:.2f} Å 约束。\n"
        f"  当前参数：n_vac={n_vac}，可用位点数={len(indices_arr)}\n"
        f"  建议：去掉 --min-sep，或减小 --concentration，或增大超胞。"
    )


def remove_atoms(atoms, indices):
    """删除指定索引的原子，返回新结构（不修改原对象）。
    使用掩码删除，复杂度 O(N)，优于逐个 del 的 O(N x n_vac)。
    indices 应为全局原子索引（int），由 choose_sites 保证。
    """
    idx = np.asarray(indices, dtype=int)   # 兼容 list/generator，明确整数类型
    if idx.size > 0 and (idx.min() < 0 or idx.max() >= len(atoms)):
        raise ValueError(
            f"remove_atoms: indices 超出范围 [0, {len(atoms)-1}]，"
            f"实际范围 [{int(idx.min())}, {int(idx.max())}]"
        )
    mask = np.ones(len(atoms), dtype=bool)
    mask[idx] = False
    return atoms[mask]


def rattle_atoms(atoms, amplitude, rng):
    """对所有原子施加均匀分布随机位移（笛卡尔坐标，Ang）。
    始终返回新对象，不修改传入的 atoms。

    位移从 Uniform(-amplitude, +amplitude) 采样，即每个方向上
    最大位移为 amplitude Ang（--rattle 参数的含义）。
    """
    atoms = atoms.copy()          # 防御性拷贝，消除对调用者的副作用
    if amplitude <= 0:
        return atoms
    disp = rng.uniform(-amplitude, amplitude, size=(len(atoms), 3))
    atoms.positions += disp
    return atoms


# ---------------------------------------------------------------------------
# Overlap 检查（基于 ASE 共价半径 + neighbor_list，材料无关）
# ---------------------------------------------------------------------------

def build_hard_warn_cutoffs(symbols, hard_factor, warn_factor):
    """
    预计算每对元素的硬截断和软警告距离。
    以 warn_factor（较大值）作为 neighbor_list 的搜索截止，
    再在邻居列表结果中按 hard_factor 分级，避免全量 O(N²) 扫描。

    返回：
        cutoffs_by_pair : dict {(sym_i, sym_j): (hard_dist, warn_dist)}
        max_warn_cutoff : float，所有元素对中最大的 warn 距离
    """
    unique = sorted(set(symbols))
    cutoffs = {}
    for i, s1 in enumerate(unique):
        for s2 in unique[i:]:
            r1 = covalent_radii[atomic_numbers[s1]]
            r2 = covalent_radii[atomic_numbers[s2]]
            if r1 <= 0 or r2 <= 0:
                print(
                    f"[警告] 元素 {s1} 或 {s2} 的共价半径未知（r={r1},{r2} Å），"
                    f"跳过该元素对的 overlap 检查。",
                    file=sys.stderr,
                )
                continue
            r_sum = r1 + r2
            key = (s1, s2)
            cutoffs[key] = (hard_factor * r_sum, warn_factor * r_sum)
    if not cutoffs:
        raise RuntimeError("所有元素对的共价半径均未知，无法构建 overlap 截断表。")
    max_warn = max(v[1] for v in cutoffs.values())
    return cutoffs, max_warn


def check_overlap(atoms, cutoffs_by_pair, max_warn_cutoff, max_violations=200):
    """
    用 ASE neighbor_list 高效检查 rattle 后的 overlap。
    比朴素 O(N²) 循环快一到两个数量级，适合大超胞。

    返回：
        status     : 'ok' | 'warn' | 'hard'
        violations : list of dict，记录违规原子对（最多 max_violations 条）
    """
    symbols = atoms.get_chemical_symbols()
    violations = []
    worst = 'ok'

    i_list, j_list, d_list = neighbor_list('ijd', atoms, max_warn_cutoff)

    for i, j, d in zip(i_list, j_list, d_list):
        if i >= j:      # 每对只检查一次
            continue
        s1, s2 = symbols[i], symbols[j]
        key = tuple(sorted([s1, s2]))
        pair_cutoffs = cutoffs_by_pair.get(key)
        if pair_cutoffs is None:
            # 理论上不应发生（cutoffs 由原始结构全元素集构建），
            # 若遇到则跳过，避免 KeyError 中断运行
            continue
        hard_d, warn_d = pair_cutoffs

        if d < hard_d:
            if len(violations) < max_violations:
                violations.append({
                    "atom_i": int(i), "sym_i": s1,
                    "atom_j": int(j), "sym_j": s2,
                    "distance": round(float(d), 4),
                    "hard_limit": round(hard_d, 4),
                    "level": "hard",
                })
            worst = 'hard'
            # 继续遍历以确保 worst 反映真实最坏情况；
            # violations 列表超过上限后停止追加，但不退出循环。
        elif d < warn_d:
            if len(violations) < max_violations:
                violations.append({
                    "atom_i": int(i), "sym_i": s1,
                    "atom_j": int(j), "sym_j": s2,
                    "distance": round(float(d), 4),
                    "warn_limit": round(warn_d, 4),
                    "level": "warn",
                })
            if worst != 'hard':
                worst = 'warn'

    return worst, violations


# ---------------------------------------------------------------------------
# 对称性去重（可选，需要 spglib）
# ---------------------------------------------------------------------------

def get_symmetry_fingerprint(atoms, symprec, spglib):
    """
    计算结构的对称性指纹，用于识别等价构型。

    指纹由 (空间群编号, 各 (元素符号, Wyckoff字母) 组合的计数元组) 构成，
    比仅排序 wyckoffs 列表更精确，能区分同 Wyckoff 字母但不同元素的位点。

    参数 spglib：已导入的 spglib 模块（由调用方在启动时导入一次并传入）。
    """
    cell = (atoms.cell[:], atoms.get_scaled_positions(), atoms.numbers)
    dataset = spglib.get_symmetry_dataset(cell, symprec=symprec)
    if dataset is None:
        return None
    # spglib < 2.0 返回 dict；spglib >= 2.0 返回 SpglibDataset 对象，支持属性访问
    # 统一用 getattr + dict fallback 兼容两种版本
    try:
        sg = dataset["number"]
        wyckoffs = dataset["wyckoffs"]
    except TypeError:
        sg = dataset.number
        wyckoffs = dataset.wyckoffs
    wk_count = tuple(sorted(
        Counter(zip(atoms.get_chemical_symbols(), wyckoffs)).items()
    ))
    return (sg, wk_count)


# ---------------------------------------------------------------------------
# 结构差异分析
# ---------------------------------------------------------------------------

def vacancy_jaccard(chosen_a, chosen_b):
    """
    计算两个空位集合的 Jaccard 距离（0 = 完全相同，1 = 完全不同）。
    反映空位位点选取的多样性，与原子位置无关。
    """
    set_a, set_b = set(chosen_a), set(chosen_b)
    union = len(set_a | set_b)
    if union == 0:
        # 防御性保护：compute_n_vac 已保证 n_vac >= 1，此分支理论上不可达。
        return 0.0
    return round(1.0 - len(set_a & set_b) / union, 4)


def mean_atomic_displacement(atoms_a, atoms_b):
    """
    计算两个结构间的平均原子位移 MAD（Ang，mic）。
    原子按索引一一对应（删除相同空位后顺序一致时有效）。
    反映 rattle 后原子位置的差异程度。

    若原子数不等或晶胞奇异（如真空层导致行列式极小），返回 None。
    """
    if len(atoms_a) != len(atoms_b):
        return None
    diff = atoms_b.get_positions() - atoms_a.get_positions()
    cell = atoms_a.cell[:]
    try:
        # 正确的笛卡尔→分数坐标：r_frac = r_cart @ inv(cell)
        frac = diff @ np.linalg.inv(cell)
    except np.linalg.LinAlgError:
        return None   # 奇异晶胞，无法计算 MIC，降级返回 None
    frac -= np.round(frac)
    cart = frac @ cell
    return round(float(np.mean(np.linalg.norm(cart, axis=1))), 4)


def compute_and_print_diversity(structures_info, atoms_list):
    """
    对同一浓度下所有生成结构做两两差异分析，打印矩阵并返回统计结果。

    Jaccard 距离：衡量空位位点的差异（0 = 完全相同，1 = 完全不同）
    MAD：衡量 rattle 后原子位置的差异（Å）

    结果同时写入 summary.json 的 diversity 字段。
    """
    n = len(structures_info)
    if n < 2:
        return None

    jac_mat = [[0.0] * n for _ in range(n)]
    mad_mat = [[0.0] * n for _ in range(n)]    # JSON 输出用，对角线和降级对均为 0.0
    mad_valid = [[False] * n for _ in range(n)]  # 标记哪些非对角对有有效 MAD 值

    for i in range(n):
        for j in range(i + 1, n):
            jac = vacancy_jaccard(
                structures_info[i]["removed_indices"],
                structures_info[j]["removed_indices"],
            )
            mad = mean_atomic_displacement(atoms_list[i], atoms_list[j])
            jac_mat[i][j] = jac_mat[j][i] = jac
            if mad is not None:
                mad_mat[i][j] = mad_mat[j][i] = mad
                mad_valid[i][j] = mad_valid[j][i] = True

    upper = [(i, j) for i in range(n) for j in range(i + 1, n)]
    jac_mean = round(sum(jac_mat[i][j] for i, j in upper) / len(upper), 4)
    # 只统计有效（mad_valid 为 True）的 MAD 对，避免降级的 0.0 稀释均值
    mad_vals = [mad_mat[i][j] for i, j in upper if mad_valid[i][j]]
    mad_mean = round(sum(mad_vals) / len(mad_vals), 4) if mad_vals else 0.0

    ids = [f"s{e['id']:03d}" for e in structures_info]
    w = 56
    print(f"\n  {'─'*w}")
    print(f"  结构差异分析（共 {n} 个结构）")
    print(f"  {'─'*w}")

    # Jaccard 矩阵
    print(f"  Jaccard 距离（空位位点差异，1 = 完全不同）：")
    header = "         " + "  ".join(f"{ids[j]:>6}" for j in range(n))
    print(f"  {header}")
    for i in range(n):
        row = "  ".join("  ----" if i == j else f"{jac_mat[i][j]:>6.3f}" for j in range(n))
        print(f"  {ids[i]:>6}   {row}")
    print(f"  均值: {jac_mean:.3f}", end="")
    if jac_mean < 0.3:
        print("  ⚠ 空位分布相似度较高，建议增加 --nstruct 或检查随机种子")
    else:
        print("  ✓ 空位分布多样，结构独立性良好")

    # MAD 矩阵（mad_valid[i][j]=False 表示降级无效，显示为 N/A）
    print(f"\n  平均原子位移 MAD（Å，反映 rattle 后位置差异）：")
    print(f"  {header}")
    for i in range(n):
        row = "  ".join(
            "  ----" if i == j
            else ("   N/A" if not mad_valid[i][j] else f"{mad_mat[i][j]:>6.3f}")
            for j in range(n)
        )
        print(f"  {ids[i]:>6}   {row}")
    print(f"  均值: {mad_mean:.3f} Å", end="")
    if mad_mean < 0.1:
        print("  ⚠ 原子位置差异较小，结构可能过于相似")
    else:
        print("  ✓ 原子位置存在显著差异，可作为独立 AIMD 初始构型")
    print(f"  {'─'*w}\n")

    return {
        "jaccard_matrix": jac_mat,
        "mad_matrix": mad_mat,
        "jaccard_mean": jac_mean,
        "mad_mean": mad_mean,
    }


# ---------------------------------------------------------------------------
# 单浓度生成
# ---------------------------------------------------------------------------

def generate_one_concentration(atoms, target_indices_arr, conc, args,
                                cutoffs_by_pair, max_warn_cutoff,
                                master_rng, outdir,
                                spglib_mod=None):
    """在 outdir 下生成 args.nstruct 个结构，返回该浓度的 summary dict。"""
    n_target = len(target_indices_arr)
    n_vac = compute_n_vac(n_target, conc)  # ValueError 由 main() 统一捕获

    n_atoms_after = len(atoms) - n_vac
    actual_conc = n_vac / n_target * 100

    print(f"  目标元素数  : {n_target}")
    print(f"  空位数量    : {n_vac}  (实际浓度 {actual_conc:.1f}%)")
    print(f"  删除后原子数: {n_atoms_after}")

    outdir.mkdir(parents=True, exist_ok=True)

    summary = {
        "concentration": conc,
        "n_target": n_target,
        "n_vac": n_vac,
        "actual_concentration_pct": round(actual_conc, 2),
        "n_atoms_after": n_atoms_after,
        "overlap_hard_factor": args.overlap_hard,
        "overlap_warn_factor": args.overlap_warn,
        "structures": [],
    }

    seen_configs = set()
    seen_symkeys = set()
    generated = 0
    n_overlap_rejected = 0
    generated_atoms = []   # 保存已生成的 Atoms 对象，用于差异分析

    # 去重失败和 overlap 拒绝分开计数，避免互相消耗重试额度
    max_dedup_attempts   = args.nstruct * 100
    max_overlap_attempts = args.nstruct * 100
    max_total_attempts   = args.nstruct * 300   # 总上限，防止两类拒绝交替无界循环
    dedup_attempts   = 0
    overlap_attempts = 0
    total_attempts   = 0

    while generated < args.nstruct:
        if total_attempts >= max_total_attempts:
            print(f"  [警告] 总尝试次数达到上限 {max_total_attempts}（"
                  f"去重拒绝: {dedup_attempts}，overlap 拒绝: {overlap_attempts}），终止。")
            break
        total_attempts += 1
        if dedup_attempts >= max_dedup_attempts:
            print(f"  [警告] 去重尝试达到上限 {max_dedup_attempts}，"
                  f"空位组合可能已穷尽。")
            break
        if overlap_attempts >= max_overlap_attempts:
            print(f"  [警告] overlap 拒绝达到上限 {max_overlap_attempts}，"
                  f"建议减小 --rattle 或 --overlap-hard。")
            break

        seed = int(master_rng.integers(0, 10**9))
        rng = np.random.default_rng(seed)

        try:
            chosen = choose_sites(
                atoms, target_indices_arr, n_vac,
                args.min_sep, rng, args.max_attempts
            )
        except RuntimeError as e:
            # min-sep 约束无法满足：先将已生成部分的 summary 写入磁盘，再向上传播异常，
            # 避免输出目录里有 POSCAR 但无对应 summary.json 的不完整状态。
            summary["nstruct_generated"] = generated
            summary["n_overlap_rejected"] = n_overlap_rejected
            summary["error"] = str(e)
            with open(outdir / "summary.json", "w", encoding="utf-8") as _f:
                json.dump(summary, _f, indent=2, ensure_ascii=False)
            raise

        # 去重：相同空位组合
        config_key = tuple(chosen)
        if config_key in seen_configs:
            dedup_attempts += 1
            continue
        seen_configs.add(config_key)

        # 构造空位结构（只调用一次，rattle 之前）
        defect = remove_atoms(atoms, chosen)

        # 去重：对称等价（可选，基于 rattle 前的拓扑构型）
        if args.symprec is not None:
            sym_key = get_symmetry_fingerprint(defect, args.symprec, spglib_mod)
            if sym_key is not None and sym_key in seen_symkeys:
                dedup_attempts += 1
                continue
            if sym_key is not None:
                seen_symkeys.add(sym_key)

        # rattle（rattle_atoms 内部做拷贝，不修改 defect 原对象）
        defect = rattle_atoms(defect, args.rattle, rng)

        # Overlap 检查
        overlap_status, violations = check_overlap(
            defect, cutoffs_by_pair, max_warn_cutoff
        )
        if overlap_status == 'hard':
            n_overlap_rejected += 1
            overlap_attempts += 1
            # 硬拒时移出 seen_configs，允许相同空位组合换 rattle seed 重试
            seen_configs.discard(config_key)
            continue

        # 写入结构
        folder = outdir / f"struct_{generated:03d}"
        folder.mkdir(parents=True, exist_ok=True)
        write(folder / "POSCAR", defect, format="vasp", direct=True, vasp5=True)

        # 路径记录：统一相对于 outdir_root（outdir.parent），扫描/单一模式行为一致
        folder_str = str(folder.relative_to(outdir.parent))

        entry = {
            "id": generated,
            "folder": folder_str,
            "seed": seed,
            "removed_indices": chosen,
            "overlap_status": overlap_status,
        }
        if violations:
            entry["overlap_warnings"] = violations
            print(f"  [OK/⚠] struct_{generated:03d}  "
                  f"空位数: {len(chosen)}，软警告原子对: {len(violations)} 个")
        else:
            print(f"  [OK] struct_{generated:03d}  空位数: {len(chosen)}")

        summary["structures"].append(entry)
        generated_atoms.append(defect)
        generated += 1

    if n_overlap_rejected > 0:
        print(f"  [信息] 因硬截断 overlap 丢弃: {n_overlap_rejected} 次"
              f"（可减小 --rattle 或 --overlap-hard）")

    summary["nstruct_generated"] = generated
    summary["n_overlap_rejected"] = n_overlap_rejected

    # 差异分析（生成 ≥ 2 个结构时自动执行）
    if len(generated_atoms) >= 2:
        diversity = compute_and_print_diversity(summary["structures"], generated_atoms)
        if diversity:
            summary["diversity"] = diversity

    with open(outdir / "summary.json", "w", encoding="utf-8") as f:
        json.dump(summary, f, indent=2, ensure_ascii=False)

    return summary


# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------

def main():
    args = parse_args()
    validate_args(args)

    # 若启用对称性去重，提前导入 spglib，避免运行到去重逻辑才报错；
    # 保存模块引用，后续通过参数传入，避免在循环内重复 import。
    spglib_mod = None
    if args.symprec is not None:
        try:
            import spglib as spglib_mod
        except ImportError:
            sys.exit("[错误] 对称性去重需要 spglib：pip install spglib")

    # 读取并扩胞
    try:
        atoms = read(args.input)
    except Exception as e:
        sys.exit(f"[错误] 无法读取结构文件 '{args.input}'：{e}")

    try:
        target_indices = get_target_indices(atoms, args.target)
    except (ValueError, RuntimeError) as e:
        sys.exit(f"[错误] {e}")

    target_indices_arr = np.array(target_indices)

    # 确定浓度列表
    if args.scan_concentration is not None:
        concentrations = sorted(set(args.scan_concentration))
        scan_mode = True
    else:
        concentrations = [args.concentration]
        scan_mode = False

    # 预计算 overlap 距离矩阵（外层一次性，所有浓度共用）
    cutoffs_by_pair, max_warn_cutoff = build_hard_warn_cutoffs(
        atoms.get_chemical_symbols(),
        args.overlap_hard,
        args.overlap_warn,
    )

    # 打印总体信息
    print("=" * 56)
    print("gen_amorphous.py — 非晶初始结构生成器")
    print("=" * 56)
    print(f"输入文件      : {args.input}")
    print(f"总原子数      : {len(atoms)}")
    print(f"目标元素 ({args.target}) : {len(target_indices_arr)} 个")
    print(f"rattle 幅度   : {args.rattle} Å")
    print(f"每浓度结构数  : {args.nstruct}")
    print(f"overlap 硬截断: {args.overlap_hard} × r_cov")
    print(f"overlap 软警告: {args.overlap_warn} × r_cov")
    if args.min_sep is not None:
        print(f"空位最小间距  : {args.min_sep} Å")
    if scan_mode:
        print(f"扫描浓度      : {[f'{c*100:.1f}%' for c in concentrations]}")
    print()

    outdir_root = Path(args.outdir)
    outdir_root.mkdir(exist_ok=True)

    master_rng = np.random.default_rng(args.seed)

    if scan_mode:
        scan_summary = {
            "input": args.input,
            "target": args.target,
            "rattle": args.rattle,
            "overlap_hard_factor": args.overlap_hard,
            "overlap_warn_factor": args.overlap_warn,
            "global_seed": args.seed,
            "concentrations": [],
        }
    else:
        scan_summary = None

    try:
        for conc in concentrations:
            label = f"conc_{conc*100:.1f}%"
            print(f"{'─'*56}")
            print(f"浓度: {conc*100:.1f}%  →  {label}/")

            conc_outdir = outdir_root / label if scan_mode else outdir_root

            summary = generate_one_concentration(
                atoms, target_indices_arr, conc, args,
                cutoffs_by_pair, max_warn_cutoff,
                master_rng, conc_outdir,
                spglib_mod=spglib_mod,
            )

            if scan_mode:
                scan_summary["concentrations"].append({
                    "concentration": conc,
                    "label": label,
                    "n_target": summary["n_target"],
                    "n_vac": summary["n_vac"],
                    "actual_concentration_pct": summary["actual_concentration_pct"],
                    "n_atoms_after": summary["n_atoms_after"],
                    "nstruct_generated": summary["nstruct_generated"],
                    "n_overlap_rejected": summary["n_overlap_rejected"],
                })

    except (ValueError, RuntimeError) as e:
        sys.exit(f"[错误] {e}")

    if scan_mode:
        scan_summary_path = outdir_root / "scan_summary.json"
        with open(scan_summary_path, "w", encoding="utf-8") as f:
            json.dump(scan_summary, f, indent=2, ensure_ascii=False)

        print(f"\n{'='*56}")
        print("扫描完成，各浓度结果汇总：")
        print(f"  {'浓度':>8}  {'空位数':>6}  {'剩余原子':>8}  "
              f"{'生成结构':>8}  {'overlap拒绝':>10}")
        for entry in scan_summary["concentrations"]:
            print(f"  {entry['actual_concentration_pct']:>7.1f}%  "
                  f"{entry['n_vac']:>6d}  "
                  f"{entry['n_atoms_after']:>8d}  "
                  f"{entry['nstruct_generated']:>8d}  "
                  f"{entry['n_overlap_rejected']:>10d}")
        print(f"\n顶层汇总：{scan_summary_path}")
    else:
        print(f"\n完成，结构写入 '{args.outdir}/'")


if __name__ == "__main__":
    main()
