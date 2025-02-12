#!/bin/bash

# Pastikan script dijalankan sebagai root
if [ "$EUID" -ne 0 ]; then
    echo "Harap jalankan sebagai root"
    exit 1
fi

# Update package list dan upgrade sistem
apt update -y && apt upgrade -y

# Pastikan UFW terinstal, jika tidak, install terlebih dahulu
if ! command -v ufw &> /dev/null; then
    echo "UFW tidak ditemukan, menginstal sekarang..."
    apt install -y ufw
fi

# Install paket yang diperlukan
apt install -y openvpn easy-rsa iptables

# Konfigurasi UFW
ufw allow OpenSSH
ufw allow 1194/udp
ufw enable

# Setup direktori EasyRSA
EASYRSA_DIR="/etc/openvpn/easy-rsa"
if [ ! -d "$EASYRSA_DIR" ]; then
    mkdir -p "$EASYRSA_DIR"
    cp -r /usr/share/easy-rsa/* "$EASYRSA_DIR"  # Salin jika belum ada
fi

cd "$EASYRSA_DIR"

# Pastikan easyrsa ada, jika tidak, hentikan script
easy_rsa_bin="$EASYRSA_DIR/easyrsa"
if [ ! -f "$easy_rsa_bin" ]; then
    echo "File easyrsa tidak ditemukan di $EASYRSA_DIR!"
    exit 1
fi
chmod +x "$easy_rsa_bin"

# Inisialisasi PKI
"$easy_rsa_bin" init-pki

# Bangkitkan CA
EASYRSA_BATCH=1 "$easy_rsa_bin" build-ca nopass

# Buat kunci server
EASYRSA_BATCH=1 "$easy_rsa_bin" gen-req server nopass
EASYRSA_BATCH=1 "$easy_rsa_bin" sign-req server server

# Buat Diffie-Hellman key
EASYRSA_BATCH=1 "$easy_rsa_bin" gen-dh

# Buat TLS key
openvpn --genkey secret /etc/openvpn/ta.key

# Salin file ke direktori OpenVPN
cp pki/ca.crt pki/issued/server.crt pki/private/server.key pki/dh.pem /etc/openvpn/

# Buat file konfigurasi OpenVPN server
cat > /etc/openvpn/server.conf <<EOF
port 1194
proto udp
dev tun
ca /etc/openvpn/ca.crt
cert /etc/openvpn/server.crt
key /etc/openvpn/server.key
dh /etc/openvpn/dh.pem
tls-auth /etc/openvpn/ta.key 0
server 10.8.0.0 255.255.255.0
ifconfig-pool-persist /var/log/openvpn/ipp.txt
keepalive 10 120
cipher AES-256-CBC
auth SHA256
persist-key
persist-tun
status /var/log/openvpn-status.log
log /var/log/openvpn/openvpn.log
verb 3
explicit-exit-notify 1
EOF

# Aktifkan IP forwarding
sysctl -w net.ipv4.ip_forward=1
echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf

# Pastikan direktori iptables ada
mkdir -p /etc/iptables

# Simpan aturan iptables
iptables-save > /etc/iptables/rules.v4

# Tambahkan iptables rules ke UFW
cat > /etc/ufw/before.rules <<EOF
# START OPENVPN RULES
*nat
:POSTROUTING ACCEPT [0:0]
-A POSTROUTING -s 10.8.0.0/24 -o eth0 -j MASQUERADE
COMMIT
# END OPENVPN RULES
EOF

ufw reload

# Restart OpenVPN dan aktifkan saat boot
systemctl restart openvpn@server
systemctl enable openvpn@server

# Buat sertifikat klien
CLIENT_NAME="client1"
EASYRSA_BATCH=1 "$easy_rsa_bin" gen-req "$CLIENT_NAME" nopass
EASYRSA_BATCH=1 "$easy_rsa_bin" sign-req client "$CLIENT_NAME"

# Salin sertifikat klien
cp pki/issued/$CLIENT_NAME.crt pki/private/$CLIENT_NAME.key /etc/openvpn/

# Buat file konfigurasi klien
SERVER_IP=$(curl -s ifconfig.me)
mkdir -p ~/client-configs
cat > ~/client-configs/$CLIENT_NAME.ovpn <<EOF
client
dev tun
proto udp
remote $SERVER_IP 1194
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
tls-auth ta.key 1
auth SHA256
cipher AES-256-CBC
verb 3
<ca>
$(cat /etc/openvpn/ca.crt)
</ca>
<cert>
$(cat /etc/openvpn/$CLIENT_NAME.crt)
</cert>
<key>
$(cat /etc/openvpn/$CLIENT_NAME.key)
</key>
<tls-auth>
$(cat /etc/openvpn/ta.key)
</tls-auth>
EOF

# Konfirmasi instalasi selesai
echo "Instalasi OpenVPN selesai!"
echo "File konfigurasi klien tersedia di: ~/client-configs/$CLIENT_NAME.ovpn"