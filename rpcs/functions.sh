date_string="%a, %d %b %Y %X %z"

# return the integer part of a float
function get_float() {
  local numerator=$1
  local denominator=$2
  if [ $denominator -eq 0 ]; then
    # echo div by 0
    echo "0"
  else
    result=$((($numerator*100)/$denominator))
    echo $result
  fi
}

function find_in_array() {
    local val=$1
    local count=0
    for i in ${run_list_array[@]}; do
        if [ "$i" = "$val" ]; then
            echo $count
            return
        fi
        count=$(($count + 1))
    done
    echo "-1"
    return
}

function fixup_array() {
    local count=0
    for i in ${run_list_array[@]}; do
        if [[ ! "$i" == *::* ]]; then
                run_list_array[$count]="${run_list_array[$count]}::default"
        fi
        count=$(($count + 1))
    done;
}

function destroy_in_array() {
    local pos=$1
    run_list_array[$pos]=$pos
}

function dump_array() {
    for i in ${run_list_array[@]}; do
        echo "run_list_array: $i"
    done;
}

function do_substatus_close() {
    echo "SUBSTATUS_CLOSE" > ${STATUS_FIFO}
}

function do_substatus() {
    echo "[$(date +"$date_string")] [-] [$1] $2 [$3]"
    echo "SUBSTATUS $1 \"$2\" \"$3\"" > ${STATUS_FIFO}
}

function do_status() {
    echo "[$(date +"$date_string")] [$1] $2"
    echo "STATUS $1 \"$2\"" > ${STATUS_FIFO}
}

function do_complete() {
    echo "COMPLETE" > ${STATUS_FIFO}
}

function do_exit() {
    local status=$?

    echo "Entering the do_exit error handler"

    # if we are running under NOCLEAN, do not clean up anything.
    if [ "${NOCLEAN-0}" == "1" ]; then
        exit ${status}
    fi

    trap - ERR EXIT SIGINT SIGTERM
    set +e

    if [ "${status}" -ne 0 ]; then
        do_status 99 "Oops - we encountered an error"
        do_substatus 10 "Cleaning up chef" "error"
        rm -rf /etc/chef
        rm -rf /root/.chef
        if [ $role = "Compute" ] || [ $role = "All-In-One" ]; then
            do_substatus 15 "Cleaning up routing" "error"
            ifdown $net_bridge
            rm /etc/network/if-up.d/dmz
        fi

        if [ $role = "Controller" ] || [ $role = "All-In-One" ]; then
            # on failure remove all the bits from the controller
            rm -rf /root/.ssh
            rm -rf /opt/rpcs/chef-server.xml
            do_substatus 20 "Destroying the chef-server" "error"
            virsh destroy chef-server
            virsh undefine chef-server
            rm -f /opt/rpcs/chef-server.qcow2
            rm -rf /opt/rpcs/chef-cookbooks
            do_substatus 30 "Uninstalling mysql" "error"
            apt-get -y purge `dpkg -l | grep mysql | awk '{print $2}'`
            do_substatus 40 "Uninstalling keystone" "error"
            apt-get -y purge `dpkg -l | grep keystone | awk '{print $2}'`
            do_substatus 50 "Uninstalling glance" "error"
            apt-get -y purge `dpkg -l | grep glance | awk '{print $2}'`
            do_substatus 60 "Cleaning up configuration files" "error"
            rm -rf /root/.my.cnf
            rm -rf /etc/mysql/grants.sql
            rm -rf /var/lib/mysql
            rm -rf /opt/rpcs/chef-cookbooks
            rm -rf /var/chef
            rm -f /var/cache/local/preseeding/mysql-server.seed
            rm -rf /etc/glance /var/lib/glance
            rm -rf /etc/keystone
        fi
        do_substatus 80 "Uninstalling nova" "error"
        apt-get -y purge `dpkg -l | grep nova | awk '{print $2}'`
        rm -rfv /etc/nova /var/lib/nova/ /var/log/nova/
        do_substatus 90 "Purging packages" "error"
        apt-get -y autoremove
        dpkg -P -a
        echo purge | debconf-communicate mysql-server-5.0
        echo purge | debconf-communicate mysql-server-5.5
        do_substatus_close
    else
        # clean exit
        mv /opt/rpcs/post-install.sh /opt/rpcs/post-install.sh.original
        chmod 600 /opt/rpcs/post-install.sh.original
    fi
    echo ${status} > /opt/rpcs/.status

    do_complete
    rm -f ${STATUS_FIFO}
    # do any other cleanup here.

    exit ${status}
}

function run_twice() {
    local cmd_to_run="$@"
    if ! $cmd_to_run; then
        # try it again!
        sleep 10
        $cmd_to_run
    fi
}

function install_chef() {
    # Make it so
    echo chef chef/chef_server_url string http://$chef:4000 | debconf-set-selections
    mkdir -p /etc/chef
    if [ ! -e /opt/rpcs/chef-full.deb ]; then
        run_twice curl -L http://opscode.com/chef/install.sh | bash 1>&9
    else
        dpkg -i /opt/rpcs/chef-full.deb 1>&9
    fi
    cat >> /etc/chef/client.rb <<EOF
    chef_server_url "http://${chef}:4000"
    environment "rpcs"
EOF
}

function disable_virbr0 {
    # Disable default virbr0 network
    virsh net-autostart default --disable 1>&9
    if virsh net-list | grep -q default; then
        echo "Disabling default libvirt network ..."
        virsh net-destroy default 1>&9
    fi
}

function dmz_routes {
    local dmzfile=/etc/network/if-up.d/dmz

    cat > "$dmzfile" <<EOF
#!/bin/sh

if [ \$IFACE = $net_bridge ]; then

EOF
    for dmz in $net_dmz; do
        echo "    ip route add $dmz via $net_dmz_gw dev $net_bridge onlink" >> "$dmzfile"
    done

    echo "fi" >> "$dmzfile"
    chmod +x "$dmzfile"
}

function config_interfaces {
    if ! grep -q "$net_bridge" /etc/network/interfaces; then
        cat >> /etc/network/interfaces << EOF

auto $net_bridge
iface $net_bridge inet manual
    bridge_ports $([ $net_private_iface = $net_public_iface ] && echo none || echo $net_private_iface)
EOF
    fi
}

function setup_iptables {
    # Enable forwarding
    sed -i '/net.ipv4.ip_forward/ s/^#//' /etc/sysctl.conf
    sysctl -p /etc/sysctl.conf 1>&9

    # Add iptables rule...
    if ! iptables -t nat -nvL PREROUTING | grep -q 4000; then
        iptables -t nat -A PREROUTING -s $net_mgmt -p tcp --dport 4000 -j DNAT --to-dest 169.254.123.2
    fi

    if ! iptables -t nat -nvL POSTROUTING | grep -q MASQUERADE; then
        iptables -t nat -A POSTROUTING -o $net_public_iface -j MASQUERADE
    fi

    # ...and make persistent
    echo iptables-persistent iptables-persistent/autosave_v4 select true | debconf-set-selections
    echo iptables-persistent iptables-persistent/autosave_v6 select true | debconf-set-selections
    run_twice apt-get -y install iptables-persistent 1>&9
}

function get_chef_qcow {
    do_substatus 10 "Downloading the pristine chef-server image" "chef-server"
    # Get the chef-server image
    if [ ! -e /opt/rpcs/chef-server.qcow2.pristine ]; then
        run_twice wget -nv -O /opt/rpcs/chef-server.qcow2.pristine http://@CHEF_IMAGE_HOST@/chef-server.qcow2
    fi
    do_substatus 20 "Copying pristine chef-server image" "chef-server"
    if [ ! -e /opt/rpcs/chef-server.qcow2 ]; then
        cp /opt/rpcs/chef-server.qcow2.pristine /opt/rpcs/chef-server.qcow2
    fi
}

function build_chef_server {
    # Drop the definition in
    do_substatus 30 "Building the chef-server definition" "chef-server"
    if [ ! -e /opt/rpcs/chef-server.xml ]; then
        cat > /opt/rpcs/chef-server.xml << EOF
<domain type='${qemu_domain_type}'>
  <name>chef-server</name>
  <memory>2097152</memory>
  <currentMemory>2097152</currentMemory>
  <vcpu>2</vcpu>
  <os>
    <type arch='x86_64' machine='pc-0.12'>hvm</type>
    <boot dev='hd'/>
  </os>
  <features>
    <acpi/>
    <apic/>
    <pae/>
  </features>
  <clock offset='utc'/>
  <on_poweroff>destroy</on_poweroff>
  <on_reboot>restart</on_reboot>
  <on_crash>restart</on_crash>
  <devices>
    <emulator>${qemu_emulator}</emulator>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2' cache='unsafe'/>
      <source file='/opt/rpcs/chef-server.qcow2'/>
      <target dev='vda' bus='virtio'/>
      <alias name='virtio-disk0'/>
      <address type='pci' domain='0x0000' bus='0x00' slot='0x05' function='0x0'/>
    </disk>
    <interface type='bridge'>
      <source bridge='chefbr0'/>
      <target dev='vnet0'/>
      <model type='virtio'/>
      <alias name='net0'/>
    </interface>
    <serial type='pty'>
      <target port='0'/>
      <alias name='serial0'/>
    </serial>
    <console type='pty' tty='/dev/pts/1'>
      <target type='serial' port='0'/>
      <alias name='serial0'/>
    </console>
    <input type='mouse' bus='ps2'/>
    <graphics type='vnc' listen='0.0.0.0' autoport='yes'/>
    <sound model='ac97'>
      <alias name='sound0'/>
      <address type='pci' domain='0x0000' bus='0x00' slot='0x04' function='0x0'/>
    </sound>
    <video>
      <model type='cirrus' vram='9216' heads='1'/>
      <model type='cirrus' vram='9216' heads='1'/>
      <alias name='video0'/>
      <address type='pci' domain='0x0000' bus='0x00' slot='0x02' function='0x0'/>
    </video>
    <memballoon model='virtio'>
      <alias name='balloon0'/>
      <address type='pci' domain='0x0000' bus='0x00' slot='0x06' function='0x0'/>
    </memballoon>
  </devices>
</domain>
EOF
    fi

    # Create private bridge for Chef
    do_substatus 35 "Creating private bridge for Chef ..." "chef-server"
    if ! grep -q "chefbr0" /etc/network/interfaces; then
        cat >> /etc/network/interfaces << EOF

auto chefbr0
iface chefbr0 inet static
      address 169.254.123.1
      netmask 255.255.255.0
      bridge_ports none
      bridge_fd 0
      bridge_stp off
      bridge_maxwait 0

EOF
    fi

    # And bring it up
    do_substatus 39 "Bringing up chefbr0 ..." "chef-server"
    if ! /sbin/ifconfig | grep -q "chefbr0"; then
        ifup chefbr0 > /dev/null 2>&1
    fi

    # Remove existing image if any
    do_substatus 40 "Removing the existing chef-server" "chef-server"
    if virsh list | grep -q chef-server; then
        virsh destroy chef-server 1>&9
    fi

    # Un-Define image and kick it
    do_substatus 50 "Undefining the existing chef-server" "chef-server"
    if virsh list --all | grep -q chef-server; then
        virsh undefine chef-server 1>&9
    fi

    # Define image and kick it
    do_substatus 60 "Creating the existing chef-server" "chef-server"
    virsh define /opt/rpcs/chef-server.xml 1>&9
    virsh autostart chef-server 1>&9

    do_substatus_close
}

function port_test() { # $1 delay, $2 max, $3 host, $4 port
    local count=1
    while (( $count <= $2 )); do
        do_substatus $(get_float $count $2) "Waiting for $3:$4 to become available (try $count of $2)" "port-test"
        if nc -w 1 -q 0 $3 $4  < /dev/null &> /dev/null; then
            do_substatus_close
            break
        fi
        sleep $1
        count=$(($count + 1))
    done
}

function generate_and_copy_ssh_keys {
    do_substatus 10 "Generating new SSH key" "ssh-keys"
    mkdir -p .ssh; chmod 0700 .ssh
    ssh-keygen -q -f .ssh/id_rsa -N ''
    cat > .ssh/known_hosts << "EOF"
|1|IDUzyhtkjSOlIdtFsTniYm7JJvA=|UGu+9OaDzOMhgL+tr+aNEOmkd98= ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBMHsA41RW2BGZS9osE5JvfxcZchz+W57PVqul8THkIQVehqoWxzMJkq16RQxylpV22EUXSiBj1bfKhy2/dkkpn4=
|1|RwkLZbV+0oIX4vCDsr7mWVRs1gc=|U2e6O501zzVFJ3dFkHdN/ZCp+Ko= ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBMHsA41RW2BGZS9osE5JvfxcZchz+W57PVqul8THkIQVehqoWxzMJkq16RQxylpV22EUXSiBj1bfKhy2/dkkpn4=
|1|eE+nAqfyigLQhi+nd/VkTUmbss0=|GFCPoZvEPOUcDdQEma8/7QILaNU= ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBMHsA41RW2BGZS9osE5JvfxcZchz+W57PVqul8THkIQVehqoWxzMJkq16RQxylpV22EUXSiBj1bfKhy2/dkkpn4=
EOF

    do_substatus 20 "Copying new key in ..." "ssh-keys"
    sshpass -p demo ssh-copy-id -i .ssh/id_rsa.pub rack@$chef 1>&9

    do_substatus 30 "Setting new password ..." "ssh-keys"
    ssh rack@$chef "sudo chpasswd" <<< "rack:$(pwgen -s 12 1)"
}

function drop_knife_config {
    # Reregister chef clients and snag keys for local use
    mkdir -p .chef
    cat > .chef/knife.rb << EOF
log_level                :info
log_location             STDOUT
node_name                '$fqdn'
client_key               '/etc/chef/client.pem'
validation_client_name   'chef-validator'
validation_key           '/etc/chef/validation.pem'
chef_server_url          'http://${chef}:4000'
cache_type               'BasicFile'
cache_options( :path => '/etc/chef/checksums' )
cookbook_path            '/opt/rpcs/chef-cookbooks/cookbooks'
EOF
}

function generate_chef_keys {
    ssh rack@$chef "sudo sh -c 'cat > /usr/share/chef-server-api/public/rpcs.cfg'; knife client reregister rack -f .chef/rack.pem; knife client reregister chef-validator -f .chef/validation.pem; sudo cp .chef/validation.pem /usr/share/chef-server-api/public; sudo chmod +r /usr/share/chef-server-api/public/*; yes | knife client delete $fqdn &> /dev/null; knife environment create -d rpcs &>/dev/null; knife client create $fqdn -d -a" < /opt/rpcs/rpcs.cfg | tail -n+2 > /etc/chef/client.pem
}

function initialize_submodules() {
    do_status 81 "Initializing Sub Modules"
    local count=0
    OLD_IFS=$IFS
    while read line; do
        count=$(($count + 1))
    done < <(git submodule init 2>&9)
    do_substatus_close
    total_cookbooks=$count
}

function update_submodules() {
    set -o pipefail
    do_status 82 "Updating Sub Modules"
    OLD_IFS=$IFS
    IFS="'"
    local count=0
    git submodule update 2>&9 | tee >(while read line; do
        if [[ "$line" == Cloning* ]]; then
            count=$(($count + 1))
            submod_cookbook=$(echo $line | awk '{print $3}' | sed 's/^cookbooks\///g')
            do_substatus $(get_float $count $total_cookbooks) "Checking out cookbook $submod_cookbook" "update"
        fi
    done) 1>&9
    result=$?
    IFS=$OLD_IFS
    do_substatus_close
    set +o pipefail
    return $result
}

function download_cookbooks {
    # grab cookbooks
    apt-get install -y git 1>&9

    pushd /root
    if [ ! -e /opt/rpcs/cookbooks ]; then
        run_twice git clone http://github.com/rcbops/chef-cookbooks /opt/rpcs/chef-cookbooks 1>&9
        cd /opt/rpcs/chef-cookbooks
        run_twice git checkout iso 1>&9

        run_twice "initialize_submodules"

        run_twice "update_submodules"
    fi
    popd
}

function upload_roles_to_chef() {
    set -o pipefail
    role_count=$(ls -1 /opt/rpcs/chef-cookbooks/roles/*.rb | wc -l)
    local count=0
    knife role from file /opt/rpcs/chef-cookbooks/roles/*.rb | tee >(while read line; do
        count=$(($count + 1))
        role_name=$(echo $line | awk '{print $3}' | sed 's/\!//g')
        do_substatus $(get_float $count $role_count) "Uploading role $role_name to chef" "upload"
    done) 1>&9
    result=$?
    do_substatus_close
    set +o pipefail
    return $result
}

function upload_cookbooks_to_chef() {
    set -o pipefail
    cookbook_count=$(find /opt/rpcs/chef-cookbooks/cookbooks -maxdepth 2 -name metadata.rb | wc -l)
    local count=0
    knife cookbook upload -a | tee >(while read line; do
        if [[ "$line" == Uploading* ]]; then
            count=$(($count + 1))
            cookbook_name=$(echo $line | awk '{print $2}' | sed 's/\!//g')
            do_substatus $(get_float $count $cookbook_count) "Uploading cookbook $cookbook_name to chef" "upload"
        fi
    done) 1>&9
    result=$?
    do_substatus_close
    set +o pipefail
    return $result
}

function get_validation_pem() {
    echo "Grabbing validation.pem from chef-server ..."
    wget -nv http://${chef}:4000/validation.pem -O /etc/chef/validation.pem
}

function commafy {
    # $* = space-separated list of words
    echo $(IFS=,; echo "$*")
}

function create_environment_json() {
    cat >/opt/rpcs/environment.json << EOF
{
  "name": "rpcs",
  "description": "",
  "cookbook_versions": {
  },
  "json_class": "Chef::Environment",
  "chef_type": "environment",
  "default_attributes": {
    "mysql": {
      "allow_remote_root": true,
      "root_network_acl": "%"
    },
    "nova": {
      "network": {
          "public_interface": "%net_public_iface"
      }
    }
  },
  "override_attributes": {
    "developer_mode": false,
    "monitoring" : { "procmon_provider" : "none" },
    "keystone" : {
      "tenants" : [ "admin", "service", "%os_user_name" ],
      "admin_user" : "admin",
      "users" : {
        "admin" : {
          "password" : "%os_admin_passwd",
          "roles" : {
            "admin" : [ "admin", "%os_user_name" ]
          }
        },
        "%os_user_name" : {
          "password" : "%os_user_passwd",
          "default_tenant" : "%os_user_name",
          "roles" : {
            "Member" : [ "%os_user_name" ]
          }
        }
      }
    },
    "glance": {
      "images": [
        "cirros",
        "precise"
      ],
      "image_upload": true
    },
    "nova": {
      "network": {
          "fixed_range": "%net_fixed",
          "dmz_cidr": "%net_dmz"
      },
      "apply_patches": true,
      "networks": [
        {
          "bridge_dev": "%net_private_iface",
          "num_networks": "1",
          "network_size": "%net_size",
          "bridge": "%net_bridge",
          "ipv4_cidr": "%net_fixed",
          "label": "public",
          "dns1": "8.8.8.8",
          "dns2": "8.8.4.4"
        }
      ]
    },
    "osops_networks": {
      "management": "%net_mgmt",
      "nova": "%net_nova",
      "public": "%net_public"
    },
    "enable_monit": true
  }
}
EOF

    # replace values from config vars?
    net_cidr="$(echo $net_fixed | cut -d/ -f2)"
    net_size=$(( 2 ** (32 - net_cidr)-2 ))
    net_dmz=$(commafy $(echo ${net_dmz:-10.128.0.0/24}))
    for v in $(cat /opt/rpcs/rpcs.cfg | cut -d= -f1) net_size; do
        sed -i "s^%${v}^${!v}^" /opt/rpcs/environment.json
    done
}


function assign_roles() {
    if [ $role = "All-In-One" ]; then
        knife node run_list add $fqdn "role[single-controller]"
        knife node run_list add $fqdn "role[single-compute]"
    else
        knife node run_list add $fqdn "role[single-${role,,}]"
    fi
}


function run_chef() {
    set -o pipefail
    do_status 95 "Running chef: This can take a while.."

    local counter=0
    chef-client | tee >(while read line; do
        if [[ "$line" == *"Run List expands to"* ]]; then
            declare -a run_list_array=($(echo $line | cut -d "[" -f 3 | cut -d "]" -f 1 | sed 's/,//g'))
            run_list_count=${#run_list_array[@]}
            fixup_array
        elif [[ "$line" == *"INFO: Processing"*::* ]]; then
            cookbook=$(echo $line | cut -d "(" -f 2 | cut -d " " -f 1)
            position=$(find_in_array $cookbook)
            if [ "$position" != "-1" ]; then
                do_substatus $(get_float $counter $run_list_count) "Processing $cookbook" "chef-client"
                destroy_in_array $position
                counter=$(($counter + 1))
            fi
        fi
    done)

    result=$?
    IFS=$OLD_IFS
    do_substatus_close
    set +o pipefail
    return $result
}

function setup_chef_initscripts() {
    echo "setting up chef-client init scripts..."
    cp /opt/chef/embedded/lib/ruby/gems/1.9.1/gems/chef-10.12.0/distro/debian/etc/init/chef-client.conf /etc/init/chef.conf
    cp /opt/chef/embedded/lib/ruby/gems/1.9.1/gems/chef-10.12.0/distro/debian/etc/default/chef-client /etc/default/chef-client
    cp /opt/chef/embedded/lib/ruby/gems/1.9.1/gems/chef-10.12.0/distro/debian/etc/init.d/chef-client /etc/init.d/chef-client
    mkdir -p /var/log/chef
    /etc/init.d/chef-client start
}

function add_eula() {
    # Link EULA to user home dir
    USERDIR=$(getent passwd 1000 | cut -d : -f6)
    if [ -e $USERDIR/RPCS_EULA.txt ]; then rm -f $USERDIR/RPCS_EULA.txt; fi
    ln -s /usr/share/doc/RPCS_EULA.txt $USERDIR/RPCS_EULA.txt
}

function apt_it_up() {
    do_substatus 33 "running apt-get update" "apt"
    run_twice apt-get update 1>&9
    do_substatus 66 "running apt-get upgrade" "apt"
    run_twice apt-get -y upgrade 1>&9
    do_substatus_close
}
