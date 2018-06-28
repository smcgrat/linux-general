#!/bin/bash
# Script to automate the usual things the admins do when a node is down
# like login and run the cluster-tests or do an ipmi reset
# run by cron maybe to do so autmoatically
# documented: http://wiki.tchpc.tcd.ie/doku.php?id=self-healing-script

# Usage Notes
# -----------
# use -d flag for dry run of script where nodes are not rebooted, etc
#	./self-heal.sh -d
# use -n so the script does not power cycle nodes with ipmi no matter what
# use -m to stop the script sending email summaries

# Author
# Sean McGrath, Trinity Centre for High Performance and Research computing, smcgrat@tchpc.tcd.ie

# To do
# -----
# 1. further testing, it is cronned to run daily on the head nodes so keep an eye on that.

# States that sinfo can be set to by this script:
# ----------------------------------------------
# SH:wontpoweron - what it says on the tin
# SH:powercycled - i.e. node reset with ipmi power
# SH:clustertests - actually, I think this will be short lived as the other script that does the cluster tests changes sinfo for the node also
# SH:ECCmemory - node with ECC memory errors
# SH:ATADiskErrors - node with ATA Disk Errors
# SH:quorumnotresponding - no ping ipmi, etc
# SH:OOMquorumnode - oom'd quorum
# SH:quorumHWerror - quorum node reporting hardware errors
# SH:quorumneedstests - as above but next stage in the script says it needs to have cluster tests run on it

#-----------------------------------------------------------------------------------------------
# variables and arrays
#-----------------------------------------------------------------------------------------------

# variables
cluster=$(hostname -s | sed 's/.\{2\}$//') # assuming this is being run on the head node
timestamp=`date '+%Y-%m-%d-%H:%M:%S'`
log=/home/support/root/cluster-tools/scripts/self-heal-logs/$cluster/self-heal-$timestamp.log # log all the things
recordclustertestslogdir=/home/support/root/cluster-tools/scripts/self-heal-logs/node-test-records/$cluster/
	# `--> want to keep a record of what nodes have the cluster tests run on them and when so we can keep an eye on it
recordipmicyclelogdir=/home/support/root/cluster-tools/scripts/self-heal-logs/ipmipowercyclerecords/$cluster/
	# `--> want to keep a record of how often nodes are being power cycled
node=
operation='' # variable containing what has been done to the node for future reference
operationlog=/tmp/self-heal-node-actions.txt

# get the flags 
for flag in $@; do
	if [ "$flag" == "-d" ]; then
		dryrunmode=on
	elif [ "$flag" == "-n" ]; then
		nopowercylce=yes
	elif [ "$flag" == "-m" ]; then
		noemailsummary=yes
	elif [ "$flag" == "-f" ]; then
		overridelimit=yes
	fi
done

if [ "$overridelimit" == "yes" ]; then
	dryrunmode=off
	echo "-f flag specified. dry run disabled"
	echo "-f over rides -d and completely disables dry run"
	echo "even for the maximum limit of nodes"
fi

# arrays
declare -a nodes_with_problems
declare -a nodes_down_with_HC_errors
declare -a nodes_that_need_cluster_tests_run
declare -a nodes_that_are_draining
declare -a nodes_not_responding
declare -a nodes_with_epilog_errors

#-----------------------------------------------------------------------------------------------
# functions
#-----------------------------------------------------------------------------------------------

function quorumcheck { 
	local node=$1
	quorum_check=$(/usr/lpp/mmfs/bin/mmlscluster | grep -i quorum | grep $node)
	if [ -n "$quorum_check" ] # quorum_check var is not null, thus this node is in the quorum
	then
		quorumnode=yes
		echo "$node is a member of the quorum" 
	else
		quorumnode=no
		echo "$node is not a member of the quorum" 
	fi
}

function pingcheck {
	local node=$1
	pingtest=$(/bin/ping -c 1 "$node" | grep 'received' | awk -F',' '{ print $2 }' | awk '{ print $1 }')
	if [ "$pingtest" == "1" ] # node is pingable
	then
		pingable=yes
	else
		pingable=no
	fi
}

function sshcheck {
	local node=$1
	sshcontactable=$(/usr/bin/ssh -o ConnectTimeout=10 $node uptime | grep -i "load average")
	if [ -z "$sshcontactable" ]
	then
		sshconnection=down
	else
		sshconnection=up
	fi
}

function ipmi {
	local node=$1
	local action=$2

	# the ipmitool usage is a bit different between the clusters so need to set variables for the different versions
	case "$cluster" in
		lonsdale)
			ipmicommand="/usr/bin/ipmitool -I lanplus -H $node.ipmi -U ADMIN -f /root/ipmipass power "
			;;
		kelvin)
			ipmicommand="/usr/bin/ipmitool -I lanplus -H $node.ipmi -U root -f /root/ipmipass power "
			;;
		parsons)
			ipmicommand="/usr/bin/ipmitool -I lanplus -H $node.ipmi -U ADMIN -f /root/ipmipass power status ; /usr/bin/ipmitool -I lanplus -H $node.ipmi -U ADMIN -f ~/ipmipass power "
			# parsons needs the ipmitool command run on it twice quite often (prefix with 'power status', then run the actual command)
			;;
		*)
			echo "cluster: $cluster not a recognised cluster for this script, expecting either lonsdale, kelvin or parsons"
			echo "did we get a new cluster? cool... :-) "
			return 1
	esac

	# only want the ipmi command to be: on off reset or status 
	case "$action" in
		off|reset|on|status)
			eval $ipmicommand $action
			;;
		getstatus)
			ipmicheck=$(eval $ipmicommand status | awk '{print $NF}') # special case to get the status of the machine

			case "$ipmicheck" in
				on|off)
					ipmistatus=$ipmicheck
					;;
				*)
					ipmistatus=unknown
					;;
			esac
			;;
		*)
			echo "unexpected ipmitool command: $action supplied, expecting 1 of on off status or reset only"
			return 1
	esac
}

function ipmicycle {
	# power cycle a node with ipmi
	local node=$1
	if [ "$dryrunmode" == "on" ]; then
		local oktoipmicyclenode=no
		echo "script invoked in dry run mode - not going to power cycle $node"
		operation="$operation node not power cycle with ipmi, dry run flag - "
	elif [ "$nopowercylce" == "yes" ]; then
		local oktoipmicyclenode=no
		echo "$node - not power cycling with ipmi, script run with -n (don't ipmi power cycle) flag"
		operation="$operation node not power cycle with ipmi, no ipmi power cycle flag - "
	elif [ "$quorumnode"  == "yes" ]; then 
		# 20150310, Sean, changed scripts behaviour to power cycle quorum nodes with ipmi
		# if they're not responding to ping/ssh then they're probably not active members of the quorum so safe to work on
		echo "$node is a member of the quorum, double checking its mmgetstate status"
		# this is a quorum node so lets double check to make sure that gpfs isn't active on it
		gpfsstate=$(/usr/lpp/mmfs/bin/mmgetstate -N $node -Y | tail -1 | cut -d: -f9) # should = active if gpfs is active on the quorum node
		echo "$node mmgetstate status is showing: $gpfsstate"
		if [ "$gpfsstate" == "active" ]; then
			local oktoipmicyclenode=no
			echo "$node - gpfs is showing as active on the node, not going to power cycle it"
			supdate $node drain "SH:quorumnotresponding"
			operation="$operation quorum node not IPMI power cycled because gpfs state $gpfsstate - "
		else
			echo "$node has gpfs state of $gpfsstate, power cycling with IPMI"
			local oktoipmicyclenode=yes
		fi
	elif [ -n "$already_powercycled" ]; then  # this will be null if the node hasn't been power cycled before
		local oktoipmicyclenode=no
		echo "$node has been powercycled before as marked in sinfo:"
		echo "$full_sinfo_state"
		echo "no point in power cycling it again, updating sinfo to SH:wontpoweron"
		supdate $node drain "SH:wontpoweron"
		operation="$operation node won't power on with ipmi - "
	else
		local oktoipmicyclenode=yes
		echo "It should be OK to power cycle $node"
	fi
	
	if [ "$oktoipmicyclenode" == "yes" ]; then
		echo "$node - OK to be power cycled with IPMI, doing so"
		#ipmi $node off # commenting out to try to improve this functionality, seems the off stops it working maybe
		#sleep 10
		ipmi $node on
		sleep 10
		ipmi $node reset
		sleep 10
		recordipmicycle $node
		ipmistatus=()
		ipmi $node getstatus

		case "$ipmistatus" in
			off)
				echo "$node won't power on with ipmi, updating it in sinfo"
				supdate $node drain "SH:wontpoweron"
				;;
			on)
				echo "$node - power cycled with ipmi"
				supdate $node drain "SH:powercycled"
				;;
			*)
				echo "$node - ipmi status is unknown and needs manual intervention"
				supdate $node drain "SH:wontpoweron"
		esac
		operation="$operation ipmi power cycled node - "
	else
		echo "$node - not power cycled for above reason"
	fi
}

function supdate {
	local node=$1
	local action=$2
	local message=$3
	if [ "$dryrunmode" != "on" ]; then
		echo "marking $node as $action in sinfo"
		/usr/bin/scontrol update nodename=$node state=$action reason="$message"
	else
		echo "script invoked with dry run mode, not changing sinfo for this node"
		echo "$node would have been set to $action in sinfo with reason "$message""
	fi
}

function get_sinfo_state { # need this to make sure we don't reboot a node that is draining
	local node=$1
	full_sinfo_state=$(/usr/bin/sinfo -Rl --nodes=$node | grep $node)
	echo "$node -  checking sinfo, here is its state"
	echo "$full_sinfo_state"
	draining_state=$(/usr/bin/sinfo -n $node | grep $node | awk '{print $5}')
	draining_check=$(echo $draining_state | grep drng) # this variable will not be null if node marked as drng
	if [ -n "$draining_check" ]; then # node is draining
		echo "$node is draining - don't do anything to it"
		is_node_draining=yes
	else
		echo "$node is not draining - fire ahead"
		is_node_draining=no
	fi
	# check to see if the node has health check or epilog related errors
	hc_epilog_error=$(echo $full_sinfo_state | grep 'HC:\|ERR:')
	ecc_error=$(echo $full_sinfo_state | grep 'ECC') # if a node has ECC memory errors no point in running cluster tests etc on it
	ata_error=$(echo $full_sinfo_state | grep 'ATA Disk Error') # if a node has ATA Disk Errors no point in running cluster tests etc on it
	already_powercycled=$(echo $full_sinfo_state | grep 'SH:powercycled')
}

function nodecheck {
	local node=$1
	node_state=unknown # this is what will be returned to the calling function which will then act on it approriately (in theory at least)
	checknode=$(/usr/bin/ssh $node /root/node_check.sh -v | grep -i problem)
	if [ -n "$checknode" ]; then # check is not null, thus there is a problem 
		failure_results="$checknode" # so this data can be called easily
		node_state=failednodetests # default state to set the node to when being checked
		echo "$node failed /root/node_check.sh and has a problem(s)"
		echo ""
		echo "$node failure's are"
		echo "$failure_results"
		echo ""
		# if the only problems reported are slurm munge sssd and or oom then a quick reboot or service restart should bring this node back into service
		while read line # read in the checknode var to work on each line to see what it is
		do
			service_and_oom_check=$(echo $line | grep -i 'service\|OOM') # slurm munge and sssd all have service in their error report
				# this variable will not be null if the line contains service or OOM
			echo ""
			if [ -z "$service_and_oom_check" ]; then # line does not contain service or OOM
				quickcheck=bad
			else
				quickcheck=good
			fi
		done <<< "$checknode"
		if [ "$quickcheck" == "good" ]
		then
			echo "$node - only problems detected are OOM, slurm, munge and or sssd"
			oomcheck=$(echo $checknode | grep -i OOM) # this variable will not be null if there is an OOM error
			if [ -n "$oomcheck" ]; then # node in OOM state
				echo "$node - has suffered an OOM error and should be rebooted"
				node_state=restartthenode
			else # node has a problem with one of the above services not running
				echo "$node - 1 or more of the munge sssd and or slurm services are not running and should be restarted"
				node_state=restartservicesonnode
			fi
		else
			node_state=unknown
			echo "$node - has an unknown node state: "
			echo "$checknode"
		fi
	else # no problems reported by node_check 
		node_state=OK
	fi
}

function restartnode {
	local node=$1
	if [ "$dryrunmode" != "on" ]; then
		# make sure that a quorum node isn't being rebooted
		if [ "$quorumnode" == "no" ]; then # this is not a member of the quorum, safe to reboot
			#supdate $node idle # a job could start if we set to idle
			#/usr/bin/ssh $node /sbin/reboot
			# Warning here: 'scontrol reboot_nodes' will only work if the node is IDLE or DRAINED.
			# In particular, it won't work if the node is DOWN or if the slurm daemon is not running.
			/usr/bin/scontrol reboot_nodes $node
			echo "$node rebooting"
			operation="$operation node rebooted - "
		else # quorum node
			echo "$node is a quorum node - don't reboot"
			supdate $node drain "SH:OOMquorumnode"
			operation="$operation quorum node that needs a reboot - "
		fi
	else
		echo "$node - services not being restarted as script has been run in dry run mode"
		operation="$operation node rebooted - "
	fi
}

function restartservices { # problem detected with 1 or more of slurm sssd munge so restart them all
	local node=$1
	if [ "$dryrunmode" != "on" ]; then
		for i in munge sssd slurm
		do
			echo "$node - restarting the $i service"
			/usr/bin/ssh $node /sbin/service $i restart
			sleep 2
		done
		echo "running node_check again to see if the services have restarted OK"
		node_state=unknown # control this variable so it can be updated fully
		nodecheck $node
	else
		echo "$node - services not being restarted as script has been run in dry run mode"
	fi
	operation="$operation services restarted - "
}

function fixmultinodes {
# sinfo will return data like parsons-n[111,121,123] which need to be parsed into individual nodes
	entry=$1
	multicheck=$(echo $entry | grep '\[') # greping for [ char for hostlist type entries
	if [ -n "$multicheck" ]; then # [ present in array entry, ergo this is a multi node entry like parsons-n[111,121,123]
		allnodes=($(/home/support/apps/apps/local/64/python-hostlist-1.6/hostlist -e $entry) )
		for node in "${allnodes[@]}"; do
			nodes_with_problems=("${nodes_with_problems[@]}" "$node")
		done
	fi
}

function recordclustertests {
	# so we can monitor how often the cluster tests get run on each node
	local node=$1
	local testslog=$recordclustertestslogdir$node 
	recordclustertestslog=/tmp/recordclustertests.log # temporary log for reporting this
	entry="$node $timestamp - sinfo reason: $full_sinfo_state"
	echo $entry >> $testslog
	number=$(wc -l $testslog | awk '{print $1}') # the number of times, including this time, that the cluster tests will have been run on the node
	if [[ $number -gt 1 ]]; then # more than 1 entry, thus node tests run on this node before
		local lastran=$(tail -2 $testslog | head -1 | awk '{print $2}') # date the cluster tests where last scheduled to run on the node by self-heal.sh
		echo "$node has had cluster tests run on it by self-heal.sh $number times before, most lately: $lastran" >> $recordclustertestslog
		echo "Please see $testslog for details" >> $recordclustertestslog
		echo "$node has had cluster tests run on it by self-heal.sh $number times before, most lately: $lastran"
		echo "Please see $testslog for details"
	fi
}

function recordipmicycle {
	# so we can monitor how each node is power cycled via ipmi
	local node=$1
	local cyclelog=$recordipmicyclelogdir$node 
	recordpowercyclelog=/tmp/recordnodepowercycles.log # temporary log for reporting this
	entry="$node $timestamp - sinfo reason: $full_sinfo_state"
	echo $entry >> $cyclelog
	cyclenumber=$(wc -l $cyclelog | awk '{print $1}') # the number of times, including this time, that the node has been ipmi power cycled
	if [[ $cyclenumber -gt 1 ]]; then # more than 1 entry, thus node power cycled before
		local lastcycled=$(tail -2 $cyclelog | head -1 | awk '{print $2}') # date the node was last power cycled by self-heal.sh
		echo "$node has been ipmi power cycled by self-heal.sh $cyclenumber times before, most lately: $lastcycled" >> $recordpowercyclelog
		echo "Please see $cyclelog for details" >> $recordpowercyclelog
		echo "$node has been ipmi power cycled by self-heal.sh $cyclenumber times before, most lately: $lastcycled"
		echo "Please see $cyclelog for details" 
	fi
}

#-----------------------------------------------------------------------------------------------
# actual workflow
#-----------------------------------------------------------------------------------------------
(
# start logging

if [ "$dryrunmode" == "on" ]; then
	echo "script being invoked in dry run mode"
fi

if [ "$nopowercylce" == "yes" ]; then
	echo "script being invoked in don't power cycle nodes with ipmi mode"
fi

# check for nodes in slurm reporting a with errors 

nodes_down_with_HC_errors=($(/usr/bin/sinfo -Rl | grep ^HC: | awk '{print $NF}')) # Health Check script generated
nodes_not_responding=($(/usr/bin/sinfo -Rl | grep -i 'Not responding' | awk '{print $NF}')) # not responding nodes
nodes_with_epilog_errors=($(/usr/bin/sinfo -Rl | grep 'ERR:' | awk '{print $NF}')) # lists the nodes with epilog errors in slurm, awk is printing just the last column
nodes_powercycled_by_sh=($(/usr/bin/sinfo -Rl | grep 'SH:powercycled' | awk '{print $NF}')) # previously power cycled by the self heal script
nodes_error_prolog=($(/usr/bin/sinfo -Rl | grep 'error prolog' | awk '{print $NF}'))
nodes_unexpected_reboot=($(/usr/bin/sinfo -Rl | grep 'Node unexpectedly re' | awk '{print $NF}'))
nodes_with_problems=( ${nodes_down_with_HC_errors[@]} ${nodes_not_responding[@]} ${nodes_with_epilog_errors[@]} ${nodes_error_prolog[@]} ${nodes_powercycled_by_sh[@]} ${nodes_unexpected_reboot[@]}) # combine the relevant arrays of down nodes
nodes_that_need_cluster_tests_run=($(/usr/bin/sinfo -Rl | grep 'doautotest' | awk '{print $NF}')) # if the node is set as doautotest in slurm then run the cluster tests on it

if [ -n "$nodes_with_problems" ]; then # if there are nodes detected with relevant problems this array will not be empty
	# clean up the array to remove any entries with multiple nodes like parsons-n[111,121,123] and get the single entries in that node
	for node in "${nodes_with_problems[@]}"; do
		fixmultinodes $node
	done
	nodes_with_problems=(${nodes_with_problems[@]/*[*/}) # remove the multinode entry from the array
	echo ""
	echo "-----------------------------------------------------------"
	echo "here is the full list of nodes we have problems with so far"
	for node in "${nodes_with_problems[@]}"; do
		echo "$node"
	done
	echo ""
	echo "total = ${#nodes_with_problems[@]}" # this gets the array length of the nodes_with_problems array to give us a total
	echo ""
	echo "-----------------------------------------------------------"
	echo ""
else
	echo "No nodes with problems relevant to this script detected in sinfo"
fi

# move this after the node expansion
# dont want to work on too many nodes simultaneously, 
# i.e. scenario of cooling failure over the weekend
# nodes get shut down but then started again by self heal

# automatically set the limit to be 1/3 of the total node count, rather than hard limit
#limit=40
fraction_of_nodes=3
total_nodes=$(sinfo -o %D -h)
limit=$(echo "$total_nodes / $fraction_of_nodes" | bc)
if [ -z "$limit" ]
then
	limit=40
	echo "error getting total node count via sinfo; manually setting limit=$limit instead"
fi

#if [ "$cluster" == "lonsdale" ]; then # changing this to apply to all clusters and not just lonsdale now
if [ "$overridelimit" != "yes" ]; then # this over rides the dry run option, if -f is specified dry run is disabled in all circumstances
	if [ "${#nodes_with_problems[@]}" -gt "$limit" ]; then
		echo "more than $limit nodes in $cluster down, defaulting to dry run mode to be safe"
		dryrunmode=on
	fi
fi
#fi

# setup the summary log
echo "Short summary of what has been done by the self_heal script" >> $operationlog
echo "-----------------------------------------------------------" >> $operationlog

if [ "$dryrunmode" == "on" ]; then
	echo "script being invoked in dry run mode, actions listed here will Not be carried out" >> $operationlog
	echo "" >> $operationlog
fi

if [ "$nopowercylce" == "yes" ]; then
	echo "script being invoked in don't power cycle nodes with ipmi mode, nodes will not be power cycled by ipmi even if it says they will" >> $operationlog
	echo "" >> $operationlog
fi

echo "date and time = $timestamp" >> $operationlog
echo "cluster = $cluster" >> $operationlog
echo "full log at: $log" >> $operationlog
echo "" >> $operationlog
echo "${#nodes_with_problems[@]} problematic nodes in $cluster" >> $operationlog
echo "" >> $operationlog
echo "node - operation(s) carried out - current sinfo state" >> $operationlog
echo "" >> $operationlog

# check the nodes that are reporting issues
for node in "${nodes_with_problems[@]}"; do
	echo "-----"
	echo "$node - reporting problems in sinfo"
	quorumcheck $node # get the quorum status of this node first so it can be referenced later
	contactable=() # null this variable to start from fresh 
	get_sinfo_state $node
	operation=() # clear this variable so it can be populated from fresh
	# check to see if node is draining, don't do anything to it if it is, don't want to reboot a node or something while it is draining
	if [ "$is_node_draining" == "yes" ]; then
		# node is draining, dont want to act on it
		echo "$node is draining in sinfo - not taking any action on this node"
		nodes_that_are_draining=("${nodes_that_are_draining[@]}" "$node") # update the list of such nodes
		operation="$operation draining in sinfo, not taking any action - "
	elif [ -n "$ecc_error" ]; then # this var will not be null if there are ECC errors in sinfo for the node
		echo "$node - reporting ECC Memory errors and should be dealt with accordingly"
		supdate $node drain "SH:ECCmemory"
		operation="$operation ECC memory errors detected - "
	elif [ -n "$ata_error" ]; then # this var will not be null if there are ATA disk errors in sinfo for the node
		echo "$node - reporting ATA Disk Errors errors and should be dealt with accordingly"
		supdate $node drain "SH:ATADiskErrors"
		operation="$operation ATA Disk Errors detected - "
	else # start to test the node to see if it can be brought back to life or whatever as its not draining
		pingcheck $node
		if [ "$pingable" == "yes" ] # node is pingable, thus check if ssh connection works then
		then
			echo "$node is pingable, thus check if ssh connection works"
			sshcheck $node
			echo "ssh state = $sshconnection"
			if [ "$sshconnection" == "up" ]; then
				echo "$node is contactable via ssh"
				echo "running /root/node_check.sh on $node"
				nodecheck $node

				case "$node_state" in
					OK)
						echo "$node passed /root/node_check.sh"
						# just because a node passes the node_check doesnt mean that it is not problematic though
						# e.g. some hardware related errors marked in sinfo by the epilog may no longer be in dmesg on the node if it has rebooted
						# firstly lets see why it was marked down in slurm, the $full_sinfo_state var
						echo "checking for epilog & health check related errors: "
						if [ -n "$hc_epilog_error" ]; then # var will not be null if it has health check or epilog errors  
							echo "$node has the following status in slurm, probably marked by the epilog or health check scripts"
							echo "$full_sinfo_state "
							echo "should run cluster tests on it if its not a quorum node, excpet if the errors are ECC memory related"
							if [ "$quorumnode" == "no" ]; then # checking to see if this is a quorum node
								echo "$node is not a quorum node, adding it to the list of nodes to have the cluster tests run on them"
								nodes_that_need_cluster_tests_run=("${nodes_that_need_cluster_tests_run[@]}" ""$node)
								operation="$operation node marked for cluster tests - "
							else
								echo "$node is a quorum node and the epilog has reported hardware related errors on it"
								echo "$node needs the cluster-tests run on it but not while it is in the GPFS quorum"
								echo "updating sinfo"
								supdate $node drain "SH:quorumHWerror"
							fi
						else
							echo "should be ok to mark the node as available in sinfo so, no hardware related problems reported in slurm for this node"
							supdate $node idle
							operation="$operation node returned to service - "
						fi
						;;
					restartservicesonnode)
						echo "node_state before restart of services = $node_state"
						restartservices $node
						echo "node_state after restart of services = $node_state"
						if [ "$node_state" != "OK" ]; then # node has failed node_check again, (re-run by restartservices function), should probably run cluster tests
							echo "$node - cluster_tests.sh failed for a second time"
							cluster_test_this_node=yes # set variable to mark this node to have the cluster tests run on it
						else
							echo "$node - passed node_check on second attempt, updating sinfo to return it to service"
							supdate $node idle
						fi
						;;
					restartthenode)
						# node has OOMd and should be restarted unless it is a quorum node
						echo "$node has OOM'd and needs to be restarted unless it is a quorum node"
						#supdate $node idle # a job could start if we set to idle
						restartnode $node # restartnode wont restart quorum nodes
						;;
					*)
						 # node_check has failed, possibly for hardware, mark the node for the cluster testing
						echo "$node - needs cluster tests run on it"
						cluster_test_this_node=yes # set variable to mark this node to have the cluster tests run on it
				esac

				# now check to see if the node needs the cluster tests run on it
				if [ "$cluster_test_this_node" == "yes" ]; then # this node needs cluster tests run on it
					# now check to make sure it is not a quorum node, shouldnt run cluster tests on those
					if [ "$quorumnode" == "no" ]; then # not a quorum node and safe to run the tests
						echo "$node needs cluster tests run on it, $node not a quorum node, updating sinfo"
						nodes_that_need_cluster_tests_run=("${nodes_that_need_cluster_tests_run[@]}" "$node") # add this node to the array of nodes that the cluster tests run on it
						supdate $node drain "SH:clustertests"
						operation="$operation running cluster tests on node - "
					else # is a quorum node and unsafe to run the tests
						echo "$node is a quorum node - don't run the cluster-tests on it, marking it in sinfo"
						supdate $node drain "SH:quorumneedstests"
						operation="$operation quorum node needs cluster tests run - "
					fi
				fi
			else
				echo "$node is not contactable via ssh"
				contactable=no
			fi
		else
			echo "$node is not pingable"
			contactable=no
		fi
		# if the node isnt contactable, ssh/ipmi failures, then reset it to try to bring it back up
			if [ "$contactable" == "no" ]; then
				echo "$node is not contactable with ping/ssh, checking the ipmi status of the node"
				ipmi $node getstatus
				echo "ipmi status for $node is $ipmistatus"

				case "$ipmistatus" in
					off)
						ipmicycle $node # power cycle the node with ipmi
						;;
					on)
						echo "$node is not contacable by ping/ssh but has a power status of on with ipmi"
						echo "reseting it with ipmi to see if it will come back and the next running of this script can pick it up"
						ipmicycle $node # power cycle the node with ipmi
						;;
					*)
						# ipmi has an unknow status, probably cant communicate with it, all we can really do is double check update sinfo to say so
						echo "$node ipmi status = $ipmistatus"
						supdate $node drain "SH:communicationproblems"
						operation="$operation can't communicate with node - "
						echo "can't communicate with $node with either ping or ipmi, updating sinfo with this"
				esac
			fi
	fi
	echo ""
	echo "-----"
	echo ""
	# update the summary log with the details for this script 
	sinfo_state=$(/usr/bin/sinfo -Rl --nodes=$node | grep $node) 
	echo "$node - $operation $sinfo_state" >> $operationlog
done

# now run the cluster tests on the relevant nodes
if [ -n "$nodes_that_need_cluster_tests_run" ]; then # make sure array is not empty before doing this
	echo "Here are the nodes that need the cluster-tests run on them"
	echo ""
	# first make sure that the entries in the array are unique so we dont get multiple ones
	nodes_that_need_cluster_tests_run=$(echo $nodes_that_need_cluster_tests_run | tr ' ' '\n' | sort -nu)
	for node in "${nodes_that_need_cluster_tests_run[@]}"; do
		echo "$node"
		if [ "$dryrunmode" != "on" ]; then
			/usr/bin/ssh $node /home/support/root/cluster-tools/scripts/node-test.sh -f &
			# the f flag forces the tests even if the node_check is reporting problems
			# node-test.sh will error if there is anything other than slurm problematic without the f flag
			recordclustertests $node # keep a record of what nodes have the cluster test run on them so we can see how often they each get tested
		else
			echo "dry run mode has been invoked, will not be running cluster tests on this node"
		fi
	done
	echo ""
fi

if [ -n "$nodes_that_are_draining" ]; then # make sure array is not empty before doing this
	echo "Here are the nodes marked as draining in sinfo, taking no furhter action on those for now"
	for node in "${nodes_that_are_draining[@]}"; do
		echo "$node"
	done
	echo ""
fi

# print out the short summary log
echo ""

if [ -e "$recordclustertestslog" ]; then # append the log that records the cluster tests being run onto the operations log for reference if such a log exists
	echo "" >> $operationlog
	echo "" >> $operationlog
	cat $recordclustertestslog >> $operationlog 
	rm -f $recordclustertestslog
fi

if [ -e "$recordpowercyclelog" ]; then # append the log that records the amount of times a node is power cycled to the email alert
	echo "" >> $operationlog
	echo "" >> $operationlog
	cat $recordpowercyclelog >> $operationlog 
	rm -f $recordpowercyclelog
fi

cat $operationlog

if [ "$noemailsummary" != "yes" ]; then
	cat /tmp/self-heal-node-actions.txt | mail -s "$cluster - self-heal.sh summary - $timestamp" admins@tchpc.tcd.ie # mail the summary to the admins so we know what I have broken
fi

rm -f $operationlog # delete it so it can be recreated cleanly
echo ""

) 2>&1 | tee $log

exit 0
