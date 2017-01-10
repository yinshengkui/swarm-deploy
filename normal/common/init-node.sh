#!/bin/bash

DEFAULT_IP=$( ifconfig eth0 | grep inet | awk '{{print $2}}' )

CLUSTER_STORE=${CLUSTER_STORE:-"zk://${DEFAULT_IP}:2181/default"}

CLUSTER_ADVERTISE=${CLUSTER_ADVERTISE:-"eth0:2376"}


rpm -i ../binary/acs-docker-1.11.1-5ec4436.x86_64.rpm

modprobe overlay openvswitch
echo "overlay" > /etc/modules-load.d/overlay.conf
echo "openvswitch" > /etc/modules-load.d/openvswitch.conf

echo "DOCKER_OPTS='--cluster-store=${CLUSTER_STORE} --cluster-advertise=${CLUSTER_ADVERTISE}'" > /etc/default/docker
