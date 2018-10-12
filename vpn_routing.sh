#!/bin/bash

function get_ips_for_hostname(){
  # echo the ip addresses for a hostname
  local ips=`host $1 | grep "has address" | awk '{print $4}'`
  echo "$ips"
}

function add_to_routing_table(){
  echo "Adding static routes for $1 via $3"
  local hostname=$1
  local table=$2
  local interface=$3
  get_interface_ip $interface
  local interface_ip=$IPADDR
  for ip in `get_ips_for_hostname $1`;
  do
    echo "Host: $1  IP: $ip"
    ip route add $ip via $interface_ip dev $interface table $table
  done
  echo "Done"
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
      echo "No IP found.  Waiting and checking again... ($COUNT/$RETRIES)"
      sleep $SLEEP
    else
      echo "Found IP: $IPADDR" $2
      GOTIP=0
      break
    fi
  done
  return $GOTIP
}



if [ $EUID -gt 0 ]; then
  echo "This script needs to run as root."
  exit 1
fi

shady_sites=("rarbg.to" "1337x.to" "tracker.leechers-paradise.org" "zer0day.ch" "tracker.coppersurfer.tk" "exodus.desync.com")
for site in "${shady_sites[@]}"
do
  echo "Adding VPN route for $site"
  add_to_routing_table $site vpn_hubert tun0
done

echo "Done!"

