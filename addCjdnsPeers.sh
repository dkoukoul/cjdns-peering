#!/bin/bash
print_help() {
  echo "Usage: $0 [options]"
  echo
  echo "Options:"
  echo "  --help                Show this help message and exit"
  echo
  echo "Environment Variables:"
  echo "  CJDNS_PATH            Path to the cjdns installation directory"
  echo "  CJDNS_NAME            Name of the cjdns node (optional)"
  echo
  echo "Description:"
  echo "  This script checks the status of existing cjdns peers and adds new peers if necessary."
  echo "  It requires 'jq' to be installed and the 'CJDNS_PATH' environment variable to be set."
}

# Check for --help argument
if [[ "$1" == "--help" ]]; then
  print_help
  exit 0
fi

if ! command -v jq &> /dev/null; then
  echo "Error: jq is not installed."
  exit 1
fi
# Check if CJDNS_PATH environment variable is set
if [ -z "$CJDNS_PATH" ]; then
  echo "Error: CJDNS_PATH environment variable is not set."
  exit 1
fi
if [ -z "$CJDNS_NAME" ]; then
  read -p "Enter your cjdns node's name: " name
else
  name=$CJDNS_NAME
fi
cjdrouteFile="$CJDNS_PATH/cjdroute.conf"
cjdnstoolspath="$CJDNS_PATH/tools"

# Check if cjdrouteFile exists
if [ ! -f "$cjdrouteFile" ]; then
  echo "Error: cjdroute.conf file does not exist at $CJDNS_PATH."
  exit 1
fi
# Check if peerStats exists
if [ ! -f "$cjdnstoolspath/peerStats" ]; then
  echo "Error: peerStats file does not exist at $CJDNS_PATH/tools/."
  exit 1
fi
if [ ! -f "$cjdnstoolspath/cexec" ]; then
  echo "Error: peerStats file does not exist at $CJDNS_PATH/tools/."
  exit 1
fi

publicip=$(curl http://v4.vpn.anode.co/api/0.3/vpn/clients/ipaddress/ 2>/dev/null | jq -r .ipAddress)
publickey=$(cat $cjdrouteFile | jq -r .publicKey)
cjdnsip=$(cat $cjdrouteFile | jq -r .ipv6)
login=$(cat $cjdrouteFile | jq -r .authorizedPasswords[0].user)
password=$(cat $cjdrouteFile | jq -r .authorizedPasswords[0].password)
CJDNS_PORT=$(cat $cjdrouteFile | jq -r '.interfaces.UDPInterface[0].bind' | sed 's/^.*://')


#Check current peers and their status
peerStats=$($cjdnstoolspath/peerStats)
peersCount=$(echo "$peerStats" | wc -l)
removedPeers=0
echo "Checking status of existing $peersCount peers"
while read -r line; do
    status=$(echo "$line" | awk '{print $3}')
    if [ "$status" != "ESTABLISHED" ]; then
        peerpublickey=$(echo "$line" | awk '{print $2}' | cut -d'.' -f6-)
        # Disconnect from peers that are not ESTABLISHED
        echo "Disconnecting from peer $peerpublickey"
        $cjdnstoolspath/cexec "InterfaceController_disconnectPeer('$peerpublickey')"
        removedPeers=$((removedPeers + 1))
    fi
done < <(echo "$peerStats")
remainingPeers=$((peersCount - removedPeers))
 
if [ "$remainingPeers" -lt 3 ]; then
  echo "We have $remainingPeers peers. Adding more peers."
  json=$(curl --max-time 10 -X POST -H "Content-Type: application/json" -d '{
    "name": "'"$name"'",
    "login": "'"$login"'",
    "password": "'"$password"'",
    "ip": "'"$publicip"'",
    "ip6": "'"$cjdnsip"'",
    "port": '"$CJDNS_PORT"',
    "publicKey": "'"$publickey"'"
  }' http://diffie.pkteer.com:8090/api/peers || cat peers.json)

  # Parse the JSON data and execute the command for each server, until we have 3 peers
  echo "$json" | jq -r '.[] | "\(.publicKey) \(.ip):\(.port) \(.login) \(.password)"' | while read -r line
  do
      publicKey=$(echo $line | cut -d' ' -f1)
      ipAndPort=$(echo $line | cut -d' ' -f2)
      login=$(echo $line | cut -d' ' -f3)
      password=$(echo $line | cut -d' ' -f4)
      $cjdnstoolspath/cexec "UDPInterface_beginConnection(\"$publicKey\",\"$ipAndPort\",0,\"\",\"$password\",\"$login\",0)"
      peerStats=$($cjdnstoolspath/peerStats)
      peersCount=$(echo "$peerStats" | wc -l)
      if [ "$peersCount" -eq 3 ]; then
        echo "We now have 3 peers. Exiting."
        exit 0
      fi
  done
fi