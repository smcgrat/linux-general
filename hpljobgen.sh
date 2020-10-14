#!bin/bash

usage() {
echo "Wrapper for submitting HPL Jobs"
cat <<EOF
Creates a specific directory called NxNB
And writes the HPL.dat & slurm submission script to it.
Flags, (mandatory)
	-h number of nodes
	-n N value
	-b NB value
	-p P value
	-q Q value
Flags, (optional)
	-t time limit in format 4-00:00:00 days-hours:mins:secs
EOF
}

# get the flags
while getopts "h:n:b:p:q:t:" OPTION
do
	case $OPTION in
		h)
			nodecount=$OPTARG
			;;
		n)
			N=$OPTARG
			;;
		b)
			NB=$OPTARG
			;;
		p)
			P=$OPTARG
			;;
		q)
			Q=$OPTARG
			;;
		t)
			time=$OPTARG
			;;
		?)
			usage
			exit
			;;
	esac
done

# sanity checks
if [ -z "$nodecount" ]; then
	echo "nodecount can't be blank - exiting"
	usage
	exit 1
fi

if [ -z "$N" ]; then
	echo "N can't be blank - exiting"
	usage
	exit 1
fi

if [ -z "$NB" ]; then
	echo "NB can't be blank - exiting"
	usage
	exit 1
fi

if [ -z "$P" ]; then
	echo "P can't be blank - exiting"
	usage
	exit 1
fi

if [ -z "$Q" ]; then
	echo "Q can't be blank - exiting"
	usage
	exit 1
fi

# workflow
dir="$N""x""$NB"
echo "building HPL job for $nodecount with N= $N and NB= $NB in the directory $dir"
mkdir $dir

echo "Creating $dir/run.sh"
cat <<EOF > "$dir/run.sh"
#!/bin/bash
#SBATCH -N $nodecount
#SBATCH -J $nodecount-hpl
#SBATCH -t $time

module load hpl-2.3-gcc-9.2.0-4ks5uw3
module load apps openmpi

Ns=$(grep Ns HPL.dat | grep -v NBMINs | awk '{print $1}')
NBs=$(grep NBs HPL.dat | grep -v '# of NBs' | awk '{print $1}')
echo "========================="
echo "$nodecount node job"
echo "Ns = $N"
echo "NBs = $NB"
echo "========================="

mpirun xhpl | tee HPL-Ns.$N-NBs.$NB-$(date +%F_%T).out

EOF
echo "contents of $dir/run.sh"
echo ""
cat $dir/run.sh
echo ""
read -p "Do you want to continue (y/n)? "
if [ $REPLY != "y" ]; then
	echo "exiting without doing anything"
fi

echo "Creating $dir/HPL.dat"
cat <<EOF > $dir/HPL.dat
HPLinpack benchmark input file
Innovative Computing Laboratory, University of Tennessee
HPL.out      output file name (if any)
6            device out (6=stdout,7=stderr,file)
1            # of problems sizes (N)
$N       Ns
1            # of NBs
$NB          NBs
0            PMAP process mapping (0=Row-,1=Column-major)
1            # of process grids (P x Q)
$P           Ps
$Q           Qs
16.0         threshold
3            # of panel fact
0 1 2        PFACTs (0=left, 1=Crout, 2=Right)
2            # of recursive stopping criterium
2 4          NBMINs (>= 1)
1            # of panels in recursion
2            NDIVs
3            # of recursive panel fact.
0 1 2        RFACTs (0=left, 1=Crout, 2=Right)
1            # of broadcast
0            BCASTs (0=1rg,1=1rM,2=2rg,3=2rM,4=Lng,5=LnM)
1            # of lookahead depth
0            DEPTHs (>=0)
2            SWAP (0=bin-exch,1=long,2=mix)
64           swapping threshold
0            L1 in (0=transposed,1=no-transposed) form
0            U  in (0=transposed,1=no-transposed) form
1            Equilibration (0=no,1=yes)
8            memory alignment in double (> 0)
EOF

echo ""
echo "Contents of $dir/HPL.dat"
echo ""
cat $dir/HPL.dat
echo ""
if [ $REPLY != "y" ]; then
	echo "exiting without doing anything"
fi
echo ""

read -p "Do you want to submit these to the queue (y/n)? "
if [ $REPLY == "y" ]; then
	echo "submitting to the queue"
	sbatch $dir/run.sh
else
	echo "not submitting to the queue"
fi
exit 0
