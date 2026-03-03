#!/bin/bash

# 1. Disable DNSStubListener
sudo sed -i 's/#DNSStubListener=yes/DNSStubListener=no/' /etc/systemd/resolved.conf

# 2. Update resolv.conf symlink
sudo ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf

# 3. Ensure hostname resolves locally (fixes the sudo error)
HOSTNAME=$(hostname)
grep -q "$HOSTNAME" /etc/hosts || echo "127.0.1.1 $HOSTNAME" | sudo tee -a /etc/hosts

# 4. Restart resolved
sudo systemctl restart systemd-resolved