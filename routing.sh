#!/bin/bash
#
#
#  Set up multi path routing along with connection marking
#  to emulate the good old route cache of earlier kernels.
#  There seems to be a bug in ifup to do with vlans.  I hacked the if-pre-up.d/vlan script to just exit 0 at the top.

DEBUG=true
SLEEP=5


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
      log "\nInterface $1 is not active.  Waiting and checking again... ($COUNT/$RETRIES)" $2 -n
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
      log "\nNo IP found.  Waiting and checking again... ($COUNT/$RETRIES)" $2 -n
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




# Load iptables rules.
# It's easier to manage the rules in a seperate file and then use iptables-restore
# to load them because it takes care of clearing all the old rules for you.
log "Loading IP tables rules..." 0
iptables-restore /home/pi/iptables/iptables.save


# Get the local gateway address for the PPPoE connection
# This can change even though the WAN IP address is static.
PPPINT="ppp1"
PPPINT_STATUS=false

log "Checking to see if $PPPINT is up..." 0 -n
is_interface_up $PPPINT 1
if [ $? = 0 ]; then
  log "Getting addresses for $PPPINT..." 0
  get_ppp_gateway $PPPINT 2
  get_interface_ip $PPPINT 2
  PPP_IPADDR=$IPADDR
  if [ $? = 0 ]; then
    log "Creating Plusnet routing table" 0
    ip route del default table plusnet > /dev/null 2>&1
    ip route add default via $GWADDR dev $PPPINT src $PPP_IPADDR table plusnet
    PPPINT_STATUS=true
  fi
fi

# Do the same for the TalkTalk interface which has a fixed IP
TTINT="eth0"
TTINT_STATUS=false

log "Checking to see if $TTINT is available..." 0
is_interface_up $TTINT
if [ $? = 0 ]; then
  log "Checking $TTINT for an IP address..." 1 -n
  get_interface_ip $TTINT 1
  if [ $? = 0 ]; then
    TT_IPADDR=$IPADDR
    log "got $TT_IPADDR" 1
    log "Creating TalkTalk routing table" 1
    ip route del default table talktalk > /dev/null 2>&1
    ip route add default via 192.168.1.254 dev $TTINT src 192.168.1.253 table talktalk
    TTINT_STATUS=true
  fi
fi

# Create the load balanced routing table now
ip route del default table loadbal > /dev/null 2>&1
if [[ "$TTINT_STATUS" == "true" && "$PPPINT_STATUS" == "true" ]]; then
  ip route add default table loadbal nexthop via $GWADDR dev $PPPINT weight 1 nexthop via 192.168.1.254 dev $TTINT weight 1
elif [[ "$TTINT_STATUS" == "true" && "$PPPINT_STATUS" == "false" ]]; then
  ip route add default table loadbal via 192.168.1.254 dev $TTINT weight 1
elif [[ "$TTINT_STATUS" == "false" && "$PPPINT_STATUS" == "true" ]]; then
  ip route add default table loadbal via $GWADDR dev $PPPINT
else
  log "Meh - something went wrong.  Bad luck." 0
  exit 1
fi

# Create the ip rules
# ip rule add from 10.222.21.12 table plusnet pref 40100
log "Creating the rules tables..." 0
ip rule del pref 40000 > /dev/null 2>&1
ip rule del pref 40100 > /dev/null 2>&1
ip rule del pref 40200 > /dev/null 2>&1
ip rule del pref 40300 > /dev/null 2>&1
ip rule del pref 40400 > /dev/null 2>&1
ip rule add from $PPP_IPADDR table plusnet pref 40000
ip rule add from 192.168.1.253 table talktalk pref 40100
ip rule add fwmark 0x1 table plusnet pref 40200
ip rule add fwmark 0x2 table talktalk pref 40300
ip rule add from 0/0 table loadbal pref 40400



# Re-direct Google DNS to this machine for Netflix clients and direct Netflix clients
# out of a single route (so that Unblock US works properly)
# Only required for Chromecasts, but meh

log "Creating the Netflix hacks..." 0
NETFLIX=plusnet
START_NETFLIX_RANGE=51
END_NETFLIX_RANGE=60
START_PREF=38000

while [ $START_NETFLIX_RANGE -le $END_NETFLIX_RANGE ]
do
  log "Doing 192.168.42.$START_NETFLIX_RANGE" 1
  ip rule del prio $START_PREF > /dev/null 2>&1
  ip rule add from 192.168.42.$START_NETFLIX_RANGE table $NETFLIX prio $START_PREF
  iptables -t nat -D PREROUTING -s 192.168.42.$START_NETFLIX_RANGE/32 -d 8.8.8.8 -p udp --dport 53 -j DNAT --to 192.168.42.254 > /dev/null 2>&1
  iptables -t nat -D PREROUTING -s 192.168.42.$START_NETFLIX_RANGE/32 -d 8.8.4.4 -p udp --dport 53 -j DNAT --to 192.168.42.254 > /dev/null 2>&1
  iptables -t nat -D PREROUTING -s 192.168.42.$START_NETFLIX_RANGE/32 -d 208.67.222.222 -p udp --dport 53 -j DNAT --to 192.168.42.254 > /dev/null 2>&1
  iptables -t nat -D PREROUTING -s 192.168.42.$START_NETFLIX_RANGE/32 -d 209.244.0.3 -p udp --dport 53 -j DNAT --to 192.168.42.254 > /dev/null 2>&1
  iptables -t nat -A PREROUTING -s 192.168.42.$START_NETFLIX_RANGE/32 -d 8.8.8.8 -p udp --dport 53 -j DNAT --to 192.168.42.254
  iptables -t nat -A PREROUTING -s 192.168.42.$START_NETFLIX_RANGE/32 -d 8.8.4.4 -p udp --dport 53 -j DNAT --to 192.168.42.254
  iptables -t nat -A PREROUTING -s 192.168.42.$START_NETFLIX_RANGE/32 -d 208.67.222.222 -p udp --dport 53 -j DNAT --to 192.168.42.254
  iptables -t nat -A PREROUTING -s 192.168.42.$START_NETFLIX_RANGE/32 -d 209.244.0.3 -p udp --dport 53 -j DNAT --to 192.168.42.254
  START_NETFLIX_RANGE=$[$START_NETFLIX_RANGE+1]
  START_PREF=$[$START_PREF+1]
done

log "Removing main default route..." 0
ip route del default > /dev/null 2>&1


#  This is a dirty hack.  Because the IP address associated with the PPP interface
#  takes a little while to start and is not guaranteed to ever exist we edit the config file
#  to take the status of this interface in to account.  SSHD won't start if *all* of the
#  interfaces it needs to bind to are not up.  This means we can't rely on init starting SSH sucessfully.
#  Which leaves us stranded on a headless box as we can't ssh in to fix it.

log "Sorting out SSHD..." 0
if [ "$PPPINT_STATUS" = "true" ]; then
  log "PPP interface is up.  Enabling SSH on $PPPINT" 1
  sed -i "s/^#-PPP-INT-GOES-HERE.-AUTOMATICALLY-EDITED-DO-NOT-CHANGE-THIS-LINE-#$/ListenAddress $PPP_IPADDR:443/g" /etc/ssh/sshd_config
fi
log "Restarting SSH..." 1
/etc/init.d/ssh restart
log "Restarting DNSMASQ..." 1
/etc/init.d/dnsmasq restart

log "Reverting changes in file for next boot..." 1
## Safe to do this anyway, because it will only match the exact string from above or do nothing
SED_ARG="s/^ListenAddress $PPP_IPADDR:443$/#-PPP-INT-GOES-HERE.-AUTOMATICALLY-EDITED-DO-NOT-CHANGE-THIS-LINE-#/g"
eval sed -i \"$SED_ARG\" /etc/ssh/sshd_config

log "Spreading network queues across cores..." 0
if [ "$TTINT_STATUS" = true ]; then
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

