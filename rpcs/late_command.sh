#!/bin/bash

# Passwordless sudo
echo "%sudo   ALL=NOPASSWD: ALL" >> /etc/sudoers

# Speed up SSH
echo "UseDNS no" >> /etc/ssh/sshd_config

# Display login prompt after boot
# sed -i 's/quiet splash//' /etc/default/grub
# Setup Plymouth
cp -r /tmp/installer/opt/rpcs/themes/rpcs /lib/plymouth/themes
cp -r /tmp/installer/opt/rpcs/themes/rpcs-text /lib/plymouth/themes
update-alternatives --install /lib/plymouth/themes/default.plymouth default.plymouth /lib/plymouth/themes/rpcs/rpcs.plymouth 100
update-alternatives --set default.plymouth /lib/plymouth/themes/rpcs/rpcs.plymouth
update-alternatives --install /lib/plymouth/themes/text.plymouth text.plymouth /lib/plymouth/themes/rpcs-text/rpcs-text.plymouth 100
update-alternatives --set text.plymouth /lib/plymouth/themes/rpcs-text/rpcs-text.plymouth

# Move installer items into target from bind mount
cp /tmp/installer/opt/rpcs/*.{rb,sh} /opt/rpcs
cp /tmp/installer/opt/rpcs/version.cfg /opt/rpcs

# Put EULA in place on disk
cp /tmp/installer/opt/rpcs/RPCS_EULA.txt /usr/share/doc/RPCS_EULA.txt

# Move the base images and chef deb to /opt/rpcs
cp /tmp/installer/opt/rpcs/resources/*.{gz,deb} /opt/rpcs

# copy over any config values from the builder
cat /tmp/installer/opt/rpcs/rpcs.cfg >> /opt/rpcs/rpcs.cfg

# Move the qcow to /opt/rpcs
if grep -Eqi "controller|all-in-one" /opt/rpcs/rpcs.cfg; then
    cp /tmp/installer/opt/rpcs/resources/*.pristine /opt/rpcs
fi
chmod 755 /opt/rpcs/*

# DO NOT STAY AT GRUB AFTER POWER LOSS/VIRSH DESTROY (cf: Bug #669481)
sed -i '/set timeout=-1/ s/-1/0/' /etc/grub.d/00_header
cat >> /etc/default/grub <<EOF
GRUB_GFXMODE=1024x768
GRUB_GFXPAYLOAD_LINUX=keep
EOF
update-grub

sed -i '/^exit/i /bin/bash /opt/rpcs/post-install.sh >> /var/log/post-install.log 2>&1 &' /etc/rc.local

cat > /etc/init/tty1.conf <<EOF
# tty1 - getty
#
# This service maintains a getty on tty1 from the point the system is
# started until it is shut down again.

start on stopped rc RUNLEVEL=[2345] and (
            not-container or
            container CONTAINER=lxc or
            container CONTAINER=lxc-libvirt)

stop on runlevel [!2345]

respawn

console output
script
    exec 0</dev/tty1 >/dev/tty1 2>&1
    /opt/rpcs/status.sh
end script

EOF
