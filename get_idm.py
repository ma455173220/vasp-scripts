#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Build POSCAR_dimer (with Dimer Axis Block) for VASP IDM (IBRION=44)
from a frequency-calculation OUTCAR.

Workflow
--------
  1) CI-NEB with 5-10 images to find the image closest to the TS.
  2) Frequency calculation on that image:
       NSW=1, IBRION=5, POTIM=0.015, EDIFF=1E-7, NFREE=2, NWRITE=3
       Free *at least* the reactive atoms (and ideally their nearest neighbours);
       keep distant slab atoms fixed. K-mesh 1x1x1 with vasp_gam.
  3) cp <freq-input POSCAR with original selective-dynamics flags> POSCAR_relax
     get_idm.py
  4) mv POSCAR_dimer POSCAR
     IDM run with IBRION=44, POTIM=0.05, original KPOINTS, NSW=500.
"""

import argparse
import re
import sys
from pathlib import Path

import numpy as np
from ase.io import read


# Real freq line:       '   1 f  =   50.270 THz ... 1676.836 cm-1 ...'
# Imaginary freq line:  '   1 f/i=   12.345 THz ...  411.890 cm-1 ...'
RE_IMAG = re.compile(r'^\s*(\d+)\s+f/i\s*=.*?([\d.]+)\s*cm-1')
RE_REAL = re.compile(r'^\s*(\d+)\s+f\s*=.*?([\d.]+)\s*cm-1')
RE_EIG_HEADER = re.compile(r'Eigenvectors after division by SQRT\(mass\)')


def scan_modes(lines, start, regex):
    """Return list of (mode_idx, freq_cm, header_line_idx) matching `regex`."""
    out = []
    for i in range(start, len(lines)):
        m = regex.match(lines[i])
        if m:
            out.append((int(m.group(1)), float(m.group(2)), i))
    return out


def extract_displacement(lines, header_idx, n_atoms):
    """Read the n_atoms x 3 dx/dy/dz columns following a freq header line.

    Layout in OUTCAR after the 'N f/i= ...' header:
        ''                                           <- blank
        '             X         Y         Z       dx        dy        dz'
        <n_atoms data lines>
    The eigenvector block in our extracted region starts at header_idx + 2.
    """
    data_start = header_idx + 2
    data_end = data_start + n_atoms
    if data_end > len(lines):
        raise ValueError(
            f"eigenvector block runs past end of OUTCAR "
            f"(need {n_atoms} rows starting at line {data_start + 1})"
        )
    disp = np.zeros((n_atoms, 3))
    for k, raw in enumerate(lines[data_start:data_end]):
        toks = raw.split()
        if len(toks) < 6:
            raise ValueError(
                f"malformed eigenvector row at OUTCAR line {data_start + k + 1}: {raw!r}"
            )
        disp[k] = [float(toks[3]), float(toks[4]), float(toks[5])]
    return disp


def main():
    ap = argparse.ArgumentParser(
        description="Generate POSCAR_dimer (with Dimer Axis Block) from a VASP freq OUTCAR.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    ap.add_argument('--poscar', default='POSCAR_relax',
                    help='Input POSCAR with original selective-dynamics flags '
                         '(default: POSCAR_relax)')
    ap.add_argument('--outcar', default='OUTCAR',
                    help='OUTCAR from the frequency run (default: OUTCAR)')
    ap.add_argument('-o', '--output', default='POSCAR_dimer',
                    help='Output filename (default: POSCAR_dimer)')
    ap.add_argument('--mode', type=int, default=None, metavar='N',
                    help='Force imaginary mode index N (1-based) instead of '
                         'auto-selecting the one with the largest |nu|.')
    ap.add_argument('--normalize', action='store_true',
                    help='Normalize the dimer axis to unit length '
                         '(VASP does this internally; off by default).')
    args = ap.parse_args()

    # ---- check inputs ----
    if not Path(args.poscar).is_file():
        sys.exit(f"Error: '{args.poscar}' not found. Provide the slab POSCAR with "
                 f"the original (un-fixed) selective-dynamics flags.")
    if not Path(args.outcar).is_file():
        sys.exit(f"Error: '{args.outcar}' not found.")

    # ---- read structure ----
    try:
        atoms = read(args.poscar)
    except Exception as e:
        sys.exit(f"Error reading '{args.poscar}': {e}")
    n_atoms = len(atoms)

    # ---- read OUTCAR ----
    try:
        with open(args.outcar) as f:
            lines = f.readlines()
    except Exception as e:
        sys.exit(f"Error reading '{args.outcar}': {e}")

    # ---- locate the SQRT(mass)-divided eigenvector block ----
    eig_headers = [i for i, ln in enumerate(lines) if RE_EIG_HEADER.search(ln)]
    if not eig_headers:
        sys.exit("Error: 'Eigenvectors after division by SQRT(mass)' not found in OUTCAR.\n"
                 "       Set NWRITE = 3 in INCAR and rerun the freq calculation.")
    eig_start = eig_headers[-1]   # last block, robust to restarts

    # ---- find imaginary modes ----
    imag_modes = scan_modes(lines, eig_start, RE_IMAG)

    if not imag_modes:
        # Diagnose: list the real modes and the freezing scheme so the cause is obvious.
        real_modes = scan_modes(lines, eig_start, RE_REAL)
        msg = [
            "Error: No imaginary frequency (f/i) in OUTCAR.",
            "       The structure is at a minimum (or near one), not a saddle point.",
            "",
        ]
        if real_modes:
            msg.append(f"Real modes found ({len(real_modes)}):")
            for idx, nu, _ in real_modes:
                msg.append(f"   mode {idx:3d}: {nu:10.3f} cm-1")
            msg.append("")
        # The freq calc itself produces 3 * N_free modes — more reliable
        # than reading selective-dynamics flags from POSCAR_relax.
        n_modes = len(real_modes)
        if n_modes and n_modes % 3 == 0:
            n_free_freq = n_modes // 3
            msg.append(f"Frequency calculation produced {n_modes} modes "
                       f"=> {n_free_freq} atom(s) were free in the freq run "
                       f"(out of {n_atoms} total).")
            if n_free_freq <= 3:
                msg.append("   -> Very few free atoms. If the reaction mode involves any "
                           "atom you fixed, the imaginary mode is invisible.")
            msg.append("")
        msg += [
            "Possible causes:",
            "  (a) The selected NEB image is not close enough to the TS",
            "      -- check CI-NEB convergence of the highest image (max force on tangent).",
            "  (b) Too few atoms are unfrozen to capture the reaction mode",
            "      -- free at least the reactive site and its nearest neighbours.",
        ]
        sys.exit("\n".join(msg))

    # ---- choose the dimer mode ----
    if args.mode is not None:
        chosen = next((m for m in imag_modes if m[0] == args.mode), None)
        if chosen is None:
            sys.exit(f"Error: requested mode {args.mode} is not imaginary. "
                     f"Imaginary mode indices: {[m[0] for m in imag_modes]}.")
    else:
        chosen = max(imag_modes, key=lambda m: m[1])   # largest |nu|

    chosen_idx, chosen_nu, chosen_line = chosen

    # ---- report ----
    print(f"OUTCAR  : {args.outcar}")
    print(f"POSCAR  : {args.poscar}  ({n_atoms} atoms)")
    print(f"Imaginary modes ({len(imag_modes)}):")
    for idx, nu, ln in imag_modes:
        tag = '  <-- selected' if (idx, nu, ln) == chosen else ''
        print(f"   mode {idx:3d}: {nu:10.3f} cm-1{tag}")
    n_total_modes = len(imag_modes) + len(scan_modes(lines, eig_start, RE_REAL))
    if n_total_modes % 3 == 0:
        print(f"Free    : {n_total_modes // 3} atom(s) in the freq run "
              f"(of {n_atoms} total)")
    if len(imag_modes) > 1:
        print("Warning: >1 imaginary mode. A genuine TS has exactly one — "
              "this may be a higher-order saddle point.")

    # ---- extract dimer axis ----
    try:
        disp = extract_displacement(lines, chosen_line, n_atoms)
    except ValueError as e:
        sys.exit(f"Error: {e}.")

    if not np.any(np.linalg.norm(disp, axis=1) > 1e-8):
        sys.exit("Error: selected mode's displacement vector is all zeros. "
                 "Did the freq calculation actually have free atoms?")

    if args.normalize:
        norm = np.linalg.norm(disp)
        if norm > 0:
            disp = disp / norm

    # ---- write output ----
    try:
        atoms.write(args.output, vasp5=True)        # fresh file, overwrites
        with open(args.output, 'a') as f:           # then append the dimer axis block
            f.write('  ! Dimer Axis Block\n')
            for v in disp:
                f.write(f'{v[0]: .8f} {v[1]: .8f} {v[2]: .8f}\n')
    except Exception as e:
        sys.exit(f"Error writing '{args.output}': {e}")

    print()
    print(f"Selected: mode {chosen_idx}, {chosen_nu:.3f} cm-1 (imaginary)")
    print(f"Wrote   : {args.output}")
    print(f"Next    : rename {args.output} -> POSCAR; run IDM with IBRION=44, POTIM=0.05.")


if __name__ == '__main__':
    main()
