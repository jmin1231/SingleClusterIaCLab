"""Lab settings shared by more than one phase. Imports nothing from lab.phases."""

import ipaddress

# Host-only bridge between the host and the VMs; the host holds VMNET's address on it.
# Change VMNET if the host's LAN already uses 10.250.0.0/24.
BRIDGE = "cloudbr1"
VMNET = ipaddress.ip_interface("10.250.0.1/24")
