﻿#!/home/561/hm1876/.local/miniconda3/bin/python3

import subprocess
import os
import sys
import math
import re

from optparse import OptionParser



# Some ANSI colors

OKGREEN = '\033[36m'
WARNING = '\033[33m'
FAIL = '\033[31m'
ENDC = '\033[0m'

# *****************************************
#             Main program
# *****************************************

parser = OptionParser()
parser.add_option('-v', '--verbose', dest='verbose',
                  help='Print extra info', action='store_true')
(options, args) = parser.parse_args()

def get_number_of_atoms(where):
    return int(subprocess.getoutput('grep "NIONS" '
               + where).split()[11])

try:
    outcar = open(args[0], 'r')
except IndexError:
    sys.stderr.write(FAIL)
    sys.stderr.write('There was a problem opening the OUTCAR file. Does it exist at all?'
                     )
    sys.stderr.write(ENDC + '\n')
    sys.exit(1)

if outcar != None:
    outcarfile = args[0]
    outcarlines = outcar.readlines()

    natoms = get_number_of_atoms(outcarfile)

    re_energy = re.compile('energy  without entropy')
    re_iteration = re.compile('Iteration')
    re_timing = re.compile('LOOP:')
    re_timing_plus = re.compile(r'LOOP\+')
    re_force = re.compile('TOTAL-FORCE')
    re_mag = re.compile('number of electron')
    re_volume = re.compile('volume of cell')

    lastenergy = 0.0
    energy = 0.0
    steps = 1
    iterations = 0
    cputime = 0.0
    totaltime = 0.0
    cputime_plus = 0.0
    dE = 0.0
    magmom = 0.0
    spinpolarized = False
    volume = 0.0
    atoms_relax = []
    atoms_freeze = []

    average = 0.0
    maxforce = 0.0

    try:
        poscar = open("POSCAR", 'r')
    except IndexError:
        pass

    if poscar != None:
        check_poscar = subprocess.getoutput('grep -in "Selective dynamics" POSCAR')
        if len(check_poscar) != 0:
            line_number_selective_dynamics = int(check_poscar.split(":")[0])
            pos = poscar.readlines()
            for i, value in enumerate(pos):
                if i >= line_number_selective_dynamics + 1 and i < line_number_selective_dynamics + 1 + natoms:
                    if value.split()[3] and value.split()[4] and  value.split()[5] == "F":
                        atom_index = int(i - line_number_selective_dynamics)
                        atoms_freeze.append(atom_index)
                    else:
                        atom_index = int(i - line_number_selective_dynamics)
                        atoms_relax.append(atom_index)

    i = 0
    for line in outcarlines:
        if "NELM" and "NELMIN" and "NELMDL" in line:
            nelmax = line.split()[2].strip(';')

        if "NIONS" in line:
            natoms = int(line.split()[11])

        if "  EDIFF  " in line:
            ediff = math.log10(float(line.split()[2]))

        if re_iteration.search(line):
            iterations = iterations + 1

        #if "FORCES: max atom" in line:
        #    maxforce = float(line.split()[4])
        if re_force.search(line):

            forces = []
            magnitudes = []
            if len(atoms_relax) != 0:
                for j in atoms_relax:
                    parts = outcarlines[i + j + 1].split()
                    x = float(parts[3])
                    y = float(parts[4])
                    z = float(parts[5])
                    forces.append([x, y, z])
                    magnitudes.append(math.sqrt(x * x + y * y + z * z))
                average = sum(magnitudes) / len(atoms_relax)
                maxforce = max(magnitudes)
            else:
                for j in range(0, natoms):
                    parts = outcarlines[i + j + 2].split()
                    x = float(parts[3])
                    y = float(parts[4])
                    z = float(parts[5])
                    forces.append([x, y, z])
                    magnitudes.append(math.sqrt(x * x + y * y + z * z))
                average = sum(magnitudes) / natoms
                maxforce = max(magnitudes)

        if re_mag.search(line):
            parts = line.split()
            if len(parts) > 5 and parts[0].strip() != 'NELECT':
                spinpolarized = True
                magmom = float(parts[5])

        if re_timing.search(line):
            all_elements = line.split()
            last_element = all_elements[len(all_elements) - 1]
            filter_digit = filter(lambda ch: ch in '0123456789.', last_element)
            filter_digit = ''.join(list(filter_digit))
            # print(filter_digit)
            cputime = cputime + float(filter_digit) / 60.0
            
        if re_volume.search(line):
            parts = line.split()
            if len(parts) > 4:
                volume = float(parts[4])

        #if re_energy.search(line):
        #    lastenergy = energy
        #    energy = float(line.split()[4])
        #    dE = math.log10(abs(energy - lastenergy))
        if re_energy.search(line):
            lastenergy = energy
            energy = float(line.split()[-1])
            dE = energy - lastenergy
            energystr = 'Energy: ' + ('%3.6f' % energy).rjust(12)
            if dE < 0:
                sys.stdout.write(OKGREEN)
            else:
                energy =  lastenergy
                sys.stdout.write(WARNING)

        if re_timing_plus.search(line):
            all_elements_plus = line.split()
            last_element_plus = all_elements_plus[len(all_elements_plus) - 1]
            filter_digit_plus = filter(lambda ch: ch in '0123456789.', last_element_plus)
            filter_digit_plus = ''.join(list(filter_digit_plus))
            #print(filter_digit_plus)
            if filter_digit_plus:
                cputime_plus = cputime_plus + float(filter_digit_plus) / 60.0
            else:
                cputime_plus = 999999

            try:
                stepstr = str(steps).rjust(4)
                #energystr = 'Energy: ' + ('%3.6f' % energy).rjust(12)
                logdestr = 'Log|dE|: ' + ('%1.3f' % dE).rjust(6)
                iterstr = 'SCF: ' + '%3i' % iterations
                avgfstr = 'Avg|F|: ' + ('%2.3f' % average).rjust(6)
                maxfstr = 'Max|F|: ' + ('%2.3f' % maxforce).rjust(6)
                timestr = 'Time: ' + ('%3.2fm' % cputime).rjust(6)
                timestr_plus = 'Time+: ' + ('%3.2fm' % cputime_plus).rjust(6)
                volstr = 'Vol.: ' + ('%3.1f' % volume).rjust(5)
            except NameError:
                print('Cannot understand this OUTCAR file...try to read ahead')
                continue

            if int(iterations) == int(nelmax):
                sys.stdout.write(FAIL)
            #if dE < 0:
            #    sys.stdout.write(OKGREEN)
            #else:
            #    sys.stdout.write(WARNING)

            if spinpolarized:

                magstr = 'Mag: ' + ('%2.2f' % magmom).rjust(6)
                print('%s  %s  %s  %s  %s  %s  %s  %s  %s ' % (
                    stepstr,
                    energystr,
                    iterstr,
                    avgfstr,
                    maxfstr,
                    volstr,
                    magstr,
                    timestr,
                    timestr_plus,
                    ))
            else:
                print('%s  %s  %s  %s  %s  %s  %s  %s ' % (
                    stepstr,
                    energystr,
                    iterstr,
                    avgfstr,
                    maxfstr,
                    volstr,
                    timestr,
                    timestr_plus,
                    ))

            sys.stdout.write(ENDC)
            steps = steps + 1
            iterations = 0
            totaltime = totaltime + cputime
            cputime = 0.0
            cputime_plus = 0.0

        i = i + 1
