#!/bin/bash

module purge

module load intel-compiler/2021.4.0
module load intel-mkl/2021.4.0
module load fftw3-mkl/2021.4.0
module load openmpi/4.1.3
module load wannier90/3.1.0

make all

