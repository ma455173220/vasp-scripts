#!/bin/bash
VASP_AUTO_SUBMISSION="test_script"
# source $PWD/VASP_AUTO_SUBMISSION
cp INCAR_RESTART INCAR
JOB_NUMBER=`grep 'JOBNAME=' test_script | awk -F '"|-' '{print$2}'`
NEW_JOB_NUMBER=`printf "%02d\n" $(expr $JOB_NUMBER + 1)`
sed  -i '/^NSW/ s/=.*-/=${NEW_JOB_NUMBER}-/' $SUBMISSION_FILE_NAME
#qsub $SUBMISSION_FILE_NAME
