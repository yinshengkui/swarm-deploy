# swarm-deploy

This is a repository of community maintained Swarm cluster deployment
automations.

目前swarm-deploy只支持centos7u2@aliyun vpc ， 后续会支持centos7u2@aliyun经典网络以及centos7u2@物理网络

## 在阿里云海外节点创建一个vpc 虚拟机，注意要选择 centos7u2的基础镜像

## 登录虚拟机，获取swarm-deploy工具

```
yum install -y git && cd /opt && git clone https://github.com/uniseraph/swarm-deploy.git 
```

##  初始化本机环境

```
cd /opt/swarm-deploy && bash init-node.sh
```

注意在初始化环境时候，会删除本机原有的docker环境与容器！

在init-node.sh脚本中，会设置docker存储模式为overlay，使用如下命令确认

```
docker info | grep STORAGE
```

在init-node.sh脚本中，会设置docke engine的监听端口为eth0:2376和unix:///var/run/docker.sock，使用如下命令check

```
netstat -anlp | grep LISTEN | grep docker
```


### 初始化swarm-master节点

```
cd /opt/swarm/swarm-deploy/vpc && bash master.sh
[root@iZrj91tefvghte2u30htvzZ vpc]# bash master.sh
+++ [1114 17:26:35] ARCH is set to: amd64
+++ [1114 17:26:35] SWARM_VERSION is set to: 1.2.5
+++ [1114 17:26:35] ETCD_VERSION is set to: 3.0.4
+++ [1114 17:26:35] ZK_VERSION is set to: 3.4.9
+++ [1114 17:26:35] ZK_URL  is set to: zk://10.24.136.254:2181
+++ [1114 17:26:35] BIP is set to: 192.168.1.1/24
+++ [1114 17:26:35] MTU is set to: 1472
+++ [1114 17:26:35] IP_ADDRESS is set to: 10.24.136.254
+++ [1114 17:26:35] Killing docker bootstrap...
+++ [1114 17:26:35] Killing all swarm containers...
a24b6301e0ba
cf11ff187bda
+++ [1114 17:26:35] Launching docker bootstrap...
+++ [1114 17:26:36] Launching zookeeper...
5166ee34422c544c452f6814ad75076adcbc335c89ad96261d4d2feee7f1691f
+++ [1114 17:26:36] waiting 10 seconds for zk starting...
+++ [1114 17:26:46] Restarting main docker daemon...
+++ [1114 17:26:47] Launching swarm master ...
+++ [1114 17:26:47] Launching swarm master , listening at 10.24.136.254:2375 ...
011507b60b5d3430c96442e5d77f115a63addd115a42794ad27b6ddc14bd586f
be6469a959c72c05e629de7b8caf3e04409916d952194f6ade117f5bc7e07c45
```

在这台ECS上，起了多个服务，组成了一个master*1 node*1的swarm 集群。

服务| 地址|
----|-----|
zk | zk://10.24.136.254:2181 |
----|-----|
swarm master | tcp://10.24.136.254:2375|
----|-----|
docker  | tcp://10.24.136.254:2376 and unix:///var/run/docker.sock|
----|-----|
bootstrap docker | unix:///var/run/docker-bootstrap.sock|

通过docker info命令可以查看集群情况。
```
[root@iZrj91tefvghte2u30htvzZ vpc]# docker -H tcp://10.24.136.254:2375 info
Containers: 2
 Running: 2
 Paused: 0
 Stopped: 0
Images: 1
Server Version: swarm/1.2.5
Role: primary
Strategy: spread
Filters: health, port, containerslots, dependency, affinity, constraint
Nodes: 1
 iZrj91tefvghte2u30htvzZ: 10.24.136.254:2376
  └ ID: 63IV:PSVE:HMSZ:SOAG:4WV4:I5CA:75LU:7HRT:3ZKC:M5HS:3JBS:6R5A
  └ Status: Healthy
  └ Containers: 2 (2 Running, 0 Paused, 0 Stopped)
  └ Reserved CPUs: 0 / 1
  └ Reserved Memory: 0 B / 1.018 GiB
  └ Labels: executiondriver=native-0.2, kernelversion=3.10.0-327.22.2.el7.x86_64, operatingsystem=CentOS Linux 7 (Core), storagedriver=overlay
  └ UpdatedAt: 2016-11-14T09:40:16Z
  └ ServerVersion: 1.10.3
Plugins:
 Volume:
 Network:
Kernel Version: 3.10.0-327.22.2.el7.x86_64
Operating System: linux
Architecture: amd64
Number of Docker Hooks: 2
CPUs: 1
Total Memory: 1.018 GiB
Name: iZrj91tefvghte2u30htvzZ
Registries:
```


通过docker ps命令可以查看集群所有容器
```
[root@iZrj91tefvghte2u30htvzZ vpc]# docker -H tcp://10.24.136.254:2375 ps -a
CONTAINER ID        IMAGE               COMMAND                  CREATED             STATUS              PORTS               NAMES
98710ac47dec        swarm:1.2.5         "/swarm manage --host"   12 minutes ago      Up 12 minutes                           iZrj91tefvghte2u30htvzZ/hungry_golick
cd39dbdbfb86        swarm:1.2.5         "/swarm join --addr 1"   12 minutes ago      Up 12 minutes                           iZrj91tefvghte2u30htvzZ/stupefied_noether
```




### 初始化swarm-agent 节点
