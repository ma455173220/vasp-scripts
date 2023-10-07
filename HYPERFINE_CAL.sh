#!/bin/bash

CONVERGENCE_TEST=`grep 'E0=' $PWD/OSZICAR`
if [ "$CONVERGENCE_TEST" ] ;  then
	source $PWD/VASP_AUTO_SUBMISSION
	mkdir HYPERFINE_CONSTANT
	echo "HYPERFINE_CONSTANT directory created"
	cp INCAR POSCAR POTCAR KPOINTS WAVECAR $SUBMISSION_FILE_NAME HYPERFINE_CONSTANT
	cd HYPERFINE_CONSTANT
	qsub $SUBMISSION_FILE_NAME
	cd ..
else
	echo "Calculation not converged, no auto_submission proceeded."
fi

