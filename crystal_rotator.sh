#!/bin/sh

# Prompt the user to input rotated atom index
read -p "Enter rotation_atom: " rotation_atom

# Prompt the user to input rotation_vector
read -p "Enter rotation_vector (e.g., -1 1 1): " rotation_vector

# Prompt the user to input rotation_origin (in Cartesian coordinates)
read -p "Enter rotation_origin (e.g., 7 7 7): " rotation_origin

# Prompt the user to input rotation_angle
read -p "Enter rotation_angle (e.g., -120): " rotation_angle

# Print the entered parameters
echo "You entered:"
echo "Rotation Atom: $rotation_atom"
echo "Rotation Vector: $rotation_vector"
echo "Rotation Origin: $rotation_origin"
echo "Rotation Angle: $rotation_angle"

# Define the crystal_rotate function here, using the user's input
crystal_rotate () {
    echo -e "408\n175 POSCAR\n1\n$rotation_atom\n4\n$rotation_vector\n$rotation_origin\n$rotation_angle\n175\n" | atomkit
}

# Call the crystal_rotate function
crystal_rotate

