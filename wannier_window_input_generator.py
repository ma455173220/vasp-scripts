#!/usr/bin/env python3
import os
import argparse
import math
# from collections import Counter

class WannierInputModifier:
    def __init__(self):
        self.input_file = None
        self.spin_state = None
        self.total_band = None
        self.num_kpoints = None
        self.num_electrons = None
        self.homo_index = None
        self.lumo_index = None
        self.num_wann = None
        self.homo_wannier_function_index = None
        self.lumo_wannier_function_index = None
        self.dis_froz_min = None
        self.dis_froz_max = None
        self.num_bands = None
        self.homo_bands_index = None
        self.lumo_bands_index = None
        self.dis_win_min = None
        self.dis_win_max = None

    def check_input_file(self):
        if not os.path.isfile(self.input_file) or os.stat(self.input_file).st_size == 0:
            print(f"Error: The specified file '{self.input_file}' does not exist or is empty.")
            exit(1)

    def parse_arguments(self):
        parser = argparse.ArgumentParser()
        parser.add_argument("-f", "--file", default="wannier90.win", help="Specify the filename of the wannier90 input file.")
        parser.add_argument("-s", "--spin_state", choices=["spinup", "spindw"], help="Specify the spin state of the system.")
        parser.add_argument("-w", "--mlwf_index", nargs=2, type=int, metavar=("NW1", "NW2"), help="Specify the minimum and maximum values of MLWF indices.")
        parser.add_argument("-b", "--num_bands_index", nargs=2, type=int, metavar=("NB1", "NB2"), help="Specify the minimum and maximum values of num_bands indices.")

        # Add more arguments as needed
        args = parser.parse_args()

        # Check parameters
        if args.mlwf_index is None or args.num_bands_index is None:
            print("Error: Please provide both MLWF indices and num_bands indices using the -w or -b options.")
            parser.print_help()
            exit(1)

        # check if it is a spin-polarized calculation
        with open("EIGENVAL", "r") as eigenval:
            raw_content = eigenval.readlines()
        content = raw_content[8:9]
        orbital_information = raw_content[5:6]
        self.num_electrons, self.num_kpoints, self.total_band = map(int, orbital_information[0].strip().split())

        if len(content[0].strip().split()) == 5:
            print("This calculation is a spin-polarized calculation (ISPIN=2)")
            if args.spin_state is None:
                print("Error: Please specify the spin state of the system using the -s option.")
                parser.print_help()
                exit(1)
        else:
            print("This calculation is a non-spin-polarized (ISPIN=1) or SOC calculation")

        # Assign arguments to class variables
        self.spin_state = args.spin_state
        self.input_file = args.file
        self.homo_wannier_function_index, self.lumo_wannier_function_index = args.mlwf_index
        self.homo_bands_index, self.lumo_bands_index = args.num_bands_index


    def extract_band_indices(self):
        emin, emax = self.extract_energy_information(xml_name="EIGENVAL", band_index=1, spin_state=self.spin_state)
        print(f"Extracted band info:\n"
              f"Total bands: \033[33m{self.total_band}\033[0m\n"
              f"HOMO index: \033[33m{self.homo_index}\033[0m\n"
              f"LUMO index: \033[33m{self.lumo_index}\033[0m")

        print("-----------------------------------------------")

    def read_num_wann(self):
        with open(self.input_file) as f:
            lines = f.readlines()
            self.num_wann = int([line.split('=')[1].strip() for line in lines if 'num_wann' in line][0])
            print(f"\033[33mnum_wann\033[0m info:\n"
                  f"num_wann: {self.num_wann}")
        if self.lumo_wannier_function_index - self.homo_wannier_function_index + 1 != self.num_wann:
            print("\033[31mError:\033[0m The range of MLWF indices provided by -w option does not match the value of num_wann.")
            exit(1)

    def calculate_froz_energy_windows(self):
        # Calculate energy window for homo wannier function if needed
        # Covers all wannier orbitals as much as possible
        homo_wannier_function_index_modified = self.homo_wannier_function_index - 1
        lumo_wannier_function_index_modified = self.lumo_wannier_function_index + 1
        if homo_wannier_function_index_modified > 0:
            emin, emax = self.extract_energy_information(xml_name="EIGENVAL", band_index=homo_wannier_function_index_modified, spin_state=self.spin_state)
            emin = float(emin)
            emax = float(emax)
            self.dis_froz_min = emax + 0.0005
            print(f"dis_froz_min: {self.dis_froz_min:.6f}")
        else:
            self.dis_froz_min = None
            print(f"dis_froz_min covers all valence bands")

        # Calculate energy window for lumo wannier function if needed
        if lumo_wannier_function_index_modified <= self.total_band:
            emin, emax = self.extract_energy_information(xml_name="EIGENVAL", band_index=lumo_wannier_function_index_modified, spin_state=self.spin_state)
            emin = float(emin)
            emax = float(emax)
            self.dis_froz_max = emin - 0.0005
            print(f"dis_froz_max: {self.dis_froz_max:.6f}")
        else:
            self.dis_froz_max = None
            print(f"dis_froz_max covers all conduction bands")
        print("-----------------------------------------------")

    def read_num_bands(self):
        with open(self.input_file) as f:
            lines = f.readlines()
            self.num_bands = int([line.split('=')[1].strip() for line in lines if 'num_bands' in line][0])
            print(f"\033[33mnum_bands\033[0m info:\n"
                  f"num_bands: {self.num_bands}")
        if self.lumo_bands_index - self.homo_bands_index + 1 != self.num_bands:
            print("\033[31mError:\033[0m The range of num_bands indices provided by the -b option does not match the value of num_bands.")
            exit(1)

    def calculate_win_energy_windows(self):
        # calculate energy window for homo bands if needed
        if self.homo_bands_index > 1:
            emin, emax = self.extract_energy_information(xml_name="EIGENVAL", band_index=self.homo_bands_index, spin_state=self.spin_state)
            emin = float(emin)
            emax = float(emax)
            self.dis_win_min = emin - 0.0005
            if self.dis_win_min > self.dis_froz_min:
                self.dis_win_min = self.dis_froz_min
            print(f"dis_win_min: {self.dis_win_min:.6f}")
        else:
            self.dis_win_min = None
            print(f"dis_win_min covers all valence bands")

        # calculate energy window for lumo bands if needed
        if self.lumo_bands_index < self.total_band:
            emin, emax = self.extract_energy_information(xml_name="EIGENVAL", band_index=self.lumo_bands_index, spin_state=self.spin_state)
            emin = float(emin)
            emax = float(emax)
            self.dis_win_max = emax + 0.0005
            if self.dis_win_max < self.dis_froz_max:
                self.dis_win_max = self.dis_froz_max
            print(f"dis_win_max: {self.dis_win_max:.6f}")
        else:
            self.dis_win_max = None
            print(f"dis_win_max covers all conduction bands")
        print("-----------------------------------------------")

    def extract_energy_information(self, xml_name, band_index, spin_state=None):
        # Read EIGENVAL file
        with open(xml_name, "r") as eigenval:
            raw_content = eigenval.readlines()

        # Extract energy information
        eng_full = []
        eng_ki = []
        homo_n_index_ki_max_list = []
        homo_n_index_ki_max = None
        for i, line in enumerate(raw_content[7:]):
            # Pass the k point information line
            if len(line.split()) == 4:
                continue
            # Spin polarized calculation
            elif len(line.split()) == 5:
                if spin_state is None:
                    print("ERROR: '-s' argument is required for spin-polarized calculation.")
                    exit(1)
                n, energy_up, energy_dw, occ_up, occ_dw = line.split()
                if spin_state == "spinup":
                    if math.ceil(float(occ_up)) == 1:
                        homo_n_index_ki_max = int(n)
                    eng_ki.append(float(energy_up))
                elif spin_state == "spindw":
                    if math.ceil(float(occ_dw)) == 1:
                        homo_n_index_ki_max = int(n)
                    eng_ki.append(float(energy_dw))
            # Spin un-polarized calculation or SOC
            elif len(line.split()) == 3:
                n, energy, occ = line.split()
                if math.ceil(float(occ)) == 1:
                    homo_n_index_ki_max = int(n)
                eng_ki.append(float(energy))
            # Reached a blank line, indicating the end of energies for the current k point
            else:
                eng_full.append(eng_ki)
                homo_n_index_ki_max_list.append(homo_n_index_ki_max)
                eng_ki = []

        # Since the last line of EIGENVAL is not blank, we need to append eng_ki of the last k to eng_full list
        eng_full.append(eng_ki)
        # find most common index in the list                     
        # most_common_element = Counter(homo_n_index_ki_max_list)
        # most_common = most_common_element.most_common(1)[0][0] 
        # print homo and lumo orbital index                      
        self.homo_index = max(homo_n_index_ki_max_list)          
        self.lumo_index = self.homo_index + 1                    
        eng_selected =[eng[band_index-1] for eng in eng_full]
        emin = min(eng_selected)
        emax = max(eng_selected)

        return emin, emax


    def write_input_file(self):
        keys_list = ["dis_win_max", "dis_win_min", "dis_froz_max", "dis_froz_min"]
        with open(self.input_file, "r") as f:
            lines = f.readlines()
            f.close()

        # Remove the lines containing the keys
        lines = [line for line in lines if not any(line.startswith(key) for key in keys_list)]

        insert_lines = []
        for var_name, var_value in zip(["dis_win_max", "dis_win_min", "dis_froz_max", "dis_froz_min"],
                                       [self.dis_win_max, self.dis_win_min, self.dis_froz_max, self.dis_froz_min]):
            if var_value is not None:
                insert_lines.append(f"{var_name} = {var_value:.6f}\n")

        with open(self.input_file, 'w') as f:
            f.writelines(insert_lines + lines)
            f.close()

    def main(self):
        self.parse_arguments()
        self.check_input_file()
        self.extract_band_indices()
        self.read_num_wann()
        self.calculate_froz_energy_windows()
        self.read_num_bands()
        self.calculate_win_energy_windows()
        self.write_input_file()

if __name__ == "__main__":
    modifier = WannierInputModifier()
    modifier.main()

