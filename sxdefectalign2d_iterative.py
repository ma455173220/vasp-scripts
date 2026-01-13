#!/usr/bin/env python3
import os
import numpy as np
import matplotlib.pyplot as plt

# Define cutoff energy (in Ry) as a variable for easy modification
ecut = 36.75  

# Define paths for the defective system and bulk LOCPOT files
vdef_path = "./LOCPOT"  # Path to the defective system LOCPOT
vref_path = "/scratch/g46/hm1876/jahan/MoSe2_exercise/Defects/MoSe2_bulk_new/vasp_gam/LOCPOT"  # Path to the bulk LOCPOT

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
