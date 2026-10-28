#!/bin/bash
#2020/04/25 fix a definition of shear strain
#20190524 fix a bug
#a simple bash shell to add specific strain on the Direct coordination
#Cartesian strain r -> r.(I+eps); Direct and Cartesian POSCARs are both handled
#ponychen 2019/05/22

# check if user has provided enough input
if [ $# -ne 2 ]
then
  echo "Usage: $0 stress_direction strain_amount"
  echo "Example: $0 XX 0.1"
  exit 1
fi

# set the stress direction and strain amount based on user input
case $1 in
  XX) Setstrain=( $2 0.0 0.0 0.0 0.0 0.0 );;
  YY) Setstrain=( 0.0 $2 0.0 0.0 0.0 0.0 );;
  ZZ) Setstrain=( 0.0 0.0 $2 0.0 0.0 0.0 );;
  XY) Setstrain=( 0.0 0.0 0.0 $2 0.0 0.0 );;
  XZ) Setstrain=( 0.0 0.0 0.0 0.0 $2 0.0 );;
  YZ) Setstrain=( 0.0 0.0 0.0 0.0 0.0 $2 );;
  *) echo "Invalid stress direction"; exit 1;;
esac

# Cartesian strain: every lattice vector (row) r -> r . (I + eps), with eps symmetric
# and the off-diagonal (shear) input taken as engineering strain (eps_xy = gamma/2).
# The scale factor (line 2; negative = volume) is folded into the vectors and line 2
# is written as 1.0. Direct coordinates follow the cell; Cartesian coordinates are
# transformed with the same matrix.
awk -v arr1="${Setstrain[*]}" '
    function det3(m) { return m[1,1]*(m[2,2]*m[3,3]-m[2,3]*m[3,2]) - m[1,2]*(m[2,1]*m[3,3]-m[2,3]*m[3,1]) + m[1,3]*(m[2,1]*m[3,2]-m[2,2]*m[3,1]) }
    function strain(x, y, z, k) {
        nx = x*F[1,1] + y*F[2,1] + z*F[3,1]
        ny = x*F[1,2] + y*F[2,2] + z*F[3,2]
        nz = x*F[1,3] + y*F[2,3] + z*F[3,3]
    }
    BEGIN {
        split(arr1, e, " ")
        F[1,1] = 1 + e[1]; F[2,2] = 1 + e[2]; F[3,3] = 1 + e[3]
        F[1,2] = F[2,1] = e[4] / 2; F[1,3] = F[3,1] = e[5] / 2; F[2,3] = F[3,2] = e[6] / 2
    }
    { L[NR] = $0 }
    END {
        scal = L[2] + 0
        for (i = 1; i <= 3; i++) { split(L[i+2], v, " "); for (j = 1; j <= 3; j++) R[i,j] = v[j] }
        if (scal < 0) { d = det3(R); if (d < 0) d = -d; scal = (-scal / d) ^ (1/3) }
        print L[1]
        print "   1.0"
        for (i = 1; i <= 3; i++) {
            strain(R[i,1]*scal, R[i,2]*scal, R[i,3]*scal)
            printf(" %12.8f %12.8f %12.8f\n", nx, ny, nz)
        }
        # species / counts / (Selective dynamics) / coordinate type
        k = 6; if (L[6] ~ /^[ \t]*[0-9]/) cl = 6; else { print L[6]; k = 7; cl = 7 }
        print L[cl]; n = split(L[cl], c, " "); nat = 0; for (i = 1; i <= n; i++) nat += c[i]
        k = cl + 1
        if (L[k] ~ /^[ \t]*[Ss]/) { print L[k]; k++ }
        print L[k]; cart = (L[k] ~ /^[ \t]*[CcKk]/)
        for (i = k + 1; i <= NR; i++) {
            if (cart && i <= k + nat) {
                n = split(L[i], f, " "); strain(f[1]*scal, f[2]*scal, f[3]*scal)
                rest = ""; for (j = 4; j <= n; j++) rest = rest " " f[j]
                printf(" %16.10f %16.10f %16.10f%s\n", nx, ny, nz, rest)
            } else print L[i]
        }
    }' POSCAR > POSCAR.deform_tmp && mv POSCAR.deform_tmp POSCAR
