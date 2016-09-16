#!/bin/bash
echo "Checking gcloud command and if it is setup correcting by issuing 'gcloud info'"
gcloud info >/dev/null || { echo "You need to install Google Cloud SDK and set it up first"; exit 1; }

GCLOUD_ZONE='us-east1-b'
MACHINE_TYPE='n1-standard-1'
DISK_SIZE=10
NODES=2

echo "Creating the manager in zone [$GCLOUD_ZONE]"
NODENAME=swarm-manager
echo $GCLOUD_ZONE-$NODENAME
gcloud compute instances create "$GCLOUD_ZONE-$NODENAME" \
	--zone $GCLOUD_ZONE --machine-type $MACHINE_TYPE \
	--image "/debian-cloud/debian-8-jessie-v20160803" \
	--boot-disk-size $DISK_SIZE
MANAGERIP=$(gcloud compute instances describe $GCLOUD_ZONE-swarm-manager --zone $GCLOUD_ZONE|grep natIP|cut -d' ' -f 6)
LOCALMANAGERIP=$(gcloud compute instances describe $GCLOUD_ZONE-swarm-manager --zone $GCLOUD_ZONE|grep networkIP|cut -d' ' -f 4)

echo "Creating nodes in zone [$GCLOUD_ZONE]"
for i in $(seq 1 $NODES)
do
	NODENAME=swarm-node$i
	echo $GCLOUD_ZONE-$NODENAME
	gcloud compute instances create "$GCLOUD_ZONE-$NODENAME" \
		--zone $GCLOUD_ZONE --machine-type $MACHINE_TYPE \
		--image "/debian-cloud/debian-8-jessie-v20160803" \
		--boot-disk-size $DISK_SIZE
	export NODEIP$i=$(gcloud compute instances describe $GCLOUD_ZONE-swarm-node$i --zone $GCLOUD_ZONE|grep natIP|cut -d' ' -f 6)
	export LOCALNODEIP$i=$(gcloud compute instances describe $GCLOUD_ZONE-swarm-node$i --zone $GCLOUD_ZONE|grep networkIP|cut -d' ' -f 4)
done

function install_docker {
	IP=$1
	echo "Adding https support for apt for [$IP]"
	ssh kaveh@$IP 'sudo apt-get update'
	ssh kaveh@$IP 'sudo apt-get install -y apt-transport-https ca-certificates'

	echo "Adding docker repository for apt and installing docker"
	ssh kaveh@$IP 'sudo bash -c '\''echo deb "https://apt.dockerproject.org/repo debian-jessie main" > /etc/apt/sources.list.d/docker.list'\'
	ssh kaveh@$IP 'sudo apt-key adv --keyserver hkp://p80.pool.sks-keyservers.net:80 --recv-keys 58118E89F3A912897C070ADBF76221572C52609D'
	ssh kaveh@$IP 'sudo apt-get update'

	ssh kaveh@$IP 'sudo apt-get install -y docker-engine'
	ssh kaveh@$IP 'sudo bash -c '\''curl -L https://github.com/docker/compose/releases/download/1.8.0/docker-compose-`uname -s`-`uname -m` > /usr/local/bin/docker-compose'\'
	ssh kaveh@$IP 'sudo chmod +x /usr/local/bin/docker-compose'
}

install_docker $MANAGERIP

echo "Setting up the master"
ssh kaveh@$MANAGERIP "sudo docker swarm init --advertise-addr $LOCALMANAGERIP"
WORKER_TOKEN=$(ssh kaveh@$MANAGERIP 'sudo docker swarm join-token -q worker')

for i in $(seq 1 $NODES)
do
	NAME=NODEIP$i
	LNAME=LOCAL$NAME
	LOCALIP="${!LNAME}"
	IP="${!NAME}"
	echo "$IP/$LOCALIP"
	echo "Installing docker on node"
	install_docker $IP
	echo "Joining the manager"
	ssh kaveh@$IP "sudo docker swarm join --token $WORKER_TOKEN $LOCALMANAGERIP:2377"	
done

echo "List nodes"
ssh kaveh@$MANAGERIP 'sudo docker node ls'
echo "Creating a network"
ssh kaveh@$MANAGERIP 'sudo docker network create --driver overlay --subnet 10.0.9.0/24 --opt encrypted my-network'

echo "Creating adding busybox and nginx services in global mode"
ssh kaveh@$MANAGERIP 'sudo docker service create --mode global --network my-network --name my-web nginx'
ssh kaveh@$MANAGERIP 'sudo docker service create --mode global --network my-network --name my-busybox busybox sleep 1000000'
ssh kaveh@$MANAGERIP 'sudo docker service create --mode global --network my-network --name my-redis redis:3.0.6'
ssh kaveh@$MANAGERIP 'sudo docker service ps my-redis'
ssh kaveh@$MANAGERIP "sudo docker node update --availability drain $GCLOUD_ZONE-swarm-manager"
ssh kaveh@$MANAGERIP 'sudo docker service update --update-parallelism=3 my-redis'
ssh kaveh@$MANAGERIP 'sudo docker service update --image redis:3.0.7 my-redis'
ssh kaveh@$MANAGERIP 'sudo docker service ps my-redis'

BUSYBOXID=$(ssh kaveh@$NODEIP1 'sudo docker ps |grep busy|cut -d" " -f 1')
echo "Getting the service DNS ip by a dns query"
ssh kaveh@$NODEIP1 "sudo docker exec -i $BUSYBOXID nslookup my-web"
echo "Adding tasks. to get all the related IPs for a service"
ssh kaveh@$NODEIP1 "sudo docker exec -i $BUSYBOXID nslookup tasks.my-web"
echo "All my-redis service IPs"
ssh kaveh@$NODEIP1 "sudo docker exec -i $BUSYBOXID nslookup tasks.my-redis"
echo "All my-busybox service IPs"
ssh kaveh@$NODEIP1 "sudo docker exec -i $BUSYBOXID nslookup tasks.my-busybox"
