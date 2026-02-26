#!/usr/bin/env python3
"""
qe2poscar.py - Convert Quantum ESPRESSO relax/vc-relax output to VASP POSCAR

Usage:
    python qe2poscar.py <vc-relax.out> [POSCAR]

If output filename is not specified, defaults to POSCAR.
Extracts the final relaxed structure (last CELL_PARAMETERS + ATOMIC_POSITIONS).
Supports both angstrom and bohr units.
"""

import sys
import re
from collections import OrderedDict
import numpy as np

BOHR_TO_ANG = 0.529177210903


def parse_qe_output(filename):
    with open(filename, 'r') as f:
        lines = f.readlines()

    # Find the "Begin final coordinates" block if it exists (vc-relax)
    # Otherwise fall back to the last CELL_PARAMETERS / ATOMIC_POSITIONS block
    begin_idx = None
    for i, line in enumerate(lines):
        if 'Begin final coordinates' in line:
            begin_idx = i
            break

    # Collect all CELL_PARAMETERS blocks
    cell_blocks = []
    for i, line in enumerate(lines):
        if re.match(r'\s*CELL_PARAMETERS', line):
            cell_blocks.append(i)

    # Collect all ATOMIC_POSITIONS blocks
    pos_blocks = []
    for i, line in enumerate(lines):
        if re.match(r'\s*ATOMIC_POSITIONS', line):
            pos_blocks.append(i)

    if not pos_blocks:
        raise ValueError("No ATOMIC_POSITIONS found in the output file.")

    # Choose the last block (or the one inside "Begin final coordinates")
    if begin_idx is not None:
        # Pick the CELL_PARAMETERS and ATOMIC_POSITIONS after begin_idx
        cell_idx = next((i for i in cell_blocks if i > begin_idx), cell_blocks[-1] if cell_blocks else None)
        pos_idx  = next((i for i in pos_blocks  if i > begin_idx), pos_blocks[-1])
    else:
        cell_idx = cell_blocks[-1] if cell_blocks else None
        pos_idx  = pos_blocks[-1]

    # ----------------------------------------------------------------
    # Parse CELL_PARAMETERS
    # ----------------------------------------------------------------
    if cell_idx is not None:
        cell_line = lines[cell_idx].strip()
        # Determine unit
        unit_match = re.search(r'\((\w+)\)', cell_line)
        cell_unit = unit_match.group(1).lower() if unit_match else 'bohr'

        lattice = []
        for j in range(1, 4):
            vals = list(map(float, lines[cell_idx + j].split()))
            lattice.append(vals)
        lattice = np.array(lattice)

        if cell_unit == 'bohr':
            lattice *= BOHR_TO_ANG
        elif cell_unit == 'alat':
            # Need alat — grab from the header
            alat = parse_alat(lines)
            lattice *= alat * BOHR_TO_ANG
        # angstrom: no conversion needed
    else:
        # Fixed-cell relax: read lattice from file header
        lattice = parse_initial_lattice(lines)

    # ----------------------------------------------------------------
    # Parse ATOMIC_POSITIONS
    # ----------------------------------------------------------------
    pos_line = lines[pos_idx].strip()
    unit_match = re.search(r'\((\w+)\)', pos_line)
    pos_unit = unit_match.group(1).lower() if unit_match else 'angstrom'

    atoms = []   # list of (species, [x, y, z])
    for j in range(pos_idx + 1, len(lines)):
        l = lines[j].strip()
        if not l or l.startswith('End') or re.match(r'[A-Z_]', l) and not re.match(r'^[A-Z][a-z]?\s', l):
            break
        parts = l.split()
        if len(parts) < 4:
            break
        # Some lines have trailing flags like "0 0 0"
        species = parts[0]
        coords  = list(map(float, parts[1:4]))
        atoms.append((species, coords))

    if not atoms:
        raise ValueError("Could not parse any atomic positions.")

    coords = np.array([a[1] for a in atoms])
    species_list = [a[0] for a in atoms]

    # Convert positions to Cartesian angstrom, then to fractional
    if pos_unit in ('angstrom', 'ang'):
        cart = coords
    elif pos_unit == 'bohr':
        cart = coords * BOHR_TO_ANG
    elif pos_unit in ('crystal', 'frac'):
        # Already fractional
        frac = coords
        cart = frac @ lattice
    elif pos_unit == 'alat':
        alat = parse_alat(lines)
        cart = coords * alat * BOHR_TO_ANG
    else:
        cart = coords  # assume angstrom

    # Fractional coordinates
    inv_lat = np.linalg.inv(lattice)
    frac = cart @ inv_lat

    # ----------------------------------------------------------------
    # Build species ordering for POSCAR
    # ----------------------------------------------------------------
    species_order = list(OrderedDict.fromkeys(species_list))
    species_count = {s: 0 for s in species_order}
    for s in species_list:
        species_count[s] += 1

    # Reorder atoms by species
    reordered = []
    for s in species_order:
        for i, sp in enumerate(species_list):
            if sp == s:
                reordered.append((sp, frac[i]))

    return lattice, species_order, species_count, reordered


def parse_alat(lines):
    for line in lines:
        m = re.search(r'lattice parameter \(alat\)\s*=\s*([\d.]+)', line)
        if m:
            return float(m.group(1))
    raise ValueError("Could not find lattice parameter (alat) in output.")


def parse_initial_lattice(lines):
    """Fallback: parse lattice from crystal axes block (fixed-cell relax)."""
    alat = parse_alat(lines)
    lattice = []
    for i, line in enumerate(lines):
        if 'crystal axes:' in line:
            for j in range(1, 4):
                m = re.search(r'a\(\d\)\s*=\s*\(\s*([\d.\-]+)\s+([\d.\-]+)\s+([\d.\-]+)', lines[i+j])
                if m:
                    lattice.append([float(m.group(k)) for k in range(1, 4)])
            break
    if len(lattice) != 3:
        raise ValueError("Could not parse initial lattice vectors.")
    return np.array(lattice) * alat * BOHR_TO_ANG


def write_poscar(lattice, species_order, species_count, reordered, outfile):
    with open(outfile, 'w') as f:
        # Line 1: comment
        f.write("Generated by qe2poscar.py\n")
        # Line 2: scale factor
        f.write("1.0\n")
        # Lines 3-5: lattice vectors
        for vec in lattice:
            f.write(f"  {vec[0]:18.10f}  {vec[1]:18.10f}  {vec[2]:18.10f}\n")
        # Line 6: species names
        f.write("  " + "  ".join(species_order) + "\n")
        # Line 7: species counts
        f.write("  " + "  ".join(str(species_count[s]) for s in species_order) + "\n")
        # Line 8: coordinate mode
        f.write("Direct\n")
        # Atomic positions in fractional coordinates
        for sp, pos in reordered:
            f.write(f"  {pos[0]:18.10f}  {pos[1]:18.10f}  {pos[2]:18.10f}  ! {sp}\n")

    print(f"Written {len(reordered)} atoms to '{outfile}'")
    print(f"  Species: " + ", ".join(f"{s}×{species_count[s]}" for s in species_order))
    a, b, c = [np.linalg.norm(v) for v in lattice]
    print(f"  Lattice: a={a:.4f} Å, b={b:.4f} Å, c={c:.4f} Å")


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    infile  = sys.argv[1]
    outfile = sys.argv[2] if len(sys.argv) > 2 else "POSCAR"

    lattice, species_order, species_count, reordered = parse_qe_output(infile)
    write_poscar(lattice, species_order, species_count, reordered, outfile)


if __name__ == "__main__":
    main()
