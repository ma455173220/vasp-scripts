#!/usr/bin/env python3
"""
vasp_echeck.py  —  VASP Energy Checker
=======================================
用途
----
扫描当前目录下所有一级子文件夹中的 VASP 计算，
  1. 检测任务是否成功收敛（读 OUTCAR）
  2. 提取最终能量 E0（读 OSZICAR）
  3. 按总能量排序，输出人类可读的 .log 和机器可读的 .csv

使用方式
--------
  1. 将本脚本放在「包含各结构子文件夹的父目录」下，例如：

       relaxation/
       ├── vasp_echeck.py      ← 脚本放这里
       ├── struct_A/
       │   ├── INCAR
       │   ├── OUTCAR
       │   ├── OSZICAR
       │   └── ...
       ├── struct_B/
       └── struct_C/

  2. 进入该父目录后运行：

       python3 vasp_echeck.py

  3. 脚本会在当前目录生成：
       vasp_energy_scan.log   —— 对齐格式，终端友好，便于快速浏览

注意事项
--------
- 仅扫描一级子文件夹（不递归），适合「一个文件夹 = 一个结构」的布局
- 收敛判据：OUTCAR 含 "reached required accuracy"
- 能量来源：OSZICAR 最后一行 E0（已去 entropy 外推值，适合结构比较）
- 若子文件夹缺少 OUTCAR / OSZICAR，会归入「失败」列表并注明原因
"""

import os
import re
import glob
from datetime import datetime


def check_vasp_success(folder):
    """检查 VASP 是否成功完成（OUTCAR 中含 'reached required accuracy'）"""
    outcar = os.path.join(folder, "OUTCAR")
    if not os.path.isfile(outcar):
        return False, "OUTCAR missing"
    with open(outcar, "r", errors="replace") as f:
        content = f.read()
    if "reached required accuracy" in content:
        return True, "OK"
    if "General timing and accounting" in content:
        return False, "finished but NOT converged"
    return False, "incomplete / still running"


def get_final_energy(folder):
    """从 OSZICAR 提取最后一个离子步的能量 E0"""
    oszicar = os.path.join(folder, "OSZICAR")
    if not os.path.isfile(oszicar):
        return None, "OSZICAR missing"
    energy = None
    pattern = re.compile(r"E0=\s*([-\d.E+]+)")
    with open(oszicar, "r", errors="replace") as f:
        for line in f:
            m = pattern.search(line)
            if m:
                energy = float(m.group(1))
    if energy is None:
        return None, "E0 not found in OSZICAR"
    return energy, "OK"


def get_natoms(folder):
    """从 OUTCAR 读取原子数"""
    outcar = os.path.join(folder, "OUTCAR")
    if not os.path.isfile(outcar):
        return None
    with open(outcar, "r", errors="replace") as f:
        for line in f:
            if "NIONS" in line:
                m = re.search(r"NIONS\s*=\s*(\d+)", line)
                if m:
                    return int(m.group(1))
    return None


def main():
    cwd = os.getcwd()
    logfile = os.path.join(cwd, "vasp_energy_scan.log")

    folders = sorted([
        d for d in glob.glob(os.path.join(cwd, "*/"))
        if os.path.isdir(d)
    ])

    if not folders:
        print("未找到子文件夹，退出。")
        return

    results_ok   = []   # (energy, energy_per_atom, natoms, name)
    results_fail = []   # (name, reason)

    for folder in folders:
        name = os.path.relpath(folder, cwd)
        success, reason = check_vasp_success(folder)
        if not success:
            results_fail.append((name, reason))
            continue

        energy, ereason = get_final_energy(folder)
        if energy is None:
            results_fail.append((name, f"converged but {ereason}"))
            continue

        natoms = get_natoms(folder)
        epa = energy / natoms if natoms else None
        results_ok.append((energy, epa, natoms, name))

    results_ok.sort(key=lambda x: x[0])

    # ── 写 LOG ──────────────────────────────────────────────────
    lines = []
    lines.append("=" * 72)
    lines.append(f"  VASP Energy Scan  —  {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    lines.append(f"  Root: {cwd}")
    lines.append("=" * 72)
    lines.append(f"\n{'Rank':<5} {'Folder':<30} {'E_total (eV)':>14} {'E/atom (eV)':>12} "
                 f"{'Natoms':>7} {'ΔE (meV/atom)':>14}")
    lines.append("-" * 85)

    for rank, (energy, epa, natoms, name) in enumerate(results_ok, 1):
        if epa is not None and results_ok[0][1] is not None:
            delta = (epa - results_ok[0][1]) * 1000
            delta_str = f"{delta:+.1f}"
        else:
            delta_str = "N/A"
        epa_str    = f"{epa:.6f}"  if epa    is not None else "N/A"
        natoms_str = f"{natoms}"   if natoms  is not None else "N/A"
        marker = "  ★" if rank == 1 else ""
        lines.append(f"{rank:<5} {name:<30} {energy:>14.6f} {epa_str:>12} "
                     f"{natoms_str:>7} {delta_str:>14}{marker}")

    if results_fail:
        lines.append(f"\nFailed / Incomplete")
        lines.append("-" * 50)
        for name, reason in results_fail:
            lines.append(f"  ✗  {name:<30}  [{reason}]")

    lines.append("\n" + "=" * 72)
    lines.append(f"  成功: {len(results_ok)}   失败/未完成: {len(results_fail)}")
    lines.append("=" * 72)

    output = "\n".join(lines)
    print(output)
    with open(logfile, "w") as f:
        f.write(output + "\n")
    print(f"\n→ 已写入 {logfile}")


if __name__ == "__main__":
    main()
