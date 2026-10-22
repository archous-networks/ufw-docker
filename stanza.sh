#!/bin/bash
# Write the DOCKER-UFW stanza into after.rules. NOTHING is applied here --
# only `ufw reload` applies it. Out-of-band iptables-restore is what broke the
# firewall earlier and is never used again.
set -e
SUBNETS=$(docker network ls -q | while read -r id; do
    docker network inspect "$id" --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}' 2>/dev/null
  done | tr ' ' '\n' | grep -E '^[0-9]' | grep -v '^10\.99\.' | sort -u)
sudo sed -i '/# BEGIN DOCKER-UFW/,/# END DOCKER-UFW/d' /etc/ufw/after.rules
{
  echo ""
  echo "# BEGIN DOCKER-UFW"
  echo "*filter"
  echo ":ufw-user-input - [0:0]"
  echo ":DOCKER-USER - [0:0]"
  for s in $SUBNETS; do echo "-A DOCKER-USER -s $s -j RETURN"; done
  echo "-A DOCKER-USER -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN"
  for s in $SUBNETS; do echo "-A DOCKER-USER -d $s -j ufw-user-input"; done
  for s in $SUBNETS; do echo "-A DOCKER-USER -d $s -j DROP"; done
  echo "COMMIT"
  echo "# END DOCKER-UFW"
} | sudo tee -a /etc/ufw/after.rules >/dev/null
