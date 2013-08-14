date_string="%a, %d %b %Y %X %z"
git_string=""
knife=/usr/bin/knife


function pwgen() {
    local length=${1:-8}
    tr -dc A-Za-z0-9_ < /dev/urandom | head -c ${length}
    echo # append \n
}

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

function set_git_proxy() {
    if [ -n "${http_proxy}" ]; then
        HOME=/root git config --global http.proxy ${http_proxy} || :
        git_string="-c http.proxy=${http_proxy}"
    fi
}

function set_chef_proxy() {
    if [ -n "${http_proxy}" ]; then
        echo "http_proxy \"${http_proxy}\"" >> /etc/chef/client.rb
        #echo "no_proxy \"169.254.*\"" >> /etc/chef/client.rb
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
            # rm -rf /opt/rpcs/chef-server.xml
            # do_substatus 20 "Destroying the chef-server" "error"
            # virsh destroy chef-server
            # virsh undefine chef-server
            # rm -f /opt/rpcs/chef-server.qcow2
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

function install_chef_client() {
    # Make it so
    #echo chef chef/chef_server_url string https://$chef:443 | debconf-set-selections
    mkdir -p /etc/chef

    CLIENT_VERSION=${CLIENT_VERSION:-"11.2.0-1"}
    CHEF_URL=${CHEF_URL:-https://$chef:4000}
    ENVIRONMENT=${ENVIRONMENT:-rpcs}

    sudo apt-get install -y curl
    curl -skS -L http://www.opscode.com/chef/install.sh | bash -s - -v ${CLIENT_VERSION} 1>&9
    mkdir -p /etc/chef

    #chef-client config file
    cat <<EOF2 > /etc/chef/client.rb
Ohai::Config[:disabled_plugins] = ["passwd"]
chef_server_url "${CHEF_URL}"
chef_environment "${ENVIRONMENT}"
EOF2
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
#    if ! iptables -t nat -nvL PREROUTING | grep -q 4000; then
#        iptables -t nat -A PREROUTING -s $net_mgmt -p tcp --dport 4000 -j DNAT --to-dest 169.254.123.2
#    fi

    if ! iptables -t nat -nvL POSTROUTING | grep -q MASQUERADE; then
        iptables -t nat -A POSTROUTING -o $net_public_iface -j MASQUERADE
    fi

    # ...and make persistent
    echo iptables-persistent iptables-persistent/autosave_v4 select true | debconf-set-selections
    echo iptables-persistent iptables-persistent/autosave_v6 select true | debconf-set-selections
    run_twice apt-get -y install iptables-persistent 1>&9
}

function install_git(){
    apt-get install -y git 1>&9
}

function setup_chef_validation_key_distribution_service(){
  apt-get install -y xinetd 1>&9
  cat > /etc/xinetd.d/chefgetvalidation <<END_XINTED_CONFIG
service chefgetvalidation
{
  disable           = no
  socket_type       = stream
  type              = UNLISTED
  protocol          = tcp
  port              = 7777
  wait              = no
  user              = root
  server            = /bin/cat
  server_args       = /etc/chef-server/chef-validator.pem
}
END_XINTED_CONFIG
stop xinetd; start xinetd
}

function wait_for_key_distribution_service(){
    port_test 30 20 localhost 7777
}

function install_rabbit_mq(){
  apt-get install -y rabbitmq-server
  /etc/init.d/rabbitmq-server restart
}

function wait_for_rabbit(){
  port_test 30 20 localhost 5672
}

get_rabbit_chef_password(){
  pw_file=/opt/rpcs/.CHEF_RMQ_PW
  if [ -e $pw_file ];
  then
    export CHEF_RMQ_PW="$(cat $pw_file)"
  else
    export CHEF_RMQ_PW="$(pwgen 16)"
    echo "$CHEF_RMQ_PW" >/opt/rpcs/.CHEF_RMQ_PW
  fi
}

function configure_rabbit_for_chef(){
  vhost="/chef"
  user="chef"
  rabbitmqctl list_vhosts |grep -q $vhost \
    || rabbitmqctl add_vhost /chef

  rabbitmqctl list_users |grep -q $user \
    && rabbitmqctl delete_user chef
  rabbitmqctl add_user chef "$CHEF_RMQ_PW"

  rabbitmqctl set_permissions -p $vhost $user '.*' '.*' '.*'

}

function test_rabbit_chef(){
  amqping=/opt/rpcs/amqping.py
  apt-get install -y python-pip
  pip install pika
  python $amqping -u chef -v chef -p "$CHEF_RMQ_PW"
}

function install_chef_server(){
  echo "\$HOME=$HOME"
  [ -z $HOME ] && export HOME=/opt/chef-server/embedded

  do_substatus 0 "Installing Chef Server Debian package"

  dpkg -l chef-server 2>/dev/null|grep -q ^ii \
    || dpkg -i /opt/rpcs/chef-server.deb

  mkdir -p /etc/chef-server

  #Initial chef-server config to disable rabbit.

  cat > /etc/chef-server/chef-server.rb <<EOF
nginx["ssl_port"] = 4000
nginx["non_ssl_port"] = 4080
nginx["enable_non_ssl"] = true
rabbitmq["enable"] = false
rabbitmq["password"] = "$CHEF_RMQ_PW"
bookshelf['url'] = "https://#{node['ipaddress']}:4000"
EOF

  do_substatus 50 "Chef Server initial configuration"

  chef-server-ctl reconfigure ||: #first run will fail

  # Change rabbit password in chef JSON secrets file.
  python <<EOP
import json
path="/etc/chef-server/chef-server-secrets.json"
hash=json.load(open(path))
hash["rabbitmq"]["password"]="$CHEF_RMQ_PW"
open(path,"w").writelines(
  json.dumps(hash,sort_keys=True,indent=4, separators=(",", ": "))
)
EOP

  do_substatus 90 "Configuring Chef Server for external RabbitMQ"

  # Run chef-solo to configure chef server
  chef-server-ctl reconfigure ||:
  chef-server-ctl reconfigure

  export HOME=/root

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

function drop_knife_config {
    pushd /root
    mkdir -p .chef
    cat > .chef/knife.rb << EOF
log_level                :info
log_location             STDOUT
node_name                '$fqdn'
client_key               '/etc/chef/client.pem'
validation_client_name   'chef-validator'
validation_key           '/etc/chef/validation.pem'
chef_server_url          'https://${chef}:4000'
cache_type               'BasicFile'
cache_options( :path => '/etc/chef/checksums' )
cookbook_path            '/opt/rpcs/chef-cookbooks/cookbooks'
EOF
  popd
}

function generate_chef_keys {
    # Admin creds for creating new clients and environments.
    knife_admin="--user admin --key /etc/chef-server/admin.pem"

    # Delete existing client
    $knife client list $knife_admin|grep -q $fqdn \
      && $knife client delete $fqdn -y $knife_admin||true

    # Create new admin client, and environment
    $knife client create $fqdn -d -a $knife_admin > /etc/chef/client.pem
    $knife environment list |grep -q rpcs \
      ||$knife environment create -d rpcs &>/dev/null
}

function initialize_submodules() {
    do_status 81 "Initializing Sub Modules"
    local count=0
    while read line; do
        count=$(($count + 1))
    done < <(git ${git_string} submodule init 2>&9)
    do_substatus_close
    total_cookbooks=$count
}

function update_submodules() {
    set -o pipefail
    do_status 82 "Updating Sub Modules"
    local count=0
    git ${git_string} submodule update 2>&9 | tee >(while read line; do
        if [[ "$line" == Cloning* ]]; then
            count=$(($count + 1))
            submod_cookbook=$(echo $line | awk '{print $3}' | sed 's/^cookbooks\///g')
            do_substatus $(get_float $count $total_cookbooks) "Checking out cookbook $submod_cookbook" "update"
        fi
    done) 1>&9
    result=$?
    do_substatus_close
    set +o pipefail
    return $result
}

function download_cookbooks {
    # grab cookbooks

    set_git_proxy

    pushd /root
    if [ ! -e /opt/rpcs/chef-cookbooks ]; then
        run_twice git ${git_string} clone http://github.com/rcbops/chef-cookbooks /opt/rpcs/chef-cookbooks 1>&9
        cd /opt/rpcs/chef-cookbooks
        run_twice git ${git_string} checkout master 1>&9

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
    nc $chef 7777 > /etc/chef/validation.pem
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
    "monitoring" : {
      "procmon_provider" : "monit",
      "metric_provider" : "collectd"
    },
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
      "image" : {
        "precise" : "%precise_url",
        "cirros" : "%cirros_url"
      },
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
    "horizon": { "theme": "Rackspace" },
    "package_component": "folsom"
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
    # All nodes get these roles
    knife node run_list add $fqdn "role[collectd-client]"

    # Role specific, errr roles.
    case $role in
      All-In-One|Controller)
        knife node run_list add $fqdn "role[ha-controller1]"
        knife node run_list add $fqdn "role[collectd-server]"
        knife node run_list add $fqdn "role[graphite]"
      ;;
      All-In-One|Compute)
        knife node run_list add $fqdn "role[single-compute]"
      ;;
    esac
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
    do_substatus_close
    set +o pipefail
    return $result
}

function setup_chef_initscripts() {
    echo "setting up chef-client init scripts..."
    cp `find /opt/chef/embedded -print | grep "debian.*init/chef-client.conf" | head -n1` /etc/init/chef-client.conf
    cp `find /opt/chef/embedded -print | grep "debian.*default/chef-client" | head -n1` /etc/default/chef-client
    ln -s /lib/init/upstart-job /etc/init.d/chef-client
    /usr/sbin/update-rc.d chef-client defaults
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
