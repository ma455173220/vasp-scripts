#!/usr/bin/env python3
"""
fatband_batch.py — 通用 fatband 批量绘图脚本 (pyprocar 6.x)

用途：对任意体系，按 元素 × 轨道壳层(s/p/d[/f]) 批量生成 fatband 图，
      用于 Wannier 投影集的选取（对照能量窗口内哪些成分权重大）。

════════════════════════════════════════════════════════════════════
一、快速上手（三步）
════════════════════════════════════════════════════════════════════
1. 准备一个【非 SOC】的能带路径非自洽计算目录，INCAR 至少含：
       LORBIT = 11        # 必须，否则 PROCAR 没有轨道分辨投影
       ICHARG = 11        # 读入自洽 CHGCAR 做非自洽
       ISMEAR = 0; SIGMA = 0.05
   KPOINTS 用 line-mode（高对称路径），跑完确认目录里有
   PROCAR / OUTCAR / POSCAR / KPOINTS 四个文件。

2. 运行（无需任何改动，原子索引和 E_F 全自动）：
       python fatband_batch.py -d /path/to/band_dir

3. 看图：所有 fatband_<元素>_<壳层>.png 用同一色标 (0-0.5)，
   直接比较颜色深浅 => 费米面附近哪些面板颜色深，
   Wannier 投影集就选哪些 元素:壳层。

════════════════════════════════════════════════════════════════════
二、命令行参数速查
════════════════════════════════════════════════════════════════════
  -d, --dirname DIR     VASP 计算目录（默认 . ）
  -e, --elimit LO HI    能量窗口，相对 E_F（默认 -15 12；
                        选投影集时建议收窄，如 -e -6 6）
  --clim LO HI          色标范围（默认 0 0.5；改了就全体面板一起改，
                        否则面板间颜色不可比）
  --cmap NAME           matplotlib colormap（默认 hot_r）
  --species A B ...     只画这些元素（默认 POSCAR 里全部元素）
  --shells s p d f      只画这些壳层（默认 s p d）
  --with-f              在 --shells 基础上附加 f 壳层
  --fermi X             手动指定 E_F，覆盖自动读取
                        （何时需要：OUTCAR 是别的 run 的 / 数值可疑时）
  -o, --outdir DIR      图片输出目录（默认当前目录）

常用组合示例：
  python fatband_batch.py                              # 全默认
  python fatband_batch.py -e -6 6                      # 聚焦费米面
  python fatband_batch.py --species Ba Cu --shells s d # BaCu 关键壳层
  python fatband_batch.py -d band/ -o figs/ --cmap viridis

════════════════════════════════════════════════════════════════════
三、想改脚本时改哪儿（按场景）
════════════════════════════════════════════════════════════════════
▶ 场景 1：只看单个轨道分量（如只看 pz —— 层状材料常用）
  在下方 SHELLS 字典里加一行即可，之后 --shells pz 就能用：
      "pz": [2],
      "dz2": [6],
  轨道索引对照 (VASP LORBIT=11)：
      s=0 | py=1 pz=2 px=3 | dxy=4 dyz=5 dz2=6 dxz=7 dx2-y2=8 | f=9..15

▶ 场景 2：把几个元素合并成一个面板（如所有卤素一起）
  最省事的做法：在 main() 里 targets 循环前手动合并，例如
      targets = {"X(Br+I)": species["Br"] + species["I"]}

▶ 场景 3：只画某几个原子而不是整个元素（如只看表面层的 Se）
  parse_poscar_species 返回的索引是 0-based、按 POSCAR 行序。
  直接构造 targets = {"Se_surf": [12, 13]} 替换自动结果。
  （原子序号 = POSCAR 坐标行的行号顺序，从 0 数）

▶ 场景 4：改输出格式 / 分辨率
  savefig=str(fname) 里把 .png 换 .pdf 即得矢量图；
  想调 dpi，给 bandsplot 传 dpi=300（pyprocar 会转给 matplotlib）。

▶ 场景 5：pyprocar 版本不是 6.x
  5.x 的接口不同（procar='PROCAR', outcar='OUTCAR' 逐个传文件，
  且 fermi/elimit 参数名有出入）。先 print(pyprocar.__version__)，
  再 help(pyprocar.bandsplot) 对照改本文件末尾 bandsplot(...) 一处即可，
  其余逻辑（解析 POSCAR/OUTCAR、循环）与版本无关。

════════════════════════════════════════════════════════════════════
四、常见报错 / 异常图像对照
════════════════════════════════════════════════════════════════════
  "缺少 PROCAR"            -> 用的不是能带那次计算的目录，或没开 LORBIT=11
  图是一团乱麻不是路径      -> PROCAR 来自自洽均匀网格，不是 line-mode
  所有面板全白             -> LORBIT 没设 11；或 SOC PROCAR 被读错块
  能带整体偏移             -> E_F 来源不对，用 --fermi 手动给自洽 OUTCAR 的值
  颜色虚线状闪烁           -> SOC + 反演对称的 Kramers 换岗（脚本会警告），
                             选投影集请改用非 SOC 计算
  某些 E_F 附近的带哪个面板都浅 -> 电子化物的间隙态指纹（PROCAR 只统计
                             PAW 球内权重），提示需要 interstitial 投影

自动化内容：
  - 从 POSCAR 解析元素种类和原子序号（无需手填 atoms 索引）
  - 从 OUTCAR 读取 E-fermi
  - 检测 SOC (LSORBIT/LNONCOLLINEAR)，若开启则给出警告
"""

import argparse
import re
import sys
from pathlib import Path
import os
os.environ.setdefault("OMP_NUM_THREADS", "1")
os.environ.setdefault("OPENBLAS_NUM_THREADS", "1")
os.environ.setdefault("MKL_NUM_THREADS", "1")
os.environ.setdefault("NUMEXPR_NUM_THREADS", "1")

# ── 改这里(场景1)：增删轨道分组，key 会自动成为 --shells 的合法选项 ──
# 轨道索引约定 (VASP LORBIT=11)：
# s=0; p: py=1, pz=2, px=3; d: dxy=4, dyz=5, dz2=6, dxz=7, dx2-y2=8; f: 9..15
SHELLS = {
    "s": [0],
    "p": [1, 2, 3],
    "d": [4, 5, 6, 7, 8],
    "f": [9, 10, 11, 12, 13, 14, 15],
}


def parse_poscar_species(poscar: Path):
    """返回 {元素: [原子索引(0-based)]}，按 POSCAR 顺序。"""
    lines = poscar.read_text().splitlines()
    symbols = lines[5].split()
    if any(s.isdigit() for s in symbols):
        sys.exit("POSCAR 第 6 行不是元素名（VASP4 格式？）。请用 VASP5+ 格式的 POSCAR。")
    counts = [int(x) for x in lines[6].split()]
    species, i = {}, 0
    for sym, n in zip(symbols, counts):
        species.setdefault(sym, []).extend(range(i, i + n))
        i += n
    return species


def parse_outcar(outcar: Path):
    """返回 (E_fermi, soc_on)。E_fermi 取最后一次出现的值。"""
    efermi, soc = None, False
    txt = outcar.read_text(errors="ignore")
    m = re.findall(r"E-fermi\s*:\s*([-\d.]+)", txt)
    if m:
        efermi = float(m[-1])
    if re.search(r"LSORBIT\s*=\s*T", txt) or re.search(r"LNONCOLLINEAR\s*=\s*T", txt):
        soc = True
    return efermi, soc


def main():
    ap = argparse.ArgumentParser(description="按 元素×壳层 批量画 fatband (pyprocar)")
    ap.add_argument("-d", "--dirname", default=".", help="VASP 计算目录 (默认当前)")
    ap.add_argument("-e", "--elimit", nargs=2, type=float, default=[-15, 12],
                    metavar=("EMIN", "EMAX"), help="能量窗口，相对 E_F (默认 -15 12)")
    ap.add_argument("--clim", nargs=2, type=float, default=[0, 0.5],
                    help="色标范围，固定后各面板间才可比 (默认 0 0.5)")
    ap.add_argument("--cmap", default="hot_r", help="colormap (默认 hot_r)")
    ap.add_argument("--species", nargs="+", default=None, help="只画这些元素 (默认全部)")
    ap.add_argument("--shells", nargs="+", default=["s", "p", "d"],
                    choices=list(SHELLS), help="要画的壳层 (默认 s p d)")
    ap.add_argument("--with-f", action="store_true", help="附加 f 壳层")
    ap.add_argument("--fermi", type=float, default=None,
                    help="手动指定 E_F（默认自动读 OUTCAR）")
    ap.add_argument("-o", "--outdir", default=".", help="图片输出目录 (默认当前)")
    args = ap.parse_args()

    import matplotlib
    matplotlib.use("Agg")  # 无头模式：集群上不弹窗，直接存文件
    import pyprocar

    d = Path(args.dirname)
    for f in ("PROCAR", "OUTCAR", "POSCAR", "KPOINTS"):
        if not (d / f).exists():
            sys.exit(f"缺少 {d/f} —— 需要能带路径非自洽计算目录 (LORBIT=11)。")

    species = parse_poscar_species(d / "POSCAR")
    efermi_auto, soc = parse_outcar(d / "OUTCAR")
    efermi = args.fermi if args.fermi is not None else efermi_auto
    if efermi is None:
        sys.exit("OUTCAR 中未找到 E-fermi，请用 --fermi 手动指定。")

    if soc:
        print("=" * 72)
        print("警告：检测到 SOC 计算 (LSORBIT/LNONCOLLINEAR = T)。")
        print("  若体系同时具有反演对称，能带处处二重简并 (Kramers 对)，")
        print("  投影权重在简并伙伴间随 k 任意分配 => fatband 呈虚线状闪烁。")
        print("  【选 Wannier 投影集请改用非 SOC 能带计算】：轨道成分的定性")
        print("  判断不依赖 SOC；SOC 只在 Wannier 化时以 spinor (x2) 体现。")
        print("=" * 72)

    shells = list(args.shells) + (["f"] if args.with_f else [])
    targets = {s: idx for s, idx in species.items()
               if args.species is None or s in args.species}
    # ── 改这里(场景2/3)：需要合并元素或只取部分原子时，直接覆盖 targets ──
    # 例:  targets = {"X(Br+I)": species["Br"] + species["I"]}
    # 例:  targets = {"Se_surf": [12, 13]}   # 0-based，按 POSCAR 行序
    if not targets:
        sys.exit(f"--species 过滤后没有元素。POSCAR 中含: {list(species)}")

    outdir = Path(args.outdir)
    outdir.mkdir(parents=True, exist_ok=True)
    print(f"E_F = {efermi:.6f} eV | 元素: "
          + ", ".join(f"{s}(原子 {i[0]}..{i[-1]})" for s, i in targets.items()))

    for sym, atoms in targets.items():
        for shell in shells:
            fname = outdir / f"fatband_{sym}_{shell}.png"
            print(f"  绘制 {sym}-{shell:>1} -> {fname}")
            pyprocar.bandsplot(
                code="vasp", dirname=str(d), mode="parametric",
                atoms=atoms, orbitals=SHELLS[shell],
                fermi=efermi, elimit=list(args.elimit),
                cmap=args.cmap, clim=list(args.clim),
                show=False, savefig=str(fname),
            )
    print("完成。固定 clim 后各面板可直接互相比较颜色深浅。")


if __name__ == "__main__":
    main()
