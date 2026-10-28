# Rebuild the Fortran trajectory analyser from source. Run "make" on the cluster where
# it is used (the committed binary was built on Setonix): the binary is older than
# the 2026-10 fixes in vasp-xdat-analyzer.f90 until it is rebuilt there.
# another compiler: make FC=ifx
FC = gfortran
FFLAGS ?= -O2

vasp-xdat-analyzer: vasp-xdat-analyzer.f90
	$(FC) $(FFLAGS) -o $@ $<
