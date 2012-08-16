#!/bin/bash

exec 9>/var/log/post-install.debug
BASH_XTRACEFD=9
set -x

set -o errtrace

export DEBIAN_FRONTEND=noninteractive

# Global Variables
qemu_domain_type=kvm
qemu_emulator=/usr/bin/kvm
total_cookbooks=0
run_list_count=0
STATUS_FIFO=/opt/rpcs/.status_fifo

# source the external functions
. /opt/rpcs/functions.sh

#set -o nounset
set -o errexit # TODO: Make trap that complains loudly somewhere if we fail?
shopt -s extdebug # inherit trap handlers in functions, just in case
trap do_exit ERR EXIT SIGINT SIGTERM

if [ -e /opt/rpcs/.status ]; then rm -f /opt/rpcs/.status; fi;
fqdn=$(hostname -f)

do_status 0 "Initializing"
# cd to /root to primarily work from
cd /root

# Source our node config
. /opt/rpcs/rpcs.cfg

# Set some handy variables
if [ $role = "Controller" ] || [ $role = "All-In-One" ]; then
    chef=169.254.123.2
else
    chef=$net_con_ip
fi

# Augment config from controller if we're a compute node
if [ $role = "Compute" ]; then
    cfg=$(curl -s http://$chef:4000/rpcs.cfg)
    eval $(grep "net_dmz\|net_bridge" <<< "$cfg")
fi

do_status 5 "Upgrading packages"
apt_it_up

do_status 10 "Installing chef client"
install_chef
disable_virbr0

do_status 11 "Dropping the knife config"
drop_knife_config

# Compute-specific stuff!
if [ $role = "Compute" ] || [ $role = "All-In-One" ]; then
    do_status 12 "Configuring interfaces"
    config_interfaces

    if [ -n "$net_dmz" ]; then
        do_status 13 "Adding DMZ routes"
        dmz_routes
    fi

    do_status 14 "Enabling bridge"
    ifup $net_bridge
fi

# Controller-specific stuff!
if [ $role = "Controller" ] || [ $role = "All-In-One" ]; then
    do_status 15 "Configuring controller node"
    setup_iptables

    do_status 20 "Grabbing the chef server VM (may take some time)"
    get_chef_qcow

    do_status 25 "Building chef server VM (may take some time)"
    build_chef_server

    do_status 50 "Starting chef server"
    virsh start chef-server 1>&9

    do_status 60 "Waiting for chef server to start up"
    port_test 10 30 $chef 22

    do_status 62 "Generating and copying ssh keys"
    generate_and_copy_ssh_keys

    do_status 70 "Waiting for API server to start"
    port_test 30 20 $chef 4000

    do_status 72 "Generating chef-client keys"
    generate_chef_keys

    do_status 80 "Downloading cookbooks"
    download_cookbooks

    do_status 85 "Uploading roles to chef"
    run_twice "upload_roles_to_chef"

    do_status 87 "Uploading cookbooks to chef"
    run_twice "upload_cookbooks_to_chef"
fi

do_status 90 "Getting the validation certificate"
get_validation_pem

do_status 91 "Registering node with chef server"
run_twice chef-client

assign_roles

if [ $role = "Controller" ] || [ $role = "All-In-One" ]; then
    create_environment_json
    # knife environment.do-it
    knife environment from_file /opt/rpcs/environment.json
else
    knife exec -E "nodes.find(:name => '$fqdn') {|n| n.set['nova']['network']['public_interface'] = '$net_public_iface'; n.save }"
fi

echo "Running chef-client to apply initial state ..."

run_twice "run_chef"

do_status 99 "Configuring chef-client upstart scripts"
setup_chef_initscripts
add_eula

do_status 99 "Finalizing setup"
# Clean up
sed -i '\/bin\/bash \/opt\/rpcs\/post-install.sh/d' /etc/rc.local

do_status 100 "Setup Complete!"

exit 0
