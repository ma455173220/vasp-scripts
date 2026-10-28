#!/usr/bin/env python3
from ase.io import read
slab = read("POSCAR")
com = slab.get_center_of_mass(scaled=True)
print("Center of mass (fractional):", com)
