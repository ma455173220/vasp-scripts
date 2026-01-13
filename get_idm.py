#!/usr/bin/env python3
# -*- coding: utf-8 -*-

# Print the initial information block
print('''\
Improved Dimer Method - General Calculation Steps:
1) Run CI-NEB calculation with 5-10 images to find the closest structure to TS.
2) Run frequency calculation on the selected structure:
   - Fix all slab atoms
   - Use a 1x1x1 k-mesh
   - Use vasp_gam for calculations
   Settings:
   NSW = 1
   IBRION = 5
   POTIM = 0.015
   EDIFF = 1E-7
   NFREE = 2
   NWRITE = 3 # Must be 3
3) Run this script:
   Copy the unfreezed POSCAR file and rename it to POSCAR_relax.
   get_dimer.py 
4) Use the POSCAR for IDM calc:
   Use original KPOINTS.
   NSW = 500           
   IBRION=44           # Use the dimer method as optimization engine
   POTIM = 0.05
''')

# Start running the script
print("Program is now starting... Please wait until completion. This may take a while.")

import numpy as np
from ase.io import read, write
import os
from sys import exit

# Check if the required POSCAR_relax file exists
if not os.path.exists('POSCAR_relax'):
    print("Error: The file 'POSCAR_relax' is missing.")
    print("This file should be the original slab structure from before the frequency calculation, where not all slab atoms are fixed.")
    exit()

# Read the POSCAR_relax file
try:
    model = read('POSCAR_relax')
    model.write('POSCAR_dimer', vasp5=True)
except Exception as e:
    print(f"Error reading 'POSCAR_relax': {e}")
    exit()

# Check if OUTCAR file exists for frequency information extraction
if not os.path.exists('OUTCAR'):
    print("Error: 'OUTCAR' file not found. Please ensure that OUTCAR from the frequency calculation is available.")
    exit()

# Read OUTCAR to locate frequency information
l_start = 0  # the number of line which contains 'Eigenvectors after division by SQRT(mass)'
try:
    with open('OUTCAR') as f_in:
        lines = f_in.readlines()
        for num, line in enumerate(lines):
            if 'Eigenvectors after division by SQRT(mass)' in line:
                l_start = num
except Exception as e:
    print(f"Error reading 'OUTCAR': {e}")
    exit()

if l_start == 0:
    print("Error: 'Eigenvectors after division by SQRT(mass)' not found in OUTCAR. Verify that NWRITE is set to 3 and rerun.")
    exit()

# Extract frequency information for the dimer axis
freq_infor_block = lines[l_start:]
l_position = 0
wave_num = 0.0
for num, line in enumerate(freq_infor_block):
    if 'f/i' in line:
        try:
            wave_tem = float(line.rstrip().split()[6])
        except ValueError:
            print(f"Error: Could not extract wave number from line {num + l_start}. Verify OUTCAR content.")
            exit()
        if wave_tem > wave_num:
            wave_num = wave_tem
            l_position = num + 2

# Append Dimer Axis Block to POSCAR_dimer
try:
    with open('POSCAR_dimer', 'a') as pos_dimer:
        pos_dimer.write('  ! Dimer Axis Block\n')
        vib_lines = freq_infor_block[l_position:l_position + len(model)]
        for line in vib_lines:
            infor = line.rstrip().split()[3:]
            pos_dimer.write(' '.join(infor) + '\n')
except Exception as e:
    print(f"Error writing to 'POSCAR_dimer': {e}")
    exit()

# Final message indicating script has finished
print('''
DONE!
Output file is named as: POSCAR_dimer and can be used for dimer calculations.
Don't forget to rename POSCAR_dimer to POSCAR before you run the dimer jobs.      
''')

