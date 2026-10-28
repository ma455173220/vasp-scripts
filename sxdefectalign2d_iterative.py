#!/usr/bin/env python3
"""
Run sxdefectalign2d for a range of --shift values and plot the potentials.

Usage:
  sxdefectalign2d_iterative.py --vref <bulk LOCPOT> [--vdef ./LOCPOT] [--ecut 36.75]
  (or set the environment variable VREF_LOCPOT instead of --vref)

Example:
  sxdefectalign2d_iterative.py --vref /scratch/g46/hm1876/jahan/MoSe2_exercise/Defects/MoSe2_bulk_new/vasp_gam/LOCPOT
"""
import os
import argparse
import numpy as np
import matplotlib.pyplot as plt

parser = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument("--vref", default=os.environ.get("VREF_LOCPOT"),
                    help="Path to the bulk (reference) LOCPOT (default: $VREF_LOCPOT)")
parser.add_argument("--vdef", default="./LOCPOT", help="Path to the defective system LOCPOT (default: ./LOCPOT)")
parser.add_argument("--ecut", type=float, default=36.75, help="Cutoff energy in Ry (default: 36.75)")
args = parser.parse_args()
if not args.vref:
    parser.error("bulk LOCPOT required: pass --vref <path> or set VREF_LOCPOT")

# Define cutoff energy (in Ry)
ecut = args.ecut

# Define paths for the defective system and bulk LOCPOT files
vdef_path = args.vdef  # Path to the defective system LOCPOT
vref_path = args.vref  # Path to the bulk LOCPOT

# Ensure 'figs' directory exists
os.makedirs("figs", exist_ok=True)

# Define the range of shift values
shift_values = np.arange(6, 9, 1)

for shift in shift_values:
    print(f"Processing shift value: {shift}")

    # Run sxdefectalign2d with the defined variables
    cmd = f"sxdefectalign2d --ecut {ecut} --vdef {vdef_path} --vref {vref_path} --vasp --shift {shift}"
    os.system(cmd)

    # Load the data file and plot
    data = np.loadtxt("vline-eV.dat")
    z, Vmod, Vdft, Vsr = data[:, 0], data[:, 1], data[:, 2], data[:, 3]

    plt.figure()
    plt.plot(z, Vmod, label='Vmod', color='black')
    plt.plot(z, Vdft, label='Vdft', color='red')
    plt.plot(z, Vsr, label='Vsr', color='green')
    plt.xlabel("z [bohr]")
    plt.ylabel("Potential [eV]")
    plt.legend()

    # Save the figure with a unique name
    output_filename = f"figs/plot_{shift}.jpg"
    plt.savefig(output_filename, format='jpg')
    plt.close()

    print(f"Saved: {output_filename}")

print("Processing complete.")
