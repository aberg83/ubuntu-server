#!/bin/bash

# Run commands or script as root
sudo -i

# Update system
apt update
apt dist-upgrade -y

# Set Time Zone (requires user input)
dpkg-reconfigure tzdata

# Install Docker & Docker Compose
apt install curl -y
curl -fsSL https://get.docker.com -o get-docker.sh
sh get-docker.sh
usermod -aG docker ${USER}
curl -L --fail https://raw.githubusercontent.com/linuxserver/docker-docker-compose/master/run.sh -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose

# Setup unattended-upgrades (requires user input)
apt install unattended-upgrades -y
dpkg-reconfigure --priority=low unattended-upgrades

# Import ZFS pool
apt install zfsutils-linux -y
zpool import -d /dev/disk/by-id ${POOL}

# Setup SMART monitoring
apt install smartmontools -y
cat >> /etc/smartd.conf << EOF
DEVICESCAN -H -l error -l selftest -f -s (O/../../5/11|L/../../5/13|C/../../5/15) -m ${EMAIL}
EOF
systemctl enable smartmontools
systemctl start smartmontools

# Setup Sanoid
apt install sanoid -y
cat >> /home/${USER}/pre_snap.sh << EOF
#!/bin/bash
docker stop $(docker ps -a -q)
EOF
cat >> /home/${USER}/post_snap.sh << EOF
#!/bin/bash
docker start $(docker ps -a -q)
EOF
chmod +x /home/${USER}/pre_snap.sh /home/${USER}/post_snap.sh
mkdir /etc/systemd/system/sanoid.service.d
mkdir /etc/systemd/system/sanoid-prune.service.d
cat >> /etc/systemd/system/sanoid.service.d/override.conf << EOF
[Service]
Environment=TZ=America/Toronto
EOF
cat >> /etc/systemd/system/sanoid-prune.service.d/override.conf << EOF
[Service]
Environment=TZ=America/Toronto
EOF
cat >> /etc/sanoid/sanoid.conf << EOF
[docker]
    hourly = 0
    daily = 14
    weekly = 0
    monthly = 0
    yearly = 0
    recursive = no
    autosnap = yes
    autoprune = yes
    pre_snapshot_script = /home/${USER}/pre_snap.sh
    post_snapshot_script = /home/${USER}/post_snap.sh
    script_timeout = 0
EOF
systemctl daemon-reload
systemctl enable sanoid.service
systemctl enable sanoid-prune.service
systemctl enable sanoid.timer
systemctl start sanoid.timer

# Setup Nvidia Driver
mkdir /opt/nvidia && cd /opt/nvidia
wget https://international.download.nvidia.com/XFree86/Linux-x86_64/510.54/NVIDIA-Linux-x86_64-510.54.run
chmod +x NVIDIA-Linux-x86_64-510.54.run
./NVIDIA-Linux-x86_64-510.54.run --no-questions --ui=none --disable-nouveau
update-initramfs -u
reboot
./NVIDIA-Linux-x86_64-510.54.run --no-questions --ui=none
nvidia-smi
distribution=$(. /etc/os-release;echo $ID$VERSION_ID) \
   && curl -s -L https://nvidia.github.io/nvidia-docker/gpgkey | sudo apt-key add - \
   && curl -s -L https://nvidia.github.io/nvidia-docker/$distribution/nvidia-docker.list | sudo tee /etc/apt/sources.list.d/nvidia-docker.list
apt update
apt install -y nvidia-docker2
systemctl restart docker
docker run --rm --gpus all nvidia/cuda:11.0-base nvidia-smi
git clone https://github.com/keylase/nvidia-patch.git
cd nvidia-patch
./patch.sh 

# Deactivate DNSStubListener
mkdir /etc/systemd/resolved.conf.d
cat >> /etc/systemd/resolved.conf.d/adguardhome.conf << EOF
[Resolve]
DNS=127.0.0.1
DNSStubListener=no
EOF
mv /etc/resolv.conf /etc/resolv.conf.backup
ln -s /run/systemd/resolve/resolv.conf /etc/resolv.conf
systemctl reload-or-restart systemd-resolved

# Pull docker containers
cd /home/${USER}
git clone https://github.com/aberg83/docker-compose
cd docker-compose
cat >> .env << EOF
USER=${USER}
PASS=${PASS}
SMB_IP=${SMB_IP}
UID=${UID}
GID=${GID}
DOMAIN=${DOMAIN}
PEERS=${PEERS}
EMAIL=${EMAIL}
FASTMAIL_PASSWORD=${FASTMAIL_PASSWORD}
CF_API_KEY=${CF_API_KEY}
YUBICO_CLIENT_ID=${YUBICO_CLIENT_ID}
YUBICO_SECRET_KEY=${YUBICO_SECRET_KEY}
ZIGBEE_PATH=${ZIGBEE_PATH}
ZWAVE_PATH=${ZWAVE_PATH}
CONFIG=${CONFIG}
HOSTNAME=${HOSTNAME}
EOF
docker-compose up -d

# Install and configure KVM
apt install qemu-kvm libvirt-daemon-system libvirt-clients bridge-utils -y
adduser ${USER} libvirt
adduser ${USER} kvm
cat >> /etc/sysctl.d/bridge.conf << EOF
net.bridge.bridge-nf-call-ip6tables=0
net.bridge.bridge-nf-call-iptables=0
net.bridge.bridge-nf-call-arptables=0
EOF
cat >> /etc/udev/rules.d/99-bridge.rules << EOF
ACTION=="add", SUBSYSTEM=="module", KERNEL=="br_netfilter", RUN+="/sbin/sysctl -p /etc/sysctl.d/bridge.conf"
EOF
virsh net-destroy default
virsh net-undefine default
cat >> /etc/netplan/00-installer-config.yaml << EOF
network:
  ethernets:
    eno1:
      dhcp4: false
      dhcp6: false
    eno2:
      dhcp4: true
    eno3:
      dhcp4: true
    eno4:
      dhcp4: true
  bridges:
    br0:
      interfaces:
      - eno1
      addresses:
      - ${IP}/24
      gateway4: ${GW}
      nameservers:
        addresses:
        - 1.1.1.1
        - 1.0.0.1
        search: []
      parameters:
        stp: true
        forward-delay: 4
      dhcp4: no
      dhcp6: no
  version: 2
EOF
reboot
cat >> host-bridge.xml << EOF
<network>
  <name>host-bridge</name>
  <forward mode="bridge"/>
  <bridge name="br0"/>
</network>
EOF
virsh net-define host-bridge.xml
virsh net-start host-bridge
virsh net-autostart host-bridge
rm host-bridge.xml
virsh net-list --all

# Install and configure Samba
apt install samba -y
cp /etc/samba/smb.conf /etc/samba/smb.conf.bak
cat >> /etc/samba/smb.conf << EOF
[global]
  workgroup = WORKGROUP
  server string = ${HOSTNAME}
  security = user
  map to guest = Bad Password
  log file = /var/log/samba/%m.log
  max log size = 50
  printcap name = /dev/null
  load printers = no
  browseable = yes
  writeable = yes
  read only = no
  admin users = ${USER}
  create mode = 0660
  directory mode = 0770
  vfs objects = shadow_copy2
  shadow:snapdir = .zfs/snapshot
  shadow:sort = desc
  shadow:format = autosnap_%Y-%m-%d_%H:%M:%S_daily
  shadow:localtime = yes
[docker]
  path = ${CONFIG}
EOF
smbpasswd -a ${USER}
systemctl restart smbd

# Add SSH keys
mkdir /home/${USER}/.ssh
chmod 700 /home/${USER}/.ssh
echo "${USER_KEY}" > /home/${USER}/.ssh/authorized_keys
chown -R ${USER} /home/${USER}/.ssh
chgrp -R ${USER} /home/${USER}/.ssh
chmod 600 /home/${USER}/.ssh/authorized_keys
mkdir /root/.ssh
chmod 700 /root/.ssh
echo "${ROOT_KEY_1}" > /root/.ssh/authorized_keys
echo "${ROOT_KEY_2}" > /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
systemctl restart ssh

# Install and configure Postfix
echo "postfix postfix/mailname string ${HOSTNAME}.local" | debconf-set-selections
echo "postfix postfix/main_mailer_type string 'Internet Site'" | debconf-set-selections
apt install mailutils -y
apt install libsasl2-modules -y
echo "[smtp.fastmail.com]:587 ${EMAIL}:${FASTMAIL_PASSWORD}" > /etc/postfix/sasl_passwd
postmap hash:/etc/postfix/sasl_passwd
chmod 600 /etc/postfix/sasl_passwd
cat >> /etc/postfix/main.cf << EOF
myhostname=${HOSTNAME}.local

smtpd_banner = $myhostname ESMTP $mail_name (Debian/GNU)
biff = no

# appending .domain is the MUA's job.
append_dot_mydomain = yes

# Uncomment the next line to generate "delayed mail" warnings
#delay_warning_time = 4h

alias_maps = hash:/etc/aliases
alias_database = hash:/etc/aliases
mydestination = ${HOSTNAME}.local, ${HOSTNAME}, localhost.localdomain, , localhost
relayhost = [smtp.fastmail.com]:587
mynetworks = 127.0.0.0/8
inet_interfaces = all
recipient_delimiter = +

compatibility_level = 2

#  use tls
smtp_use_tls=yes

# use sasl when authenticating to foreign SMTP servers
smtp_sasl_auth_enable = yes

# path to password map file
smtp_sasl_password_maps = hash:/etc/postfix/sasl_passwd

# eliminate default security options which are imcompatible with gmail
smtp_sasl_security_options =

myorigin = /etc/mailname
mailbox_size_limit = 0
inet_protocols = all
EOF
postfix reload
echo "test mail from ${HOSTNAME}" | mail -s test ${EMAIL}

# Install and configure NUT
apt install nut -y
sed -i 's/MODE=none/MODE=netserver/' /etc/nut/nut.conf
cat > /etc/nut/notify << EOF
#! /bin/sh
echo "$*" | mail -s "${HOSTNAME}: UPS notice" ${EMAIL}
EOF
chown root:nut /etc/nut/notify
chmod +x /etc/nut/notify
cat > /etc/nut/upsmon.conf << EOF
MONITOR ups@127.0.0.1:3493 1 ${USER} ${PASS} master
RUN_AS_USER nut
NOTIFYCMD /etc/nut/notify
NOTIFYFLAG ONBATT SYSLOG+WALL+EXEC
NOTIFYFLAG LOWBATT SYSLOG+WALL+EXEC
NOTIFYFLAG ONLINE SYSLOG+WALL+EXEC
NOTIFYFLAG COMMBAD SYSLOG+WALL+EXEC
NOTIFYFLAG COMMOK SYSLOG+WALL+EXEC
NOTIFYFLAG REPLBATT SYSLOG+WALL+EXEC
NOTIFYFLAG NOCOMM SYSLOG+EXEC
NOTIFYFLAG FSD SYSLOG+EXEC
NOTIFYFLAG SHUTDOWN SYSLOG+EXEC
EOF
cat > /etc/nut/ups.conf << EOF
[ups]
  driver = usbhid-ups
  port = auto
EOF
cat > /etc/nut/upsd.conf << EOF
LISTEN ${IP} 3493
LISTEN 127.0.0.1 3493
LISTEN ::1 3493
EOF
cat > /etc/nut/upsd.users << EOF
[${USER}]
  password = ${PASS}
  upsmon master
EOF
upsdrvctl start
systemctl start nut-server
upsc ups@localhost

# Configure ZED notifications
sed -i 's/ZED_EMAIL_ADDR="root"/ZED_EMAIL_ADDR="${EMAIL}"/' /etc/zfs/zed.d/zed.rc
sed -i 's/#ZED_NOTIFY_VERBOSE=0/ZED_NOTIFY_VERBOSE=1/' /etc/zfs/zed.d/zed.rc
systemctl restart zed
zpool scrub storage
