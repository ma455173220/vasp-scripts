#!/bin/bash

CONVERGENCE_TEST=`grep 'reached required accuracy' $PWD/OUTCAR`
if [ "$CONVERGENCE_TEST" ] ;  then
	source $PWD/VASP_AUTO_SUBMISSION
	rm -rf $PWD/DOSCAR $PWD/WAVECAR $PWD/CHG* $PWD/vasprun.xml $PWD/PROCAR $PWD/LOCPOT $PWD/vaspout.h5
	mkdir NON-SC
	echo "NON-SC directory created"
	cp INCAR POSCAR POTCAR KPOINTS $SUBMISSION_FILE_NAME NON-SC
	cd NON-SC
	sed  -i '/^NSW/ s/=.*#/=  0            #/' INCAR
	sed  -i '/^IBRION/ s/=.*#/=  -1            #/' INCAR
	qsub $SUBMISSION_FILE_NAME
	cd ..
else
	echo "Calculation not converged, no auto_submission proceeded."
fi

