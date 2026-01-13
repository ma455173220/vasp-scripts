#!/usr/bin/env python3
"""
Vacancy Generation Script (Oxygen Vacancies) using pymatgen
-----------------------------------------------------------
This script:
1. Reads a user-specified supercell (CIF or POSCAR).
2. Uses VacancyGenerator to enumerate symmetry-distinct oxygen vacancies.
3. Exports each defect structure to separate POSCAR files.

Requirements:
- pymatgen
- pymatgen-analysis-defects

Author: Your Name
"""

import os
from pymatgen.core import Structure
from pymatgen.analysis.defects.generators import VacancyGenerator

# ===================== USER SETTINGS =====================
INPUT_FILE = "SUPERCELL_333.cif"  # Input supercell file
OUTPUT_DIR = "Oxygen_Vacancies"   # Directory to store defect structures
SYMPREC = 0.1                     # Symmetry tolerance (Å)
ELEMENT = "O"                     # Target element for vacancy
# ==========================================================

# --- Check input file existence ---
if not os.path.exists(INPUT_FILE):
    raise FileNotFoundError(f"Input file '{INPUT_FILE}' not found. "
                            f"Please check the path.")

print(f"[INFO] Reading structure from: {INPUT_FILE}")
struct = Structure.from_file(INPUT_FILE)
print(f"[INFO] Structure loaded successfully: "
      f"{len(struct)} atoms, {len(struct.composition.elements)} unique elements.")

# --- Initialize vacancy generator ---
print(f"[INFO] Initializing VacancyGenerator for {ELEMENT} vacancies...")
vac_gen = VacancyGenerator()

# --- Generate vacancies ---
vacancies = list(vac_gen.generate(structure=struct, symprec=SYMPREC))
print(f"[INFO] Found {len(vacancies)} symmetry-distinct {ELEMENT} vacancy configurations.")

# --- Create output directory ---
os.makedirs(OUTPUT_DIR, exist_ok=True)

# --- Export each defect structure ---
for i, vac in enumerate(vacancies):
    # Access the defect structure
    defect_struct = vac.defect_structure  # For pymatgen-analysis-defects >=2024
    filename = os.path.join(OUTPUT_DIR, f"{ELEMENT}vac_{i}.vasp")
    
    # Export to VASP POSCAR format
    defect_struct.to(fmt="poscar", filename=filename)
    print(f"[INFO] Exported: {filename}")

print("\n[INFO] Vacancy generation completed successfully.")
print(f"[INFO] Output directory: {os.path.abspath(OUTPUT_DIR)}")
print("[INFO] Use the exported POSCARs for subsequent DFT calculations.")
