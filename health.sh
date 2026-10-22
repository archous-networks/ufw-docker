#!/bin/bash
# One-line health verdict for the firewall + the functional reachability test.
HOSTIP=203.0.113.82
probe() { docker run --rm --network ufwtest alpine/curl:latest -sk -o /dev/null \
            -w '%{http_code}' --max-time 5 "$1" 2>/dev/null || true; }
act=$(sudo ufw status 2>/dev/null | grep -c 'Status: active')
logc=$(sudo iptables -S 2>/dev/null | grep -cE '^-N ufw.*logging')
ssh_=$(sudo iptables -S ufw-user-input 2>/dev/null | grep -c 'dport 22')
du=$(sudo iptables -S DOCKER-USER 2>/dev/null | tail -n +2 | wc -l)
dup=$(sudo iptables -S DOCKER-USER 2>/dev/null | grep -c 'ufw-user-input')
p80=$(probe "http://$HOSTIP/"); p443=$(probe "https://$HOSTIP/"); p8089=$(probe "http://$HOSTIP:8089/")
printf "  ufw=%s logchains=%-2s sshrule=%s | DOCKER-USER rules=%-2s jumps=%s | 80=%-4s 443=%-4s 8089=%s\n" \
  "$([ "$act" -eq 1 ] && echo ACTIVE || echo DOWN)" "$logc" \
  "$([ "$ssh_" -gt 0 ] && echo yes || echo NO)" "$du" "$dup" \
  "${p80:---}" "${p443:---}" "${p8089:---}"
