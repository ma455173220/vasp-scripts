#!/apps/python3/3.10.0/bin/python3
import sys
import xml.dom.minidom
import argparse
import math
# from collections import Counter

"""
Usage:
    wannier_eigwin.py EIGENVAL -e BAND_INDEX [-s spinup/spindw] (e.g., wannier_eigwin.py EIGENVAL -e 5 -s spinup)
    wannier_eigwin.py EIGENVAL -n BAND_RANGE [-s spinup/spindw] (e.g., wannier_eigwin.py EIGENVAL -n -1.6 1.6 -s spindw)

Options:
    EIGENVAL           Path to the EIGENVAL file
    -e                  Option to extract the eigenvalues and eigenvectors for a single band
    BAND_INDEX         Index of the band to extract
    -n                  Option to extract the eigenvalues and eigenvectors for a range of bands
    BAND_RANGE         Range of bands to extract, e.g., "5 10"
    -s
    spinup/spindw      Specify the spin channel to extract (default=None)
                       For ISPIN=1, this option is not required

"""

# Define the command line arguments and help information
parser = argparse.ArgumentParser(usage='%(prog)s [-h] EIGENVAL (-e band_index | -n energy1 energy2) [-s spinup/spindw]', description='Extract data from EIGENVAL files.')
parser.add_argument('-f', metavar='xml_name', type=str, default="EIGENVAL", help='Path to the EIGENVAL file')
parser.add_argument('-e', metavar='band_index', type=int, help='Specify a single band to extract')
parser.add_argument('-n', metavar=('energy1', 'energy2'), type=float, nargs=2, help='Specify an energy range to extract')
parser.add_argument('-s', metavar='spin', type=str, choices=['spinup', 'spindw'], default=None, help='Specify the spin channel to extract (default=None)')

# Parse the command line arguments
args = parser.parse_args()

# Check the options and extract the relevant information
if args.e is not None:
    # Process the case where the option is "e" and extract a single band
    band_index = args.e
    option = "-e"
elif args.n is not None:
    # Process the case where the option is "n" and extract an energy range
    energy1, energy2 = args.n
    option = "-n"
else:
    # If the arguments are not valid, print an error message and exit
    print("ERROR: Incorrect usage.")
    parser.print_help()
    exit(1)

# Extract the spin channel if specified
spin = args.s
xml_name = args.f

def get_energies(xml_name):
    # VASP EIGENVAL format
    if xml_name == "EIGENVAL":
        with open(xml_name, "r") as eigenval:
            raw_content = eigenval.readlines()
        orbital_information = raw_content[5:6]                                                                  
        num_electrons, num_kpoints, total_band = map(int, orbital_information[0].strip().split())

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
                if args.s is None:                                                           
                    print("ERROR: '-s' argument is required for spin-polarized calculation.")
                    parser.print_help()                                                      
                    exit(1)                                                                  
                else:                                                                        
                    if args.s not in ["spinup", "spindw"]:                                   
                        print("ERROR: '-s' argument must be 'spinup' or 'spindw'.")          
                        parser.print_help()                                                  
                        exit(1)                                                              
                    else:                                                                    
                        spin = args.s                                                        
                n, energy_up, energy_dw, occ_up, occ_dw = line.split()
                if spin == "spinup":
                    if math.ceil(float(occ_up)) == 1:
                        homo_n_index_ki_max = int(n)
                    eng_ki.append(float(energy_up))
                elif spin == "spindw":
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

        # Since the last line is not blank, we need to append eng_ki of the last k to eng_full list
        eng_full.append(eng_ki)
        # find most common index in the list                     
        # most_common_element = Counter(homo_n_index_ki_max_list)
        # most_common = most_common_element.most_common(1)[0][0] 
        # print homo and lumo orbital index                      
        homo_n_index_max = max(homo_n_index_ki_max_list)
        lumo_n_index_max = homo_n_index_max + 1
    # Quantum ESPRESSO and FLEUR xml format
    else:
        Har2eV = 13.60569253 * 2
        dom = xml.dom.minidom.parse(xml_name)
        root = dom.documentElement
        eng_full = []
        if root.nodeName == "fleurOutput":
            eigenvalues = root.getElementsByTagName("eigenvalues")[-1]
            eks = eigenvalues.getElementsByTagName("eigenvaluesAt")
            eng_full = [[float(f) * Har2eV for f in ek.childNodes[0].data.split()] for ek in eks]
        elif root.nodeName == "qes:espresso":
            eigenvalues = root.getElementsByTagName("eigenvalues")
            eng_full = [[float(f) * Har2eV for f in ek.childNodes[0].data.split()] for ek in eigenvalues]
        else:
            raise RuntimeError("Unknown xml output")
    return eng_full, homo_n_index_max, lumo_n_index_max, total_band


def main():
    if option == "-e":
        # Band index is counted from 1, NOT 0.
        eng_full, homo_n_index_max, lumo_n_index_max, total_band = get_energies(xml_name)
        eng_selected =[eng[band_index-1] for eng in eng_full]
        emin = min(eng_selected)
        emax = max(eng_selected)
        print("Tot_bands = %d" % total_band)
        print("homo_index = %d" % homo_n_index_max)
        print("lumo_index = %d" % lumo_n_index_max)
        print("emin = %f" % emin)
        print("emax = %f" % emax)
    elif option == "-n":
        # Energies are in eV, not Hartree.
        eng_full, _, _, _ = get_energies(xml_name)
        for ik, ek in enumerate(eng_full):
            num_bands = 0
            for eng in ek:
                if eng >= energy1 and eng <= energy2:
                    num_bands += 1
            print("ik = %d, nbnd = %d" % (ik+1, num_bands))
    else:
        print("ERROR: unknown option '%s'" % option)

if __name__ == "__main__":
    main()
