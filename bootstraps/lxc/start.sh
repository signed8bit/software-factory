#!/bin/bash
#
# Copyright (C) 2014 eNovance SAS <licensing@enovance.com>
#
# Licensed under the Apache License, Version 2.0 (the "License"); you may
# not use this file except in compliance with the License. You may obtain
# a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
# WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
# License for the specific language governing permissions and limitations
# under the License.

set -x
set -e

source ../functions.sh
. ./../../role_configrc

generate_sfconfig
DOMAIN=$(cat $SFCONFIGFILE | grep "^domain:" | cut -d' ' -f2)
SF_SUFFIX=${SF_SUFFIX:-$DOMAIN}
EDEPLOY_ROLES=${EDEPLOY_ROLES:-/var/lib/sf/roles/}
SSH_PUBKEY=${SSH_PUBKEY:-${HOME}/.ssh/id_rsa.pub}
export SF_SUFFIX

EDEPLOY_LXC=/srv/edeploy-lxc/edeploy-lxc
CONFDIR=/var/lib/lxc-conf

# Need to be select randomly
SSHPASS=$(generate_random_pswd 8)
JENKINS_USER_PASSWORD=$(generate_random_pswd 8)

ROLES_DIR=${BUILD_DIR}/install/${SF_VER}/

function get_ip {
    grep -B 1 "name:[ \t]*$1" sf-lxc.yaml | head -1 | awk '{ print $2 }'
}
function setup_iptables {
    set +e
    if [ "$1" = "down" ]; then
        switch="-D"
        # Disable NAT on the container hosts
        sudo iptables -t nat $switch POSTROUTING -o eth0 -j MASQUERADE
    fi
    if [ "$1" = "up" ]; then
        switch="-A"
        # Enable NAT on the container hosts (do not do that automatically)
        # sudo iptables -t nat $switch POSTROUTING -o eth0 -j MASQUERADE
    fi
    # Redirect host incoming TCP/80 to the sf gateway on 192.168.134.54/80
    sudo iptables -t nat $switch PREROUTING -p tcp -i eth0 --dport 80 -j DNAT --to-destination 192.168.134.54:80
    # Redirect host incoming TCP/29418 to the sf gateway on 192.168.134.54/29418 (a socat service listens 29418 to redirect internally to the Gerrit service)
    sudo iptables -t nat $switch PREROUTING -p tcp -i eth0 --dport 29418 -j DNAT --to-destination 192.168.134.54:29418
    # Redirect host incoming TCP/8080 and TCP/45452 to the sf gateway on 192.168.134.54 (a socat service listens 8080 and 45452 to redirect internally to the Jenkins service)
    # This is to allow jenkins swarm (slave) to SF via the gateway
    sudo iptables -t nat $switch PREROUTING -p tcp -i eth0 --dport 8080 -j DNAT --to-destination 192.168.134.54:8080
    sudo iptables -t nat $switch PREROUTING -p tcp -i eth0 --dport 45452 -j DNAT --to-destination 192.168.134.54:45452
    set -e
}

function init {
    sudo rm -rf ${CONFDIR}
    sudo mkdir -p ${CONFDIR}
    CONFDIR=$CONFDIR sudo -E bash -c 'chown $SUDO_USER:$SUDO_USER ${CONFDIR}'
    cp sf-lxc.yaml $CONFDIR
    cp ../cloudinit/* $CONFDIR
    jenkins_ip=`get_ip jenkins`
    managesf_ip=`get_ip managesf`
    # Complete the sf-lxc template used by edeploy-lxc tool
    sed -i "s/SF_SUFFIX/${SF_SUFFIX}/g" ${CONFDIR}/sf-lxc.yaml
    sed -i "s#CIPATH#${CONFDIR}#g" ${CONFDIR}/sf-lxc.yaml
    sed -i "s#SSH_PUBKEY#${SSH_PUBKEY}#g" ${CONFDIR}/sf-lxc.yaml
    sed -i "s#ROLES_DIR#${ROLES_DIR}#g" ${CONFDIR}/sf-lxc.yaml
    # Complete jenkins slave cloudinit
    sed -i "s/JENKINS_USER_PASSWORD/${JENKINS_USER_PASSWORD}/g" ${CONFDIR}/slave.cloudinit
    sed -i "s/JENKINS_IP/${jenkins_ip}/g" ${CONFDIR}/slave.cloudinit
    sed -i "s/MANAGESF_IP/${managesf_ip}/g" ${CONFDIR}/slave.cloudinit
    # Complete all the cloudinit templates
    sed -i "s/SF_SUFFIX/${SF_SUFFIX}/g" ${CONFDIR}/*.cloudinit
    sed -i "s/SSHPASS/${SSHPASS}/g" ${CONFDIR}/*.cloudinit
    sfconfigcontent=`cat $SFCONFIGFILE | base64 -w 0`
    sed -i "s|SFCONFIGCONTENT|${sfconfigcontent}|" $CONFDIR/puppetmaster.cloudinit
    for r in `echo $ROLES | sed s/puppetmaster//`; do
        ip=`get_ip $r`
        sed -i "s/${r}_host/$ip/g" ${CONFDIR}/puppetmaster.cloudinit
    done
    ip=`get_ip puppetmaster`
    sed -i "s/JENKINS_USER_PASSWORD/${JENKINS_USER_PASSWORD}/" ${CONFDIR}/puppetmaster.cloudinit
    sed -i "s/MY_PRIV_IP=.*/MY_PRIV_IP=$ip/" ${CONFDIR}/puppetmaster.cloudinit

    echo "Now running edeploy-lxc"
    sudo ${EDEPLOY_LXC} --config ${CONFDIR}/sf-lxc.yaml stop || exit -1

    # Let's add a default nameserver
    nameserver=`grep nameserver /etc/resolv.conf | head -1`
    sed -i -e "s/NAMESERVER/${nameserver}/g" ${CONFDIR}/*.cloudinit

    sudo ${EDEPLOY_LXC} --config ${CONFDIR}/sf-lxc.yaml start > /dev/null || exit -1
    setup_iptables 'up'
}

function destroy {
    [ -f "${CONFDIR}/sf-lxc.yaml" ] && sudo ${EDEPLOY_LXC} --config ${CONFDIR}/sf-lxc.yaml stop || echo
    sudo rm -Rf ${CONFDIR} || echo
    # make sure all lxc are shutdown
    for instance in $(sudo lxc-ls); do
        sudo lxc-stop --kill --name ${instance} || echo
        sudo lxc-destroy --name ${instance} || echo
    done
    setup_iptables 'down'
}

function stop {
    set +e
    for instance in $(sudo lxc-ls); do
        # The kill is not safe - need to figure out why a soft shutdown hang
        sudo lxc-stop --kill --name ${instance}
    done
    for instance in $(sudo lxc-ls); do
        sudo umount /var/lib/lxc/${instance}/rootfs
    done
    # Remove bridge
    bridge=$(grep bridge ${CONFDIR}/sf-lxc.yaml | awk 'FS=":" {print $2}')
    sudo ifconfig $bridge down
    sudo brctl delbr $bridge
    # Remove iptables rules
    setup_iptables 'down'
    set -e
}

function start {
    set +e
    # Add the bridge
    bridge=$(grep bridge ${CONFDIR}/sf-lxc.yaml | awk 'FS=":" {print $2}')
    gateway=$(grep gateway ${CONFDIR}/sf-lxc.yaml | awk 'FS=":" {print $2}')
    sudo brctl addbr $bridge
    sudo ifconfig $bridge $gateway
    # Mount rootfs
    base_aufs=$(grep aufs_dir ${CONFDIR}/sf-lxc.yaml | awk 'FS=":" {print $2}')
    roles_dir=$(grep " dir: " ${CONFDIR}/sf-lxc.yaml | awk 'FS=":" {print $2}')
    sudo mount -t aufs -o "br=${base_aufs}/puppetmaster:${roles_dir}/install-server-vm" none /var/lib/lxc/puppetmaster/rootfs
    for name in `echo $ROLES | sed s/puppetmaster//`; do
        sudo mount -t aufs -o "br=${base_aufs}/${name}:${roles_dir}/softwarefactory" none /var/lib/lxc/${name}/rootfs
    done
    # Start LXC containers
    for name in mysql puppetmaster; do
        sudo lxc-start -d -L /var/log/lxc$name.log --name $name;
    done
    sleep 20
    for name in gerrit jenkins managesf redmine slave; do
        sudo lxc-start -d -L /var/log/lxc$name.log --name $name
    done
    # Start iptables rules
    setup_iptables 'up'
    set -e
}

function restart {
    stop
    start
}

case $1 in
    init)
        init;;
    destroy)
        destroy;;
    start)
        start;;
    stop)
        stop;;
    restart)
        stop
        start
        ;;
    *)
        echo "usage: $0 [init|destroy|start|stop|restart]";;
esac

exit 0
