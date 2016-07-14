#!/bin/bash
# get the folder sizes of a file system

if [ -z $1 ]
then
	echo "no diretory supplied as first arg, exting..."
	exit 0
fi

declare -a folders=($(ls $1))

for i in "${folders[@]}"
do
	#echo "$1/$i"
	#if [ $i != "gpfs" ] # want to avoid the gpfs fs here as its large
	#then
		du -hs $1/$i
	#fi
done

exit 0
