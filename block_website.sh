#!/bin/bash

function look_up_ips() {
  local WEBSITE=$1
  IP_LIST=`dig $1 A | awk '{print $5}' | grep -Eo '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}'`
  echo $IP_LIST
}

function drop_ip_dest(){
  #  We add the DROP rule to the FORWARD table
  #  This drops packets coming FROM the intended host
  #  rather than blocking outgoing packets.  This means
  #  that all ESTABLISHED connections stop working as well
  #  if we just added it to the outgoing rule then all established
  #  connections would continue to work until the conntrack times them out.
  local IPADDR=$1
  echo "Blocking access to IP: $IPADDR"
  iptables -t filter -I FORWARD -s $IPADDR -j DROP
}

function allow_ip_dest(){
  # We assume that the IP addresses will stay the same.
  # This is not sensible.
  local IPADDR=$1
  echo "Unblocking access to IP: $IPADDR"
  iptables -t filter -D FORWARD -s $IPADDR -j DROP
}

if [ $EUID -gt 0 ]; then
  echo "This script needs to run as root."
  exit 1
fi

ACTION=$1
SITE=$2

if [ "$ACTION" != "block" ] && [ "$ACTION" != "unblock" ]; then
  echo "First argument needs to be either block or unblock"
  exit 1
fi

echo "Destination hostname: $SITE"

a=$(look_up_ips $SITE)
for THING in $a
do
  #echo "IP address: $THING"
  if [ "$ACTION" == "block" ]; then
    drop_ip_dest $THING
  fi
  if [ "$ACTION" == "unblock" ]; then
    allow_ip_dest $THING
  fi
done

