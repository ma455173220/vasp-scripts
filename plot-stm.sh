#!/bin/bash

if [ $# -ne 1 ]; then
  echo "Usage: $0 <number>"
  exit 1
fi

re='^[0-9]+([.][0-9]+)?$'
if ! [[ $1 =~ $re ]]; then
  echo "Error: Argument must be a number"
  exit 1
fi

echo -e "325\n1\n$1\n1 1"| vaspkit
tsz -y *.jpg
