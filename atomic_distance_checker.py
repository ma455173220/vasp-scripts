#!/usr/bin/env python3
"""
Check for atoms too close in a VASP POSCAR/CONTCAR.

Usage:
  python check_close_atoms.py                        # default cutoff 1.5 Å
  python check_close_atoms.py CONTCAR --cutoff 1.0
  python check_close_atoms.py --pair Mo-Se:2.4 --pair Se-Se:3.0
  python check_close_atoms.py --cutoff 1.5 --pair Mo-Se:2.4
"""

import numpy as np
import argparse
import sys
from itertools import combinations


def read_poscar(filename):
    with open(filename) as f:
        lines = f.readlines()
    scale = float(lines[1].strip())
    lattice = np.array([[float(x) for x in lines[i].split()] for i in range(2, 5)]) * scale
    elem_line = lines[5].split()
    try:
        float(elem_line[0])
        counts = [int(x) for x in elem_line]
        elements = [f"X{i}" for i in range(len(counts))]
        coord_line = 6
    except ValueError:
        elements = elem_line
        counts = [int(x) for x in lines[6].split()]
        coord_line = 7
    coord_type = lines[coord_line].strip()[0].lower()
    coords, labels = [], []
    for elem, count in zip(elements, counts):
        for _ in range(count):
            coords.append([float(x) for x in lines[coord_line + 1 + len(coords)].split()[:3]])
            labels.append(elem)
    coords = np.array(coords)
    if coord_type == 'd':
        coords = coords @ lattice
    return lattice, coords, labels


def min_image_dist(r1, r2, lattice):
    diff = (r1 - r2) @ np.linalg.inv(lattice)
    diff -= np.round(diff)
    return np.linalg.norm(diff @ lattice)


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
    lattice, coords, labels = read_poscar(args.poscar)

    errors = []
    for i, j in combinations(range(len(coords)), 2):
        d = min_image_dist(coords[i], coords[j], lattice)
        cut = pair_cutoffs.get(frozenset({labels[i], labels[j]}), args.cutoff)
        if d < cut:
            errors.append((i, j, d, labels[i], labels[j], cut))

    print(f"File: {args.poscar}  |  {len(coords)} atoms")
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
