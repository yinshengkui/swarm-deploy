#!/bin/bash

# Copyright 2016 The swarmrnetes Authors All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

cd "$(dirname "${BASH_SOURCE}")"
source docker-bootstrap.sh

swarm::multinode::main(){

  # Require root
  if [[ "$(id -u)" != "0" ]]; then
    swarm::log::fatal "Please run as root"
  fi

  for tool in curl ip docker; do
    if [[ ! -f $(which ${tool} 2>&1) ]]; then
      swarm::log::status "The binary ${tool} is required. Install it..."
      yum install -y ${tool}
    fi
  done

  # Make sure docker daemon is running
  if [[ $(docker ps 2>&1 1>/dev/null; echo $?) != 0 ]]; then
    swarm::log::fatal "Docker is not running on this machine!"
  fi


  CURRENT_PLATFORM=$(swarm::helpers::host_platform)
  ARCH=${ARCH:-${CURRENT_PLATFORM##*/}}
  swarm::log::status "ARCH is set to: ${ARCH}"

  SWARM_VERSION=${SWARM_VERSION:-1.2.5}
  swarm::log::status "SWARM_VERSION is set to: ${SWARM_VERSION}"
  ETCD_VERSION=${ETCD_VERSION:-"3.0.4"}
  swarm::log::status "ETCD_VERSION is set to: ${ETCD_VERSION}"
  ZK_VERSION=${ZK_VERSION:-3.4.6}
  swarm::log::status "ZK_VERSION is set to: ${ZK_VERSION}"

  #FLANNEL_VERSION=${FLANNEL_VERSION:-"v0.6.1"}
  #FLANNEL_IPMASQ=${FLANNEL_IPMASQ:-"true"}
  #FLANNEL_BACKEND=${FLANNEL_BACKEND:-"udp"}
  #FLANNEL_NETWORK=${FLANNEL_NETWORK:-"10.1.0.0/16"}

  BIP=${SUBNET:-"10.1.1.0/24"}
  swarm::log::status "BIP is set to: ${BIP}"

  MTU=${MTU:-"1472"}
  swarm::log::status "MTU is set to: ${MTU}"

  # RESTART_POLICY=${RESTART_POLICY:-"unless-stopped"}

#  DEFAULT_IP_ADDRESS=$(ip -o -4 addr list $(ip -o -4 route show to default | awk '{print $5}' | head -1) | awk '{print $4}' | cut -d/ -f1 | head -1)
  DEFAULT_IP_ADDRESS=$( ifconfig eth0 | grep inet | awk '{{print $2}}' )
  IP_ADDRESS=${IP_ADDRESS:-${DEFAULT_IP_ADDRESS}}
  swarm::log::status "IP_ADDRESS is set to: ${IP_ADDRESS}"

  TIMEOUT_FOR_SERVICES=${TIMEOUT_FOR_SERVICES:-20}

  BOOTSTRAP_DOCKER_SOCK="unix:///var/run/docker-bootstrap.sock"
  BOOTSTRAP_DOCKER_PARAM="-H ${BOOTSTRAP_DOCKER_SOCK}"


}


swarm::multinode::start_zookeeper() {

  swarm::log::status "Launching zookeeper..."

  # TODO: Remove the 4001 port as it is deprecated
  docker ${BOOTSTRAP_DOCKER_PARAM} run -d \
    --name swarm_zk_$(swarm::helpers::small_sha) \
    --restart=always \
    --net=host  \
    -v /var/lib/zookeeper/data:/data \
    -v /var/lib/zookeeper/datalog:/datalog \
    jplock/zookeeper:${ZOOKEEPER_VERSION} 


}


# Start etcd on the master node
swarm::multinode::start_etcd() {

  swarm::log::status "Launching etcd..."

  # TODO: Remove the 4001 port as it is deprecated
  docker ${BOOTSTRAP_DOCKER_PARAM} run -d \
    --name swarm_etcd_$(swarm::helpers::small_sha) \
    --restart=${RESTART_POLICY} \
    ${ETCD_NET_PARAM} \
    -v /var/lib/swarmlet/etcd:/var/etcd \
    gcr.io/google_containers/etcd-${ARCH}:${ETCD_VERSION} \
    /usr/local/bin/etcd \
      --listen-client-urls=http://0.0.0.0:2379,http://0.0.0.0:4001 \
      --advertise-client-urls=http://localhost:2379,http://localhost:4001 \
      --listen-peer-urls=http://0.0.0.0:2380 \
      --data-dir=/var/etcd/data

  # Wait for etcd to come up
  local SECONDS=0
  while [[ $(curl -fsSL http://localhost:2379/health 2>&1 1>/dev/null; echo $?) != 0 ]]; do
    ((SECONDS++))
    if [[ ${SECONDS} == ${TIMEOUT_FOR_SERVICES} ]]; then
      swarm::log::fatal "etcd failed to start. Exiting..."
    fi
    sleep 1
  done

  sleep 2
}

# Start flannel in docker bootstrap, both for master and worker
swarm::multinode::start_flannel() {

  swarm::log::status "Launching flannel..."

  # Set flannel net config (when running on master)
  if [[ "${MASTER_IP}" == "localhost" ]]; then
    curl -sSL http://localhost:2379/v2/keys/coreos.com/network/config -XPUT \
      -d value="{ \"Network\": \"${FLANNEL_NETWORK}\", \"Backend\": {\"Type\": \"${FLANNEL_BACKEND}\"}}"
  fi

  # Make sure that a subnet file doesn't already exist
  rm -f ${FLANNEL_SUBNET_DIR}/subnet.env

  docker ${BOOTSTRAP_DOCKER_PARAM} run -d \
    --name swarm_flannel_$(swarm::helpers::small_sha) \
    --restart=${RESTART_POLICY} \
    --net=host \
    --privileged \
    -v /dev/net:/dev/net \
    -v ${FLANNEL_SUBNET_DIR}:${FLANNEL_SUBNET_DIR} \
    quay.io/coreos/flannel:${FLANNEL_VERSION}-${ARCH} \
    /opt/bin/flanneld \
      --etcd-endpoints=http://${MASTER_IP}:2379 \
      --ip-masq="${FLANNEL_IPMASQ}" \
      --iface="${IP_ADDRESS}"

  # Wait for the flannel subnet.env file to be created instead of a timeout. This is faster and more reliable
  local SECONDS=0
  while [[ ! -f ${FLANNEL_SUBNET_DIR}/subnet.env ]]; do
    ((SECONDS++))
    if [[ ${SECONDS} == ${TIMEOUT_FOR_SERVICES} ]]; then
      swarm::log::fatal "flannel failed to start. Exiting..."
    fi
    sleep 1
  done

  source ${FLANNEL_SUBNET_DIR}/subnet.env

  swarm::log::status "FLANNEL_SUBNET is set to: ${FLANNEL_SUBNET}"
  swarm::log::status "FLANNEL_MTU is set to: ${FLANNEL_MTU}"
}

# Start swarmlet first and then the master components as pods
swarm::multinode::start_k8s_master() {
  swarm::multinode::create_swarmconfig
  swarm::log::status "Launching swarmrnetes master components..."

  swarm::multinode::make_shared_swarmlet_dir

  docker run -d \
    --net=host \
    --pid=host \
    --privileged \
    --restart=${RESTART_POLICY} \
    --name swarm_swarmlet_$(swarm::helpers::small_sha) \
    ${swarmLET_MOUNTS} \
    gcr.io/google_containers/hyperswarm-${ARCH}:${K8S_VERSION} \
    /hyperswarm swarmlet \
      --allow-privileged \
      --api-servers=http://localhost:8080 \
      --config=/etc/swarmrnetes/manifests-multi \
      --cluster-dns=10.0.0.10 \
      --cluster-domain=cluster.local \
      ${CNI_ARGS} \
      ${CONTAINERIZED_FLAG} \
      --hostname-override=${IP_ADDRESS} \
      --v=2
}

# Start swarmlet in a container, for a worker node
swarm::multinode::start_k8s_worker() {
  swarm::multinode::create_swarmconfig
  swarm::log::status "Launching swarmrnetes worker components..."

  swarm::multinode::make_shared_swarmlet_dir

  # TODO: Use secure port for communication
  docker run -d \
    --net=host \
    --pid=host \
    --privileged \
    --restart=${RESTART_POLICY} \
    --name swarm_swarmlet_$(swarm::helpers::small_sha) \
    ${swarmLET_MOUNTS} \
    gcr.io/google_containers/hyperswarm-${ARCH}:${K8S_VERSION} \
    /hyperswarm swarmlet \
      --allow-privileged \
      --api-servers=http://${MASTER_IP}:8080 \
      --cluster-dns=10.0.0.10 \
      --cluster-domain=cluster.local \
      ${CNI_ARGS} \
      ${CONTAINERIZED_FLAG} \
      --cadvisor-port=4194 \
      --storage-driver-db="cadvisor" \
      --storage-driver-host="localhost:8086" \
      --hostname-override=${IP_ADDRESS} \
      --v=2
}

# Start swarm-proxy in a container, for a worker node
swarm::multinode::start_k8s_worker_proxy() {

  swarm::log::status "Launching swarm-proxy..."
  docker run -d \
    --net=host \
    --privileged \
    --name swarm_proxy_$(swarm::helpers::small_sha) \
    --restart=${RESTART_POLICY} \
    gcr.io/google_containers/hyperswarm-${ARCH}:${K8S_VERSION} \
    /hyperswarm proxy \
        --master=http://${MASTER_IP}:8080 \
        --v=2
}

# Turndown the local cluster
swarm::multinode::turndown(){

  # Check if docker bootstrap is running
  DOCKER_BOOTSTRAP_PID=$(ps aux | grep ${BOOTSTRAP_DOCKER_SOCK} | grep -v "grep" | awk '{print $2}')
  if [[ ! -z ${DOCKER_BOOTSTRAP_PID} ]]; then

    swarm::log::status "Killing docker bootstrap..."

    # Kill the bootstrap docker daemon and it's containers
    docker -H ${BOOTSTRAP_DOCKER_SOCK} rm -f $(docker -H ${BOOTSTRAP_DOCKER_SOCK} ps -q) >/dev/null 2>/dev/null
    kill ${DOCKER_BOOTSTRAP_PID}
  fi

  swarm::log::status "Killing all swarm containers..."

  if [[ $(docker ps | grep "swarm" | awk '{print $1}' | wc -l) != 0 ]]; then
    docker rm -f $(docker ps | grep "swarm" | awk '{print $1}')
  fi

  swarm::multinode::delete_bridge docker0
}

swarm::multinode::delete_bridge() {
  if [[ ! -z $(ip link | grep "$1") ]]; then
    ip link set $1 down
    ip link del $1
  fi
}

# Make shared swarmlet directory
swarm::multinode::make_shared_swarmlet_dir() {

  # This only has to be done when the host doesn't use systemd
  if ! swarm::helpers::command_exists systemctl; then
    mkdir -p /var/lib/swarmlet
    mount --bind /var/lib/swarmlet /var/lib/swarmlet
    mount --make-shared /var/lib/swarmlet

    swarm::log::status "Mounted /var/lib/swarmlet with shared propagnation"
  fi
}

swarm::multinode::create_swarmconfig(){
  # Create a swarmconfig.yaml file for the proxy daemonset
  mkdir -p /var/lib/swarmlet/swarmconfig
  sed -e "s|MASTER_IP|${MASTER_IP}|g" swarmconfig.yaml > /var/lib/swarmlet/swarmconfig/swarmconfig.yaml
}

# Check if a command is valid
swarm::helpers::command_exists() {
  command -v "$@" > /dev/null 2>&1
}

# Backup the current file
swarm::helpers::backup_file(){
  cp -f ${1} ${1}.backup
}

# Returns five "random" chars
swarm::helpers::small_sha(){
  date | md5sum | cut -c-5
}

# Get the architecture for the current machine
swarm::helpers::host_platform() {
  local host_os
  local host_arch
  case "$(uname -s)" in
    Linux)
      host_os=linux;;
    *)
      swarm::log::fatal "Unsupported host OS. Must be linux.";;
  esac

  case "$(uname -m)" in
    x86_64*)
      host_arch=amd64;;
    i?86_64*)
      host_arch=amd64;;
    amd64*)
      host_arch=amd64;;
    aarch64*)
      host_arch=arm64;;
    arm64*)
      host_arch=arm64;;
    arm*)
      host_arch=arm;;
    ppc64le*)
      host_arch=ppc64le;;
    *)
      swarm::log::fatal "Unsupported host arch. Must be x86_64, arm, arm64 or ppc64le.";;
  esac
  echo "${host_os}/${host_arch}"
}

swarm::helpers::parse_version() {
  local -r version_regex="^v(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)(-(beta|alpha)\\.(0|[1-9][0-9]*))?$"
  local -r version="${1-}"
  [[ "${version}" =~ ${version_regex} ]] || {
    swarm::log::fatal "Invalid release version: '${version}', must match regex ${version_regex}"
    return 1
  }
  VERSION_MAJOR="${BASH_REMATCH[1]}"
  VERSION_MINOR="${BASH_REMATCH[2]}"
  VERSION_PATCH="${BASH_REMATCH[3]}"
  VERSION_EXTRA="${BASH_REMATCH[4]}"
  VERSION_PRERELEASE="${BASH_REMATCH[5]}"
  VERSION_PRERELEASE_REV="${BASH_REMATCH[6]}"
}

# Print a status line. Formatted to show up in a stream of output.
swarm::log::status() {
  timestamp=$(date +"[%m%d %H:%M:%S]")
  echo "+++ $timestamp $1"
  shift
  for message; do
    echo "    $message"
  done
}

# Log an error and exit
swarm::log::fatal() {
  timestamp=$(date +"[%m%d %H:%M:%S]")
  echo "!!! $timestamp ${1-}" >&2
  shift
  for message; do
    echo "    $message" >&2
  done
  exit 1
}