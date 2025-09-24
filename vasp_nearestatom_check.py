from ase.io import read
import numpy as np

# Read POSCAR
atoms = read("POSCAR")

# Set a distance threshold, e.g., the minimum allowed distance between atoms (in Å)
threshold = 0.8  # Example value, adjust according to the system

# Get all atomic positions (including periodic images)
positions = atoms.get_positions()
cell = atoms.get_cell()
pbc = atoms.get_pbc()

# ASE provides get_neighbors or NeighborList utilities
from ase.neighborlist import NeighborList

# Set cutoff distance for each atom, e.g., threshold
cutoffs = [threshold/2] * len(atoms)  # or assign different values for each atom

nl = NeighborList(cutoffs, self_interaction=False, bothways=True)
nl.update(atoms)

bad_pairs = []
for i in range(len(atoms)):
    indices, offsets = nl.get_neighbors(i)
    for j, off in zip(indices, offsets):
        # Calculate actual distance (considering periodic boundary conditions)
        pos_i = positions[i]
        pos_j = positions[j] + np.dot(off, cell)
        dist = np.linalg.norm(pos_i - pos_j)
        if dist < threshold:
            # Exclude self or duplicate pairs
            if j > i:
                bad_pairs.append((i, j, dist))

if bad_pairs:
    print("Found suspiciously close atom pairs:")
    for (i, j, d) in bad_pairs:
        print(f" Atom {i} ({atoms[i].symbol}) and Atom {j} ({atoms[j].symbol}): {d:.3f} Å")
else:
    print("No atom pairs closer than threshold found.")
