#!/bin/bash

REPO=https://raw.githubusercontent.com/TripleA150/AntiZapret-VPN/refs/heads/patch-1/setup/root/antizapret/config

URLS=(
  "$REPO/allow-ips.txt"
  "$REPO/custom-block.txt"
  "$REPO/deny-ips.txt"
  "$REPO/drop-ips.txt"
  "$REPO/exclude-adblock-hosts.txt"
  "$REPO/exclude-hosts.txt"
  "$REPO/exclude-ips.txt"
  "$REPO/forward-ips.txt"
  "$REPO/include-adblock-hosts.txt"
  "$REPO/include-hosts.txt"
  "$REPO/include-ips.txt"
  "$REPO/remove-hosts.txt"
)

cd /root/antizapret
rm -f config/*

curl -L --parallel --create-dirs --output-dir "./config" --remote-name-all -O "${URLS[@]}"

sed -E 's/[\r[:space:]]+//g; /^[[:punct:]]/d; /^$/d' config/custom-block.txt | sort -u > temp/custom-block.txt
echo "$(wc -l < temp/custom-block.txt) - custom-block.txt"
echo -e '$TTL 10800\n@ SOA . . (1 1 1 1 10800)' > result/custom.rpz
sed 's/$/ CNAME ./; p; s/^/*./' temp/custom-block.txt >> result/custom.rpz

if [[ -f result/custom.rpz ]] && ! diff -q result/custom.rpz /etc/knot-resolver/custom.rpz; then
        cp -f result/custom.rpz /etc/knot-resolver/custom.rpz.tmp
        mv -f /etc/knot-resolver/custom.rpz.tmp /etc/knot-resolver/custom.rpz
        sleep 5
fi
