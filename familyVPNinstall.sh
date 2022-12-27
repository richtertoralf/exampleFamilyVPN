#!/bin/bash

# 
# familyVPNinstall.sh
#
# Skript zur Installation eines WireGuard-VPN
# Installation auf einem Server mit einer öffentlichen IP-Adresse
# Server-OS: Ubuntu 22.04 LTS by Hetzner
#
# Konfiguration:
VPNserverPort="51820"
DNSserverIP="1.1.1.1"
VPNaddresses="192.168.203.0/24"
VPNserverAddress="192.168.203.1/24"
maxClients=90
VPNaddressClientStart=101 
highIP=254
# Name der Netzwerkkarte ermitteln, z.B. so: 'ls /sys/class/net'
# oder so: inetName=$(ip -o -4 route show to default | awk '{print $5}')
inetName="eth0"

# Start der automatischen Konfiguration
clear
echo "Ich beginne mit der automatischen Konfiguration !"

if  [ $(( $maxClients + $VPNaddressClientStart )) -gt $highIP ]
  then
  echo "Fehler in der Konfiguration. Ein /24er Netz reicht dafür nicht!"
  exit 1
fi

# ermitteln der öffentlichen IP des Servers
# VPNserverIP=$(wget -O - -q icanhazip.com)
VPNserverIP=$(hostname -I | awk '{print $1}')
echo "Ich installiere WireGuard auf dem Server mit der IP "$VPNserverIP

# Installation
sudo apt update -y  && sudo apt upgrade -y
sudo apt install wireguard -y
sudo apt install qrencode -y
sleep 3
echo Die Installation ist abgeschlossen.

# Keys generieren
echo "Im nächsten Schritt werden die Schlüsselpaare erzeugt."
echo "Für wieviele Clients sollen Konfigurationsdateien und QR-Codes erzeugt werden?"
ex='false'
while [ "$ex" == false ]; do
  echo "Gibt die Anzahl ein (zwischen 0 und $maxClients ) und bestätige mit [ENTER]: "
  read anzahlClients
  #prüfen ob $anzahlClients eine ganze Zahl ist
  anzahlClients=$(printf "%d" $anzahlClients 2>/dev/null)
  if [ $anzahlClients -le $maxClients ]
  then
    echo "o.k. Ich werde" $anzahlClients "Clients generieren."
    ex='true'
    if [ $anzahlClients == 0 ]
    then
      echo "Du musst die Clients selbst per Hand anlegen."
    else
      ipf3=${VPNaddresses%.*}
      echo "Die Clients bekommen die Adressen von $ipf3.$VPNaddressClientStart bis $ipf3.$(( $VPNaddressClientStart + $anzahlClients ))"
    fi
  else
    echo "Mehr als $maxClients Clients machen auf diesem Server keinen Sinn!"
  fi
done

# Verzeichnis für die Schlüssel erzeugen
mkdir -p /etc/wireguard/keys
cd /etc/wireguard
# ServerKeys
wg genkey | tee keys/server_private_key | wg pubkey > keys/server_public_key 
echo "Die Keys für den Server wurden erstellt."
# ClientKeys
if [ $anzahlClients != 0 ]
then
  # Verzeichnis für die .conf-Dateien und QR-Codes erzeugen
  mkdir -p /etc/wireguard/clients
  # Konfigurationsdateien und QR-Codes für die Clients erzeugen
  for (( i=$VPNaddressClientStart ; i<$(( $VPNaddressClientStart + $anzahlClients )) ; i++ ))
  do
    wg genkey | tee keys/client${i}_private_key | wg pubkey > keys/client${i}_public_key
    echo -n "Die Keys für client${i} "
    cat <<EOF > /etc/wireguard/clients/client${i}.conf
[Interface]
Address = ${ipf3}.${i}/32
PrivateKey = $(cat /etc/wireguard/keys/client${i}_private_key)
DNS = ${DNSserverIP}
[Peer]
PublicKey = $(cat /etc/wireguard/keys/server_public_key)
Endpoint = ${VPNserverIP}:${VPNserverPort}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
    qrencode -o /etc/wireguard/clients/client${i}.png -t png < /etc/wireguard/clients/client${i}.conf
    echo "und die .conf-Datei sowie der QR-Code wurden erstellt."
  done
else
  echo "Es wurden keine Keys und .conf-Dateien für Clients erstellt."
fi
# WireGuard-Schnittstelle erzeugen
echo "... wg0.conf wird erstellt"
cat <<EOF > /etc/wireguard/wg0.conf
#Server
[Interface]  
PrivateKey = $(cat /etc/wireguard/keys/server_private_key)  
Address = $VPNserverAddress
ListenPort = $VPNserverPort
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o ${inetName} -j MASQUERADE; ip6tables -A FORWARD -i wg0 -j ACCEPT; ip6tables -t nat -A POSTROUTING -o ${inetName} -j MASQUERADE; iptables -t nat -A POSTROUTING -s ${VPNaddresses} -o ${inetName} -j MASQUERADE  
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o ${inetName} -j MASQUERADE; ip6tables -D FORWARD -i wg0 -j ACCEPT; ip6tables -t nat -D POSTROUTING -o ${inetName} -j MASQUERADE; iptables -t nat -D POSTROUTING -s ${VPNaddresses} -o ${inetName} -j MASQUERADE  
# SaveConfig = true 
EOF

# Peers in wg0.conf eintragen
echo "#Clients" >> /etc/wireguard/wg0.conf
if [ $anzahlClients != 0 ]
then
  for (( i=$VPNaddressClientStart ; i<$(( $VPNaddressClientStart + $anzahlClients )) ; i++ ))
  do
  cat <<EOF >> /etc/wireguard/wg0.conf
[Peer] 
# client${i} 
PublicKey = $(cat /etc/wireguard/keys/client${i}_public_key)  
AllowedIPs = ${ipf3}.${i}/32
EOF
  done
fi

echo "Die WireGuard_Datei wg0.conf wurde erzeugt."
sudo wg-quick up wg0
sudo systemctl enable wg-quick@wg0.service

# IPv4 forwarding aktivieren
sudo sed -i 's/\#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/g' /etc/sysctl.conf
# negate the need to reboot after the above change
sudo sysctl -p
sudo echo 1 | sudo tee /proc/sys/net/ipv4/ip_forward

echo "Damit ist die automatische Konfiguration abgeschlossen."
sleep 5
echo "Prüfe jetzt die Schnittstelle wg0 selbst!"
wg
echo 
echo "Alles o.k.? ... Wenn nicht, frage den Experten um Rat ;-)"
