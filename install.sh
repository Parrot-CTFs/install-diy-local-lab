#!/bin/bash

set -eou pipefail

# === Config ===
BRIDGE_NAME="br-vpnnet"
SUBNET="10.70.0.0/24"
GATEWAY="10.70.0.1"
PFSENSE_IMG="/var/lib/libvirt/images/pfSense.qcow2"
UBUNTU_IMG="/var/lib/libvirt/images/ubuntu-server.qcow2"
UBUNTU_ISO="/var/lib/libvirt/boot/ubuntu-22.04.iso"
PFSENSE_ISO="/var/lib/libvirt/boot/pfSense-CE-2.7.1.iso"
CLOUD_INIT_ISO="/var/lib/libvirt/boot/cloud-init.iso"
UBUNTU_VM_NAME="vpn-server"
PFSENSE_VM_NAME="pfsense-fw"
SSH_USER="ubuntu"
SSH_PASS="vpnpass"
UBUNTU_IP="10.70.0.10"
CLIENT_OVPN_OUTPUT="/root/client1.ovpn"

# === Create Linux Bridge ===
echo "[*] Checking bridge $BRIDGE_NAME..."
if ! nmcli conn show "$BRIDGE_NAME" &>/dev/null; then
    echo "[*] Creating bridge $BRIDGE_NAME..."
    nmcli connection add type bridge con-name $BRIDGE_NAME ifname $BRIDGE_NAME
    nmcli connection modify $BRIDGE_NAME ipv4.addresses "$GATEWAY/24"
    nmcli connection modify $BRIDGE_NAME ipv4.method manual
    nmcli connection up $BRIDGE_NAME
else
    echo "[*] Bridge $BRIDGE_NAME already exists."
fi

# === Generate cloud-init ISO ===
echo "[*] Creating cloud-init ISO for Ubuntu autologin..."
cat > user-data <<EOF
#cloud-config
hostname: vpn-server
users:
  - name: $SSH_USER
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: users, admin
    home: /home/$SSH_USER
    shell: /bin/bash
    lock_passwd: false
    plain_text_passwd: '$SSH_PASS'
ssh_pwauth: True
disable_root: false
EOF

cat > meta-data <<EOF
instance-id: vpn-server
local-hostname: vpn-server
EOF

genisoimage -output $CLOUD_INIT_ISO -volid cidata -joliet -rock user-data meta-data

# === Step 3: Launch VMs ===
echo "[*] Creating Ubuntu disk..."
qemu-img create -f qcow2 $UBUNTU_IMG 20G

echo "[*] Launching Ubuntu VPN Server (QEMU, with cloud-init)..."
qemu-system-x86_64 \
    -enable-kvm \
    -m 2048 \
    -smp 2 \
    -netdev bridge,id=net0,br=$BRIDGE_NAME \
    -device virtio-net-pci,netdev=net0 \
    -drive file=$UBUNTU_IMG,format=qcow2 \
    -cdrom $UBUNTU_ISO \
    -drive file=$CLOUD_INIT_ISO,format=raw \
    -boot order=d \
    -name $UBUNTU_VM_NAME \
    -nographic &

echo "[*] Creating pfSense disk..."
qemu-img create -f qcow2 $PFSENSE_IMG 8G

echo "[*] Launching pfSense VM (manual setup)..."
qemu-system-x86_64 \
    -enable-kvm \
    -m 2048 \
    -smp 2 \
    -netdev bridge,id=net0,br=$BRIDGE_NAME \
    -device virtio-net-pci,netdev=net0 \
    -drive file=$PFSENSE_IMG,format=qcow2 \
    -cdrom $PFSENSE_ISO \
    -boot order=d \
    -name $PFSENSE_VM_NAME \
    -nographic &

# ===  Prompt user to complete install ===
echo ""
echo "======================================================"
echo "  VM INSTALL TIME"
echo "------------------------------------------------------"
echo " Ubuntu VPN Login:"
echo "   Username: $SSH_USER"
echo "   Password: $SSH_PASS"
echo "   IP:       $UBUNTU_IP"
echo ""
echo " pfSense: set LAN to $GATEWAY"
echo " Wait until both are installed and network is up."
echo "======================================================"
read -p "[!] Press ENTER once VMs are fully installed and SSH is accessible..."

# ===  Install OpenVPN INSIDE the Ubuntu VM ===
echo "[*] Installing OpenVPN stack inside the VPN server..."

sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no ${SSH_USER}@${UBUNTU_IP} << 'EOFSSH'
set -e
sudo apt update
sudo apt install -y openvpn easy-rsa iptables-persistent

make-cadir ~/openvpn-ca
cd ~/openvpn-ca
./easyrsa init-pki
echo | ./easyrsa build-ca nopass
./easyrsa build-server-full server nopass
./easyrsa build-client-full client1 nopass
./easyrsa gen-dh
./easyrsa gen-crl

sudo cp pki/{ca.crt,crl.pem} /etc/openvpn
sudo cp pki/issued/server.crt /etc/openvpn
sudo cp pki/private/server.key /etc/openvpn
sudo cp pki/dh.pem /etc/openvpn

gunzip -c /usr/share/doc/openvpn/examples/sample-config-files/server.conf.gz | sudo tee /etc/openvpn/server.conf

sudo sed -i 's/^;push "redirect-gateway/push "redirect-gateway/' /etc/openvpn/server.conf
echo 'push "route 10.70.0.0 255.255.255.0"' | sudo tee -a /etc/openvpn/server.conf
echo 'crl-verify crl.pem' | sudo tee -a /etc/openvpn/server.conf

echo 1 | sudo tee /proc/sys/net/ipv4/ip_forward
echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.conf

# === Firewall & NAT Rules ===
# Allow VPN traffic and forwarding
sudo iptables -A INPUT -i tun0 -j ACCEPT
sudo iptables -A FORWARD -i tun0 -j ACCEPT
sudo iptables -A FORWARD -i tun0 -o eth0 -m state --state RELATED,ESTABLISHED -j ACCEPT
sudo iptables -A FORWARD -i eth0 -o tun0 -m state --state RELATED,ESTABLISHED -j ACCEPT

# Allow DNS (optional)
sudo iptables -A INPUT -p udp --dport 53 -j ACCEPT

# Allow OpenVPN traffic
sudo iptables -A INPUT -p udp --dport 1194 -j ACCEPT

# NAT for VPN subnet
sudo iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o eth0 -j MASQUERADE

# Persist all rules
sudo iptables-save | sudo tee /etc/iptables/rules.v4

sudo systemctl enable openvpn@server
sudo systemctl start openvpn@server

# Export .ovpn client config
mkdir -p ~/ovpn-export
cat > ~/ovpn-export/client1.ovpn <<EOFCONF
client
dev tun
proto udp
remote 10.70.0.10 1194
resolv-retry infinite
nobind
persist-key
persist-tun
ca [inline]
cert [inline]
key [inline]
remote-cert-tls server
comp-lzo
verb 3

<ca>
$(cat pki/ca.crt)
</ca>
<cert>
$(cat pki/issued/client1.crt)
</cert>
<key>
$(cat pki/private/client1.key)
</key>
EOFCONF
EOFSSH

# === Copy client config back to Proxmox ===
echo "[*] Copying VPN config file back to Proxmox host..."
sshpass -p "$SSH_PASS" scp -o StrictHostKeyChecking=no ${SSH_USER}@${UBUNTU_IP}:/home/${SSH_USER}/ovpn-export/client1.ovpn $CLIENT_OVPN_OUTPUT

echo ""
echo "VPN Setup Complete!"
echo "Credentials:"
echo "   Username: $SSH_USER"
echo "   Password: $SSH_PASS"
echo "   Ubuntu VPN IP: $UBUNTU_IP"
echo ""
echo "VPN client config exported to: $CLIENT_OVPN_OUTPUT"
echo "You can now import this into any OpenVPN client to connect."
