#!/usr/bin/env bash
# health-check.sh
# Hits the load balancer repeatedly and reports which web nodes are responding.
# Run this from the project root after `vagrant up` and `ansible-playbook`.

LB_IP="192.168.12.10"
REQUESTS=9
TIMEOUT=3

echo "=== HA Lab Health Check ==="
echo "Load balancer: http://${LB_IP}"
echo ""

# Check the load balancer is reachable at all
if ! curl -s --max-time "$TIMEOUT" "http://${LB_IP}" > /dev/null 2>&1; then
  echo "ERROR: Load balancer at ${LB_IP} is not responding."
  echo "Make sure the VMs are up: vagrant status"
  exit 1
fi

echo "Sending ${REQUESTS} requests and tracking which node handles each one..."
echo ""

declare -A node_counts

for i in $(seq 1 "$REQUESTS"); do
  response=$(curl -s --max-time "$TIMEOUT" "http://${LB_IP}" | grep -oP '(?<=Served by: <strong>).*(?=</strong>)')
  if [[ -n "$response" ]]; then
    node_counts["$response"]=$(( ${node_counts["$response"]:-0} + 1 ))
    echo "  Request $i → $response"
  else
    echo "  Request $i → no response"
  fi
done

echo ""
echo "=== Summary ==="
for node in $(echo "${!node_counts[@]}" | tr ' ' '\n' | sort); do
  echo "  $node: ${node_counts[$node]} requests"
done

echo ""

# Warn if any expected node never showed up
for expected in web01 web02 web03; do
  if [[ -z "${node_counts[$expected]}" ]]; then
    echo "WARNING: $expected never appeared in rotation — it may be down."
  fi
done

echo "Done."
