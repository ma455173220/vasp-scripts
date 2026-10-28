#!/usr/bin/env python3
"""
Check for atoms too close in a VASP POSCAR/CONTCAR.

Usage:
  python atomic_distance_checker.py                        # default cutoff 1.5 Å
  python atomic_distance_checker.py CONTCAR --cutoff 1.0
  python atomic_distance_checker.py --pair Mo-Se:2.4 --pair Se-Se:3.0
  python atomic_distance_checker.py --cutoff 1.5 --pair Mo-Se:2.4
"""

import argparse
import os
import shutil
import sys

_w = shutil.which("vasp_common.py")
for _d in [os.path.dirname(os.path.realpath(__file__))] + ([os.path.dirname(os.path.realpath(_w))] if _w else []):
    if os.path.isfile(os.path.join(_d, "vasp_common.py")):
        sys.path.insert(0, _d)
        break
else:
    sys.exit("ERROR: vasp_common.py not found (next to this script or on PATH)")
from vasp_common import neighbor_pairs, read_poscar  # noqa: E402


def parse_pairs(pair_args):
    cutoffs = {}
    for p in (pair_args or []):
        try:
            pair, val = p.rsplit(":", 1)
            a, b = pair.split("-")
            cutoffs[frozenset({a.strip(), b.strip()})] = float(val)
        except Exception:
            print(f"Warning: cannot parse --pair '{p}', expected A-B:dist")
    return cutoffs


def main():
    parser = argparse.ArgumentParser(description="Check close atoms in VASP POSCAR/CONTCAR",
                                     formatter_class=argparse.RawDescriptionHelpFormatter,
                                     epilog=__doc__)
    parser.add_argument("poscar", nargs="?", default="POSCAR")
    parser.add_argument("--cutoff", type=float, default=1.5, help="Global error cutoff in Å (default: 1.5)")
    parser.add_argument("--pair", action="append", metavar="A-B:dist",
                        help="Per-pair cutoff, e.g. --pair Mo-Se:2.4")
    args = parser.parse_args()

    pair_cutoffs = parse_pairs(args.pair)
    p = read_poscar(args.poscar)   # VASP 4/5/6 ("Ti_pv/<hash>"), selective dynamics, Cartesian
    if p.species is None:          # VASP4: no species line
        labels = [f"X{t}" for t, n in enumerate(p.counts) for _ in range(n)]
    else:
        labels = p.symbols
    natoms = p.natoms

    errors = []
    # true minimum image (27 neighbouring cells), vectorised per atom
    for i, j, d in neighbor_pairs(p.frac, p.lattice, max([args.cutoff] + list(pair_cutoffs.values()))):
        cut = pair_cutoffs.get(frozenset({labels[i], labels[j]}), args.cutoff)
        if d < cut:
            errors.append((i, j, d, labels[i], labels[j], cut))

    print(f"File: {args.poscar}  |  {natoms} atoms")
    if pair_cutoffs:
        for k, v in pair_cutoffs.items():
            a, b = sorted(k)
            print(f"  cutoff {a}-{b}: {v} Å")
    else:
        print(f"  cutoff: {args.cutoff} Å")
    print()

    if errors:
        print(f"❌ {len(errors)} pair(s) too close:\n")
        for i, j, d, li, lj, cut in sorted(errors, key=lambda x: x[2]):
            print(f"  Atom {i+1:4d}({li}) — Atom {j+1:4d}({lj})  :  {d:.4f} Å  [< {cut} Å]")
        sys.exit(1)
    else:
        print("✅ All good — no atom pairs below cutoff.")
        sys.exit(0)


if __name__ == "__main__":
    main()
