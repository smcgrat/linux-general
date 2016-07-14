#!/bin/bash
# Find the available IP addresses from the DNS Zone files in the tchpc.tcd.ie DNS Zones

# Sean McGrath, October 2013

# ===============
# Script Overview
# ===============
# Map the subnet ip address usage
#	create an array with 255 elements for each TCHPC subnet
#	populate it by reading the relevant reverse zone file into it with some additonal information and after excluding things like comments, etc
# for each subnet create an array for the ip's in use and the free ip's
# 	use the mapping array above as a basis for this
#	get a count of used and free ip's in each subnet this way
#	do some checking on ip addresses in use
#		- make sure there is a forward dns entry for each ip address
#		- make sure that the hostname you get by using the ip address from the reverse zone file to query dns with, then matches the ip address you get if you query dns with that hostname
# Offer to display free IP addresses for the subnets
# 
# To be wary of
#==============
# - Script only looks at the reverse zone files, so if an ip address is in use in the forward zone but not the reverse, that's problematic
#	(looking to do something about this as above)
# 
# =======================


# Begin

recordfile=/tmp/ipam.txt # create a file that will list the ip address usage in the subnets 
rm -rf $recordfile # delete the record current file so it can be re-created

echo ""
echo "TCHPC IP Addresses Usage Script"
echo ""
echo "Gathering Information, this may take a little time"
echo ""

#--------------
# Subnet Arrays
#--------------

# create the array's for each of the 134.226.x Subnet's that belong to TCHPC
# and the array should have 255 entries so we can populate it with the ip addresses in the subnet
# YES, this is ugly, sorry

start=0
repeats=255

declare -a two_net=()
declare -a three_net=()
declare -a four_net=()
declare -a five_net=()

while [ $start -lt $repeats ]; do
	two_net=("${two_net[@]}" "134.226.112.$start available")
	three_net=("${three_net[@]}" "134.226.113.$start available")
	four_net=("${four_net[@]}" "134.226.114.$start available")
	five_net=("${five_net[@]}" "134.226.115.$start available")
	let "start+=1"
done

#----------
# Functions
#----------

function map_subnet {
# function to find the ip address usage in a subnet from a zone file
# expects the zone file to be the first arguement supplied with the function call

zonefile="$1"
subnet=( ${zonefile:3:3} ) 
# from the supplied zone file figure out what subnet this is so we can out the entries into the relevant array

while read -r line
do 
	## make sure that the line is a PTR record, e.g.
		# 250		IN	PTR	cchy019.tchpc.tcd.ie. 
	# so we know we are dealing with an actual dns entry
	ptr_check=( $(echo $line | grep PTR ) )
	if [ -n "$ptr_check" ] # make sure that the ptr check var is not null 
	then
		# get the first 'word' of the string, this will be the end of the ip address where appropirate
		# and get the first character of the string to make sure it's not a ; and thus a comment
		first_word=( $(echo $line | awk '{print $1}' ) )
		first_char=( ${line:0:1} )
		if [ "$first_char" != ";" ] # i.e. is not a comment: ;
		then
			hostname=( $(host 134.226.$subnet.$first_word | awk '{print $5}') )
			if [ "$subnet" == "112" ]
			then
				two_net[$first_word]="134.226.112.$first_word in use by $hostname"
			elif [ "$subnet" == "113" ]
			then
				three_net[$first_word]="134.226.113.$first_word in use by $hostname"
			elif [ "$subnet" == "114" ]
			then
				four_net[$first_word]="134.226.114.$first_word in use by $hostname"
			else [ "$subnet" == "115" ]
				five_net[$first_word]="134.226.115.$first_word in use by $hostname"
			fi			
		fi
	fi
done < $zonefile
}

#---------
# WorkFlow
#--------- 

# Build the arrays
cd /var/named/chroot/var/named/
map_subnet db.112.226.134
map_subnet db.113.226.134
map_subnet db.114.226.134
map_subnet db.115.226.134
map_subnet db.tchpc.tcd.ie

### Get an array with the used ip address in the subnet and another array with the free ip's in the subnet for each array
# and do some checking like matching hostnames to reverse lookup ip's, etc

declare -a problems=() # an array to hold records of any issues that are picked up

# 134.226.112.
declare -a two_used=()
declare -a two_free=()
count_used_two=0
count_free_two=0
        # counters for totals
for i in "${two_net[@]}"
do
        # check the dns lookups for the ip address
	ip=( $(echo $i | awk '{print $1}') ) # create a var with just the ip address and not other text
        hostname=( $(host $ip | awk '{print $5}') )
	# check to make sure that the ip address resolves to a hostname
	lookup=( $(host $ip) ) # lookup the IP address in dns
	lookup_problem=( $(echo $lookup | grep NXDOMAIN) )
		# If the lookup fails the response will have: NXDOMAIN in it, thus that ip address does not resolve to a hostname
	if [ -n "$lookup_problem" ] # there is a lookup problem as the variable is not null
	then
		problems=("${problems[@]}" "$i -> no DNS hostname found for this IP address, i.e. host $ip returned a NXDOMAIN value")
	fi	

	# find out if the ip is in use or not and add to relevant array & increment a counter total
	check_availability=( $(echo $i | grep available) ) # find out if the ip is in use or not
        if [ -z "$check_availability" ] # var is null, i.e. ip is in use
        then
                two_used=("${two_used[@]}" "$ip") # enter it into the relevant array
		let "count_used_two+=1"
	        
		# + check that the ip address supplied by DNS is the ip address we are referrencing here from the zone file, can only do this on IP addresses that have been used
        	dns_ip=( $(host $hostname | awk '{print $4}') )
		if [ "$dns_ip" != "$ip" ]
		then
                	problems=("${problems[@]}" "$ip -> pulled from the reverse zone file for the host $hostname has a different or no ip address registered with it in DNS when you do a lookup on the hostname")
        	fi

        else
                two_free=("${two_free[@]}" "$ip")
		let "count_free_two+=1"
        fi
done

# 134.226.113.
declare -a three_used=()
declare -a three_free=()
count_used_three=0
count_free_three=0
        # counters for totals
for i in "${three_net[@]}"
do
        # check the dns lookups for the ip address
        ip=( $(echo $i | awk '{print $1}') ) # create a var with just the ip address and not other text
        hostname=( $(host $ip | awk '{print $5}') )
        # check to make sure that the ip address resolves to a hostname
        lookup=( $(host $ip) ) # lookup the IP address in dns
        lookup_problem=( $(echo $lookup | grep NXDOMAIN) )
                # If the lookup fails the response will have: NXDOMAIN in it, thus that ip address does not resolve to a hostname
        if [ -n "$lookup_problem" ] # there is a lookup problem as the variable is not null
        then
                problems=("${problems[@]}" "$i -> no DNS hostname found for this IP address, i.e. host $ip returned a NXDOMAIN value")
        fi 

        # find out if the ip is in use or not and add to relevant array
        check_availability=( $(echo $i | grep available) ) # find out if the ip is in use or not
        if [ -z "$check_availability" ] # var is null, i.e. ip is in use
        then
                three_used=("${three_used[@]}" "$ip") # enter it into the relevant array
		let "count_used_three+=1"

                # + check that the ip address supplied by DNS is the ip address we are referrencing here from the zone file, can only do this on IP addresses that have been used
		dns_ip=( $(host $hostname | awk '{print $4}') )
                if [ "$dns_ip" != "$ip" ]
                then
                        problems=("${problems[@]}" "$ip -> pulled from the reverse zone file for the host $hostname has a different or no ip address registered with it in DNS when you do a lookup on the hostname")
                fi

        else
                three_free=("${three_free[@]}" "$ip")
		let "count_free_three+=1"
        fi
done

# 134.226.114.
declare -a four_used=()
declare -a four_free=()
count_used_four=0
count_free_four=0
        # counters for totals
for i in "${four_net[@]}"
do
        # check the dns lookups for the ip address
        ip=( $(echo $i | awk '{print $1}') ) # create a var with just the ip address and not other text
        hostname=( $(host $ip | awk '{print $5}') )
        # check to make sure that the ip address resolves to a hostname
        lookup=( $(host $ip) ) # lookup the IP address in dns
        lookup_problem=( $(echo $lookup | grep NXDOMAIN) )
                # If the lookup fails the response will have: NXDOMAIN in it, thus that ip address does not resolve to a hostname
        if [ -n "$lookup_problem" ] # there is a lookup problem as the variable is not null
        then
                problems=("${problems[@]}" "$i -> no DNS hostname found for this IP address, i.e. host $ip returned a NXDOMAIN value")
        fi 

        # find out if the ip is in use or not and add to relevant array
        check_availability=( $(echo $i | grep available) ) # find out if the ip is in use or not
        if [ -z "$check_availability" ] # var is null, i.e. ip is in use
        then
                four_used=("${four_used[@]}" "$ip") # enter it into the relevant array
		let "count_used_four+=1"

                # + check that the ip address supplied by DNS is the ip address we are referrencing here from the zone file, can only do this on IP addresses that have been used
                dns_ip=( $(host $hostname | awk '{print $4}') )
                if [ "$dns_ip" != "$ip" ]
                then
                        problems=("${problems[@]}" "$ip -> pulled from the reverse zone file for the host $hostname has a different or no ip address registered with it in DNS when you do a lookup on the hostname")
                fi

        else
                four_free=("${four_free[@]}" "$ip")
		let "count_free_four+=1"
        fi
done

# 134.226.115.
declare -a five_used=()
declare -a five_free=()
count_used_five=0
count_free_five=0
        # counters for totals
for i in "${five_net[@]}"
do
        # check the dns lookups for the ip address
        ip=( $(echo $i | awk '{print $1}') ) # create a var with just the ip address and not other text
        hostname=( $(host $ip | awk '{print $5}') )
        # check to make sure that the ip address resolves to a hostname
        lookup=( $(host $ip) ) # lookup the IP address in dns
        lookup_problem=( $(echo $lookup | grep NXDOMAIN) )
                # If the lookup fails the response will have: NXDOMAIN in it, thus that ip address does not resolve to a hostname
        if [ -n "$lookup_problem" ] # there is a lookup problem as the variable is not null
        then
                problems=("${problems[@]}" "$i -> no DNS hostname found for this IP address, i.e. host $ip returned a NXDOMAIN value")
        fi 

        # find out if the ip is in use or not and add to relevant array
        check_availability=( $(echo $i | grep available) ) # find out if the ip is in use or not
        if [ -z "$check_availability" ] # var is null, i.e. ip is in use
        then
                five_used=("${five_used[@]}" "$ip") # enter it into the relevant array
		let "count_used_five+=1"

                # + check that the ip address supplied by DNS is the ip address we are referrencing here from the zone file, can only do this on IP addresses that have been used
                dns_ip=( $(host $hostname | awk '{print $4}') )
                if [ "$dns_ip" != "$ip" ]
                then
                        problems=("${problems[@]}" "$ip -> pulled from the reverse zone file for the host $hostname has a different or no ip address registered with it in DNS when you do a lookup on the hostname")
                fi

        else
                five_free=("${five_free[@]}" "$ip")
		let "count_free_five+=1" 
       fi
done

# add all the totals together to get grand totals for free and used ip address numbers
total_used=$(($count_used_two + $count_used_three + $count_used_four + $count_used_five))
total_free=$(($count_free_two + $count_free_three + $count_free_four + $count_free_five))

#----------------------------------
# Write the info to the record file
#----------------------------------

### Record all the usage in the subnet's
echo "TCHPC IP Addresses Usage" >> $recordfile
echo "========================" >> $recordfile
echo "" >> $recordfile
        date=`date`
echo "($date)" >> $recordfile
echo "" >> $recordfile
echo "Total number of Used IP Addresses = $total_used" >> $recordfile
echo "Total number of Free IP Addresses = $total_free" >> $recordfile
echo "" >> $recordfile

echo "134.226.112.x - Subnet - $count_used_two ip's used || $count_free_two ip's free" >> $recordfile
echo "======================================================" >> $recordfile
for i in "${two_net[@]}"; do echo $i >> $recordfile; done
echo "">> $recordfile

echo "134.226.113.x - Subnet - $count_used_three ip's used || $count_free_three ip's free" >> $recordfile
echo "======================================================" >> $recordfile
for i in "${three_net[@]}"; do echo $i >> $recordfile; done
echo "">> $recordfile

echo "134.226.114.x - Subnet - $count_used_four ip's used || $count_free_four ip's free" >> $recordfile
echo "======================================================" >> $recordfile
for i in "${four_net[@]}"; do echo $i >> $recordfile; done
echo "">> $recordfile

echo "134.226.115.x - Subnet - $count_used_five ip's used || $count_free_five ip's free" >> $recordfile
echo "======================================================" >> $recordfile
for i in "${five_net[@]}"; do echo $i >> $recordfile; done
echo "" >> $recordfile

echo "Data has been written to $recordfile"
echo ""

#--------------------------------------------------------------
# Print free ip addresses in each subnet if the user wants them
#--------------------------------------------------------------


waitperiod="60" # will wait 30 secs for input to display free ip's by subnet, otherwise don't and move on
	# Example 9-3 from  http://tldp.org/LDP/abs/html/internalvariables.html

#function timeout_read {
#	timeout=$1
#	varname=$2
#	old_tty_settings=`stty -g`
#	stty -icanon min 0 time ${timeout}0
#	eval read $varname      # or just  read $varname
#	stty "$old_tty_settings"
#}

#echo; echo "Would you like to list free IP addresses by subnet, will wait for answer for 30 seconds, (y/n)? "
#timeout_read $waitperiod display_subnets

read -t $waitperiod -p "Would you like to list free IP addresses by subnet (y/n)? "

if [ "$display_subnets" == "y" ]
then
	echo ""
	echo "Checking free IP's in the subnets"
	echo ""

	read -p "Display the $count_free_two free ip addresses in 134.226.112.x (y/n)? "
	if [ $REPLY == "y" ]
	then
	echo ""
        echo "134.226.112.x free addresses"
        echo "============================" 
                for i in "${two_free[@]}"; do echo "$i"; done
        echo ""
	fi

        read -p "Display the $count_free_three free ip addresses in 134.226.113.x (y/n)? "
        if [ $REPLY == "y" ]
        then
	echo ""
        echo "134.226.113.x free addresses"
        echo "============================" 
                for i in "${three_free[@]}"; do echo "$i"; done
        echo ""
        fi

        read -p "Display the $count_free_four free ip addresses in 134.226.114.x (y/n)? "
        if [ $REPLY == "y" ]
        then
	echo ""
        echo "134.226.114.x free addresses"
        echo "============================" 
                for i in "${four_free[@]}"; do echo "$i"; done
        echo ""
        fi

        read -p "Display the $count_free_five free ip addresses in 134.226.115.x (y/n)? "
        if [ $REPLY == "y" ]
        then
	echo ""
        echo "134.226.115.x free addresses"
        echo "============================" 
                for i in "${five_free[@]}"; do echo "$i"; done
        echo ""
        fi

# To display the used ip's in a subnet, replace the SUBNET placeholder in the below command with either two three four or five as needed

# echo "  134.226.11x.x $count_used_SUBNET ip's used"
# echo "  ==========================="
# for i in "${SUBNET_used[@]}"; do echo "$i"; done
#        echo ""
# 

else
	echo "Moving on without checking free ip addresses in each subnet, please see $recordfile for used and available ip addresses"
fi

#-----------------
# Problem Checking
#-----------------
echo ""
echo "Checking for Problems"
echo "====================="
echo "Looking for:"
echo "- No forward DNS record associated with an IP address, i.e. host 134.226.112.x comes back with an NXDOMAIN error"
echo "- Make sure that when you do a 'host ipaddress' to get a hostname on an ip pulled from a zone file, that doing a 'host hostname' gives you back the same ip address you started with"
echo ""
echo "Some issues will be have to be ignored, (e.g. kelvin has multiple public ip addresses & dig and host seem to trunctuate long hostname strings):"
echo ""

# list of ip addresses to 'ignore'
declare ignored_list=(134.226.114.130)
# advise that these potential problems are being ignored though
for ignored in "${ignored_list[@]}"; do hostname=`host $ignored | awk '{print $5}'`; echo "ignoring: $ignored; $hostname for a good reason"; done

echo ""
echo "Found the following problems"
echo "  (If blank then none detected)"
echo "--------------------------------------------------"
echo ""

for problem in "${problems[@]}" # problesm array populated above with issues, now we need to check if any of the problems are to be ignored
do
	# figure out if we should advise of this problem
	report="yes" # default is to report 
	for toignore in "${ignored_list[@]}"
	do
		ignore_check=()
		ignore_check=( $(echo "$problem" | grep "$toignore" | awk '{print $1}') )
		if [ -n "$ignore_check" ] # string is not null, i.e. the to be ignored ip address is present in the $problem string
		then
			report=()
			report="no"
		fi
	done
	# advise of problem as appropriate
	if [ "$report" == "yes" ]
	then
		echo "$problem"
	fi
done

echo ""
echo "--------------------------------------------------"
echo ""

echo "Have you taken note of the possible problems above?"

echo ""
echo "Log file: $recordfile"
echo ""
echo "IP Address Usage check complete"
echo ""

exit 0
