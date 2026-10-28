#!/usr/bin/env python3
"""
Center of mass of a POSCAR in fractional coordinates (used to set DIPOL).

Usage: center-of-mass.py [POSCAR]

Periodic-safe (vasp_common.periodic_com): along each lattice vector the atoms are
unwrapped by cutting the cell at the largest empty interval (for a slab this is the
vacuum gap along the IDIPOL axis), then the mass-weighted mean is taken and wrapped
back into [0, 1). For a slab that crosses the cell boundary this gives the slab
centre instead of a point in the vacuum. For an axis without a gap (bulk direction)
the result is the centre of the contiguous block, which is the same as the plain
mean when nothing crosses the boundary.

POSCAR is read by vasp_common.read_poscar, so VASP 6.4 species such as
"Ti_pv/<hash>" work with any ASE version (ASE is only used for the atomic masses).
"""
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
from vasp_common import periodic_com, read_poscar  # noqa: E402

import numpy as np  # noqa: E402
from ase.data import atomic_masses, atomic_numbers  # noqa: E402

poscar = sys.argv[1] if len(sys.argv) > 1 else "POSCAR"
p = read_poscar(poscar)
if p.species is None:  # VASP4: no species line, let ASE find the symbols
    from ase.io import read
    atoms = read(poscar, format="vasp")
    frac, masses = atoms.get_scaled_positions(wrap=False), atoms.get_masses()
else:
    frac = p.frac
    masses = np.array([atomic_masses[atomic_numbers[s]] for s in p.symbols])
com = periodic_com(frac, masses)
print("Center of mass (fractional):", com)
