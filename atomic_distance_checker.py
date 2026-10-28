#!/usr/bin/env python3
"""
Check for atoms too close in a VASP POSCAR/CONTCAR.

Usage:
  python atomic_distance_checker.py                        # default cutoff 1.5 Å
  python atomic_distance_checker.py CONTCAR --cutoff 1.0
  python atomic_distance_checker.py --pair Mo-Se:2.4 --pair Se-Se:3.0
  python atomic_distance_checker.py --cutoff 1.5 --pair Mo-Se:2.4
"""

import numpy as np
import argparse
import sys
from itertools import product


def read_poscar(filename):
    with open(filename) as f:
        lines = f.readlines()
    scale = float(lines[1].strip())
    lattice = np.array([[float(x) for x in lines[i].split()] for i in range(2, 5)]) * scale
    elem_line = lines[5].split()
    try:
        # VASP4: no species line, line 6 holds the counts
        float(elem_line[0])
        counts = [int(x) for x in elem_line]
        elements = [f"X{i}" for i in range(len(counts))]
        coord_line = 6
    except ValueError:
        # VASP5/6: strip POTCAR suffixes such as Ti_pv or Ti_pv/<hash>
        elements = [e.split("/")[0].split("_")[0] for e in elem_line]
        counts = [int(x) for x in lines[6].split()]
        coord_line = 7
    if lines[coord_line].strip()[0].lower() == 's':  # Selective dynamics
        coord_line += 1
    coord_type = lines[coord_line].strip()[0].lower()
    coords, labels = [], []
    for elem, count in zip(elements, counts):
        for _ in range(count):
            coords.append([float(x) for x in lines[coord_line + 1 + len(coords)].split()[:3]])
            labels.append(elem)
    coords = np.array(coords)
    if coord_type in ('c', 'k'):   # Cartesian coordinates are scaled too
        coords = coords * scale
    else:                          # Direct
        coords = coords @ lattice
    return lattice, coords, labels


# the 27 neighbouring cell translations (fractional)
SHIFTS = np.array(list(product((-1, 0, 1), repeat=3)), dtype=float)


def min_image_dists(frac, i, lattice):
    """True minimum-image distances from atom i to atoms i+1..N-1.

    Fractional differences are first reduced to [-0.5, 0.5); the shortest of the
    27 neighbouring images is then taken, which is also correct for oblique
    (hexagonal, monoclinic) cells where rounding alone overestimates distances.
    """
    diff = frac[i + 1:] - frac[i]
    diff -= np.round(diff)
    cart = (diff[:, None, :] + SHIFTS[None, :, :]) @ lattice   # (n, 27, 3)
    return np.sqrt((cart ** 2).sum(axis=-1)).min(axis=1)


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
    frac = coords @ np.linalg.inv(lattice)
    for i in range(len(coords) - 1):
        dists = min_image_dists(frac, i, lattice)
        for k in np.nonzero(dists < max([args.cutoff] + list(pair_cutoffs.values())))[0]:
            j = i + 1 + int(k)
            d = float(dists[k])
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
