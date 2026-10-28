#!/usr/bin/env python3
"""
Center of mass of a POSCAR in fractional coordinates (used to set DIPOL).

Usage: center-of-mass.py [POSCAR]

Periodic-safe: along each lattice vector the atoms are first unwrapped by
cutting the cell at the largest empty interval (for a slab this is the
vacuum gap along the IDIPOL axis), then the mass-weighted mean is taken and
wrapped back into [0, 1). For a slab that crosses the cell boundary this
gives the slab centre instead of a point in the vacuum. For an axis without
a gap (bulk direction) the result is the centre of the contiguous block,
which is the same as the plain mean when nothing crosses the boundary.

POSCAR is read directly, so VASP 6.4 species such as "Ti_pv/<hash>" work
with any ASE version (ASE is only used for the atomic masses).
"""
import sys

import numpy as np
from ase.data import atomic_masses, atomic_numbers


def read_poscar(path):
    lines = open(path).read().splitlines()
    scale = float(lines[1].split()[0])
    cell = np.array([[float(x) for x in lines[i].split()[:3]] for i in (2, 3, 4)])
    if scale < 0:  # negative scale = target volume
        scale = (-scale / abs(np.linalg.det(cell))) ** (1.0 / 3.0)
    cell *= scale
    tokens = lines[5].split()
    if all(t.isdigit() for t in tokens):  # VASP4: no species line
        from ase.io import read
        atoms = read(path, format="vasp")
        return atoms.get_scaled_positions(wrap=False), atoms.get_masses()
    species = [t.split("/")[0].split("_")[0] for t in tokens]
    counts = [int(x) for x in lines[6].split()]
    k = 7
    if lines[k].strip()[:1] in "sS":  # Selective dynamics
        k += 1
    cartesian = lines[k].strip()[:1] in "cCkK"
    nat = sum(counts)
    pos = np.array([[float(x) for x in lines[k + 1 + i].split()[:3]] for i in range(nat)])
    if cartesian:
        pos = (pos * scale) @ np.linalg.inv(cell)
    masses = np.concatenate([[atomic_masses[atomic_numbers[s]]] * n for s, n in zip(species, counts)])
    return pos, masses


def periodic_center(frac, masses):
    com = np.zeros(3)
    for ax in range(3):
        s = np.sort(frac[:, ax] % 1.0)
        gaps = np.diff(np.append(s, s[0] + 1.0))  # last entry: gap across the boundary
        i = int(np.argmax(gaps))
        if gaps[-1] >= gaps[i] - 1e-6:            # tie: keep the cell boundary (= plain mean)
            i = len(gaps) - 1
        cut = (s[i] + gaps[i] / 2.0) % 1.0        # middle of the largest empty interval
        unwrapped = (frac[:, ax] - cut) % 1.0 + cut
        com[ax] = (np.sum(masses * unwrapped) / np.sum(masses)) % 1.0
    return com


poscar = sys.argv[1] if len(sys.argv) > 1 else "POSCAR"
frac, masses = read_poscar(poscar)
com = periodic_center(frac, masses)
print("Center of mass (fractional):", com)
