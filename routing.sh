#!/bin/bash
### BEGIN INIT INFO
# Provides:          apache2
# Required-Start:    $local_fs $remote_fs $network $syslog $named
# Required-Stop:     $local_fs $remote_fs $network $syslog $named
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# X-Interactive:     true
# Short-Description: Start/stop apache2 web server
### END INIT INFO
#
#
#  Set up multi path routing along with connection marking
#  to emulate the good old route cache of earlier kernels.
#  There seems to be a bug in ifup to do with vlans.  I hacked the if-pre-up.d/vlan script to just exit 0 at the top.

DEBUG=true
SLEEP=5

BYPASS_MODE=false

function log() {
  local SEP=""
  if [ "$DEBUG" = true ]; then
    for i in `seq 1 $2`;
    do
      SEP+="\t"
    done
    LOGSTR=`echo -e "$SEP"`
    logger "$1"
    echo -e $3 "$LOGSTR$1"
  fi
}


if [ $EUID -gt 0 ]; then
  echo "This script needs to run as root."
  exit 1
fi



function is_interface_up() {
  local RETRIES=5
  local LINK=1
  local COUNT=0
  for i in `seq 1 $RETRIES`;
  do
    let COUNT=COUNT+1
    ifconfig $1 > /dev/null 2>&1
    local STATUS=$?
    if [ $STATUS -eq 0 ]; then
        log "Interface $1 *is* up" $2
        LINK=0
        break
    else
      log "Interface $1 is not active.  Waiting and checking again... ($COUNT/$RETRIES)" $2 -n
      sleep $SLEEP
    fi
  done
  return $LINK
}

function get_interface_ip() {
  local RETRIES=5
  local COUNT=0
  local INTERFACE=$1
  local GOTIP=1
  for i in `seq 1 $RETRIES`;
  do
    let COUNT=COUNT+1
    IPADDR=`ip addr show dev $INTERFACE | awk -F'[ /]*' '/inet /{print $3}'`
    if [ ${#IPADDR} -lt 6 ]; then
      log "No IP found.  Waiting and checking again... ($COUNT/$RETRIES)" $2 -n
      sleep $SLEEP
    else
      log "Found IP: $IPADDR" $2
      GOTIP=0
      break
    fi
  done
  return $GOTIP
}


function get_ppp_gateway() {
  local RETRIES=5
  local COUNT=0
  local INTERFACE=$1
  local GOTIP=1
  for i in `seq 1 $RETRIES`;
  do
    let COUNT=COUNT+1
    GWADDR=`ip addr show dev $INTERFACE | awk -F'[ /]*' '/inet /{print $5}'`
    if [ ${#GWADDR} -lt 6 ]; then
      log "\nNo IP found.  Waiting and checking again... ($COUNT/$RETRIES)" $2
      sleep $SLEEP
    else
      log "Found GW: $GWADDR" $2
      GOTIP=0
      break
    fi
  done
  return $GOTIP
}

function get_dhcpclient_gateway() {
  #  Attempts to recover the default gateway provided by the DHCP server
  #  from the leases file, not from the current routing table.  This is
  #  because the current routing table could have been editied by this script
  #  already and not be valid.  The last entry in the leases file should be
  #  the one we want.
  local leaserouter=`tac /var/lib/dhcp/dhclient.$1.leases | grep router -m 1`
  DHCPGW=`echo $leaserouter | awk -F'[; ]' '{ print $3 }'`
  return 0
}

function get_ips_for_hostname(){
  # echo the ip addresses for a hostname
  local ips=`host $1 | grep "has address" | awk '{print $4}'`
  echo "$ips"
}

function add_to_routing_table(){
  log "Adding static routes for $1 via $3" 2
  local hostname=$1
  local table=$2
  local interface=$3
  get_interface_ip $interface
  local interface_ip=$IPADDR
  for ip in `get_ips_for_hostname $1`;
  do
    log "Host: $1  IP: $ip" 3
    ip route add $ip via $interface_ip dev $interface table $table
  done
  log "Done" 0
}

log "Starting router setup script..." 0

if [ "$BYPASS_MODE" = true ]; then
log "Running in bypass mode..." 0
BYPASS_INT="eth0"
BYPASS_STATUS=false

log "Checking to see if $BYPASS_INT is available..." 0
is_interface_up $BYPASS_INT
if [ $? = 0 ]; then
  log "Checking $BYPASS_INT for an IP address..." 1 -n
  get_interface_ip $BYPASS_INT 1
  if [ $? = 0 ]; then
    BYPASS_IPADDR=$IPADDR
    log "got $BYPASS_IPADDR" 1
    get_dhcpclient_gateway $BYPASS_INT
    if [ $? = 0 ]; then
      log "Got DHCP gateway IP: $DHCPGW" 1
      log "Creating Bypass routing table" 1
      ##ip route del default table talktalk > /dev/null 2>&1
      ## This was from when we had a talktalk router.  Need to change this to support direct connection now
      #ip route add default via 192.168.1.254 dev $BTINT src 192.168.1.253 table talktalk
      ip route add default via $DHCPGW dev eth0 src $BYPASS_IPADDR
      BTINT_STATUS=true
      log "Adding dynamic iptables rules..." 0
      iptables -t nat -A POSTROUTING -o $BYPASS_INT -j SNAT --to-source $BYPASS_IPADDR

      log "Finished setting up route for bypass mode.  Restarting DHCP" 0
      /etc/init.d/dnsmasq restart
      log "Routing script is finished." 0
      exit 0
    fi
  fi
fi

exit 0
fi


# Load iptables rules.
# It's easier to manage the rules in a seperate file and then use iptables-restore
# to load them because it takes care of clearing all the old rules for you.
log "Loading IP tables rules..." 0
iptables-restore /home/pi/iptables/iptables.save
# Also need to add some dynamic rules to take in to account the changing BT address
# This needs to be done after we know our IP address, not here.

# Get the local gateway address for the PPPoE connection
# This can change even though the WAN IP address is static.
PLUSNETINT="ppp1"
PLUSNETINT_STATUS=false

log "Checking to see if $PLUSNETINT is up..." 0 -n
is_interface_up $PLUSNETINT 1
if [ $? = 0 ]; then
  log "Getting addresses for $PLUSNETINT..." 0
  get_ppp_gateway $PLUSNETINT 2
  get_interface_ip $PLUSNETINT 2
  PLUSNET_IPADDR=$IPADDR
  PLUSNET_GW=$GWADDR
  if [ $? = 0 ]; then
    log "Creating Plusnet routing table" 0
    ip route del default table plusnet > /dev/null 2>&1
    ip route add default via $PLUSNET_GWADDR dev $PLUSNETINT src $PLUSNET_IPADDR table plusnet
    PLUSNETINT_STATUS=true
  fi
fi

# Do the same for the BT interface which has a dynamic IP
BTINT="ppp2"
BTINT_STATUS=false

log "Checking to see if $BTINT is up..." 0 -n
is_interface_up $BTINT 1
if [ $? = 0 ]; then
  log "Getting addresses for $BTINT..." 0
  get_ppp_gateway $BTINT 2
  get_interface_ip $BTINT 2
  BT_IPADDR=$IPADDR
  BT_GW=$GWADDR
  if [ $? = 0 ]; then
    log "Creating BT routing table" 0
    ip route del default table bt > /dev/null 2>&1
    ip route add default via $BT_GW dev $BTINT src $BT_IPADDR table bt
    BTINT_STATUS=true
  fi
fi

# Create the load balanced routing table now
ip route del default table loadbal > /dev/null 2>&1
if [[ "$BTINT_STATUS" == "true" && "$PLUSNETINT_STATUS" == "true" ]]; then
  ip route add default table loadbal nexthop via $PLUSNET_GW dev $PLUSNETINT weight 1 nexthop via $BT_GW dev $BTINT weight 1
elif [[ "$BTINT_STATUS" == "true" && "$PLUSNETINT_STATUS" == "false" ]]; then
  ip route add default table loadbal via $BT_GW dev $BTINT weight 1
elif [[ "$BTINT_STATUS" == "false" && "$PLUSNETINT_STATUS" == "true" ]]; then
  ip route add default table loadbal via $PLUSNET_GQ dev $PLUSNETINT
else
  log "Meh - something went wrong.  Bad luck." 0
  exit 1
fi

# Create the ip rules
# ip rule add from 10.222.21.12 table plusnet pref 40100
log "Creating the rules tables..." 0
ip rule del pref 39900 > /dev/null 2>&1
ip rule del pref 40000 > /dev/null 2>&1
ip rule del pref 40100 > /dev/null 2>&1
ip rule del pref 40200 > /dev/null 2>&1
ip rule del pref 40300 > /dev/null 2>&1
ip rule del pref 40400 > /dev/null 2>&1

ip rule add from all table vpn_hubert pref 39900
ip rule add from $PLUSNET_IPADDR table plusnet pref 40000
ip rule add from $BT_IPADDR table bt pref 40100
ip rule add fwmark 0x1 table plusnet pref 40200
ip rule add fwmark 0x2 table bt pref 40300
ip rule add from 0/0 table loadbal pref 40400


# Add static routes here for the *main* table
# Don't have to use the main table but it makes it a bit easier to find.
log "Creating static routing entries..." 0
log "Hubert" 2
# Make sure that the VPN always takes the same route, makes it easier to add a firewall rule
ip route add 104.131.59.210 via $PLUSNET_GW dev $PLUSNETINT table main
log "voip.canonical.com" 2
add_to_routing_table voip.canonical.com main $PLUSNETINT
log "sipgate.co.uk" 2
add_to_routing_table sipgate.co.uk main $PLUSNETINT

log "Done with static routes."

log "Pausing to give VPNs a chance to start and connect...." 0
for i in `seq 10 -1 1`
do
  log $i 1 -n
  sleep 1
done
log ".. carry on." 0

# Add dynamic iptables rules now since we should know all our IP addresses at this point
#[0:0] -A POSTROUTING -o eth0 -j SNAT --to-source 92.18.127.108
log "Adding dynamic iptables rules..." 0
iptables -t nat -A POSTROUTING -o $BTINT -j SNAT --to-source $BT_IPADDR

# Add static routes to the VPN tables
log "Setting up VPN routes..." 0
is_interface_up tun0 1
if [ $? = 0 ]; then
  log "Adding Firewall and NAT rules..." 1
  iptables -t filter -A FORWARD -i eth1 -o tun0 -j LAN_WAN
  iptables -t nat -A POSTROUTING -o tun0 -j SNAT --to-source 10.8.0.10
  log "Adding custom routes..." 1
  add_to_routing_table thepiratebay.org vpn_hubert tun0
else
  log "Interface tun0 not up. Can't add static routes" 1
fi

log "Done" 0



# Re-direct Google DNS to this machine for Netflix clients and direct Netflix clients
# out of a single route (so that Unblock US works properly)
# Only required for Chromecasts, but meh
#log "Creating the Netflix hacks..." 0
#NETFLIX=plusnet
#START_NETFLIX_RANGE=51
#END_NETFLIX_RANGE=70
#START_PREF=38000

#while [ $START_NETFLIX_RANGE -le $END_NETFLIX_RANGE ]
#do
#  log "Doing 192.168.42.$START_NETFLIX_RANGE" 1
#  ip rule del prio $START_PREF > /dev/null 2>&1
#  ip rule add from 192.168.42.$START_NETFLIX_RANGE table $NETFLIX prio $START_PREF
#  iptables -t nat -D PREROUTING -s 192.168.42.$START_NETFLIX_RANGE/32 -d 8.8.8.8 -p udp --dport 53 -j DNAT --to 192.168.42.254 > /dev/null 2>&1
#  iptables -t nat -D PREROUTING -s 192.168.42.$START_NETFLIX_RANGE/32 -d 8.8.4.4 -p udp --dport 53 -j DNAT --to 192.168.42.254 > /dev/null 2>&1
#  iptables -t nat -D PREROUTING -s 192.168.42.$START_NETFLIX_RANGE/32 -d 208.67.222.222 -p udp --dport 53 -j DNAT --to 192.168.42.254 > /dev/null 2>&1
#  iptables -t nat -D PREROUTING -s 192.168.42.$START_NETFLIX_RANGE/32 -d 209.244.0.3 -p udp --dport 53 -j DNAT --to 192.168.42.254 > /dev/null 2>&1
#  iptables -t nat -A PREROUTING -s 192.168.42.$START_NETFLIX_RANGE/32 -d 8.8.8.8 -p udp --dport 53 -j DNAT --to 192.168.42.254
#  iptables -t nat -A PREROUTING -s 192.168.42.$START_NETFLIX_RANGE/32 -d 8.8.4.4 -p udp --dport 53 -j DNAT --to 192.168.42.254
#  iptables -t nat -A PREROUTING -s 192.168.42.$START_NETFLIX_RANGE/32 -d 208.67.222.222 -p udp --dport 53 -j DNAT --to 192.168.42.254
#  iptables -t nat -A PREROUTING -s 192.168.42.$START_NETFLIX_RANGE/32 -d 209.244.0.3 -p udp --dport 53 -j DNAT --to 192.168.42.254
#  START_NETFLIX_RANGE=$[$START_NETFLIX_RANGE+1]
#  START_PREF=$[$START_PREF+10]
#done

log "Removing main default route..." 0
ip route del default > /dev/null 2>&1


#  This is a dirty hack.  Because the IP address associated with the PPP interface
#  takes a little while to start and is not guaranteed to ever exist we edit the config file
#  to take the status of this interface in to account.  SSHD won't start if *all* of the
#  interfaces it needs to bind to are not up.  This means we can't rely on init starting SSH sucessfully.
#  Which leaves us stranded on a headless box as we can't ssh in to fix it.


SSHPORT=801
log "Sorting out SSHD..." 0
if [ "$PLUSNETINT_STATUS" = "true" ]; then
  log "PPP interface is up.  Enabling SSH on $PLUSNETINT" 1
  sed -i "s/^#-PPP-INT-GOES-HERE.-AUTOMATICALLY-EDITED-DO-NOT-CHANGE-THIS-LINE-#$/ListenAddress $PLUSNET_IPADDR:$SSHPORT/g" /etc/ssh/sshd_config
fi
log "Restarting SSH..." 1
/etc/init.d/ssh restart
log "Restarting DNSMASQ..." 1
/etc/init.d/dnsmasq restart

log "Reverting changes in file for next boot..." 1
## Safe to do this anyway, because it will only match the exact string from above or do nothing
SED_ARG="s/^ListenAddress $PLUSNET_IPADDR:$SSHPORT$/#-PPP-INT-GOES-HERE.-AUTOMATICALLY-EDITED-DO-NOT-CHANGE-THIS-LINE-#/g"
eval sed -i \"$SED_ARG\" /etc/ssh/sshd_config

log "Spreading network queues across cores..." 0
if [ "$BTINT_STATUS" = true ]; then
  echo 1 > /sys/class/net/eth0/queues/rx-0/rps_cpus
  echo 1 > /sys/class/net/eth0/queues/tx-0/xps_cpus
fi
echo 2 > /sys/class/net/eth1/queues/tx-0/xps_cpus
echo 2 > /sys/class/net/eth1/queues/rx-0/rps_cpus
echo 4 > /sys/class/net/eth1.1000/queues/tx-0/xps_cpus
echo 4 > /sys/class/net/eth1.1000/queues/rx-0/rps_cpus
echo 8 > /sys/class/net/ppp1/queues/tx-0/xps_cpus
echo 8 > /sys/class/net/ppp1/queues/rx-0/rps_cpus

log "And we are done." 0
exit 0

