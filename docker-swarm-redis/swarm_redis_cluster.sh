#!/bin/bash
echo "Checking gcloud command and if it is setup correcting by issuing 'gcloud info'"
gcloud info >/dev/null || { echo "You need to install Google Cloud SDK and set it up first"; exit 1; }

GCLOUD_ZONE='us-east1-b'
MACHINE_TYPE='n1-standard-1'
DISK_SIZE=10
DISK_SIZE_REDIS=10
NODES=2
REDIS_PER_NODE=2

echo "Creating the manager in zone [$GCLOUD_ZONE]"
NODENAME=swarm-manager
echo $GCLOUD_ZONE-$NODENAME
gcloud compute instances create "$GCLOUD_ZONE-$NODENAME" \
	--zone $GCLOUD_ZONE --machine-type $MACHINE_TYPE \
	--image "/debian-cloud/debian-8-jessie-v20160803" \
	--boot-disk-size $DISK_SIZE
MANAGERIP=$(gcloud compute instances describe $GCLOUD_ZONE-swarm-manager --zone $GCLOUD_ZONE|grep natIP|cut -d' ' -f 6)
LOCALMANAGERIP=$(gcloud compute instances describe $GCLOUD_ZONE-swarm-manager --zone $GCLOUD_ZONE|grep networkIP|cut -d' ' -f 4)

REDIS_NODES=$(expr $REDIS_PER_NODE \* $NODES)
for i in $(seq 1 $REDIS_NODES)
do
	echo "Creating disk redis$i"
	gcloud compute disks create "redis$i" --size "20" --zone $GCLOUD_ZONE 
	gcloud compute instances attach-disk $GCLOUD_ZONE-$NODENAME --zone $GCLOUD_ZONE --disk redis$i --device-name redis$i
	ssh kaveh@$MANAGERIP "sudo mkfs.ext4 /dev/disk/by-id/google-redis$i"
	ssh kaveh@$MANAGERIP "sudo mount /dev/disk/by-id/google-redis$i /mnt"

	ssh kaveh@$MANAGERIP 'sudo bash -c '\''echo "port 6379" > /mnt/redis.conf'\'
	ssh kaveh@$MANAGERIP 'sudo bash -c '\''echo "cluster-enabled yes" >> /mnt/redis.conf'\'
	ssh kaveh@$MANAGERIP 'sudo bash -c '\''echo "cluster-config-file nodes.conf" >> /mnt/redis.conf'\'
	ssh kaveh@$MANAGERIP 'sudo umount /mnt'

	gcloud compute instances detach-disk  $GCLOUD_ZONE-$NODENAME --zone $GCLOUD_ZONE --device-name=redis$i
done

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

for i in $(seq 1 $NODES)
do
	for j in $(seq 1 $REDIS_PER_NODE)
	do
		ID=$(perl -e "print $j+($i-1)*$REDIS_PER_NODE")
		echo "Attaching redis$ID to $GCLOUD_ZONE-swarm-node$i as redis$j"
		gcloud compute instances attach-disk $GCLOUD_ZONE-swarm-node$i --zone $GCLOUD_ZONE --disk redis$ID --device-name redis$j
		NAME=NODEIP$i
		IP="${!NAME}"
		ssh kaveh@$IP "sudo bash -c 'echo  "\""/dev/disk/by-id/google-redis$j /mnt/redis$j ext4 defaults 1 1"\"" >> /etc/fstab'"
		ssh kaveh@$IP "sudo mkdir /mnt/redis$j;sudo mount /mnt/redis$j"
	done
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
	echo "Installing docker on nodes"
	install_docker $IP
	echo "Joining the manager"
	ssh kaveh@$IP "sudo docker swarm join --token $WORKER_TOKEN $LOCALMANAGERIP:2377"	
done

echo "No service running on manager"
ssh kaveh@$MANAGERIP "sudo docker node update --availability drain $GCLOUD_ZONE-swarm-manager"

echo "List nodes"
ssh kaveh@$MANAGERIP 'sudo docker node ls'
echo "Creating a network"
ssh kaveh@$MANAGERIP 'sudo docker network create --driver overlay privatenetwork'

echo "Creating adding busybox and redis services in global mode"
ssh kaveh@$MANAGERIP 'sudo docker service create --mode global --network privatenetwork --name my-busybox busybox sleep 1000000'
for i in $(seq 1 $REDIS_PER_NODE)
do
	echo "Adding redis$i service"
	ssh kaveh@$MANAGERIP "sudo docker service create --mode global --network privatenetwork --name redis$i --mount source=/mnt/redis$i,target=/data,type=bind redis:3.0.7 redis-server /data/redis.conf"
	ssh kaveh@$MANAGERIP "sudo docker service ps redis$i"
done

BUSYBOXID=$(ssh kaveh@$NODEIP1 'sudo docker ps |grep busy|cut -d" " -f 1')
REDIS1ID=$(ssh kaveh@$NODEIP1 'sudo docker ps |grep redis1|cut -d" " -f 1')

for i in $(seq 1 $REDIS_PER_NODE)
do
	for IP in $(ssh kaveh@$NODEIP1 "sudo docker exec -i $BUSYBOXID nslookup tasks.redis$i|egrep 'redis$i\.'|cut -d' ' -f 3")
	do
		echo "redis servers meeting $IP"
		ssh kaveh@$NODEIP1 "sudo docker exec -i $REDIS1ID redis-cli CLUSTER MEET $IP 6379"
	done
done

STEP=$(expr 16384 \/ $NODES)
START=0
for i in $(seq 1 $NODES)
do
	NAME=NODEIP$i
	IP="${!NAME}"
	echo "Setup redis master at NODEIP$i[$IP]"
	REDISID=$(ssh kaveh@$IP 'sudo docker ps |grep redis1|cut -d" " -f 1')
	END=$(expr $START + $STEP)
	END=$(expr $END - 1)
	SLOTS='';for j in $(seq $START $END);do SLOTS="$SLOTS $j";done
	ssh kaveh@$IP "sudo docker exec -i $REDISID redis-cli CLUSTER ADDSLOTS $SLOTS"
	START=$(expr $START + $STEP)
done

echo "Setting replications"
for i in $(seq 1 $NODES)
do
	NAME=NODEIP$i
	SLAVENODEIP="${!NAME}"
	m=$(expr $i - 1)
	[ $m -eq 0 ] && m=$NODES
	NAME=NODEIP$m
	MASTERNODEIP="${!NAME}"
	REDISID=$(ssh kaveh@$MASTERNODEIP 'sudo docker ps |grep redis1|cut -d" " -f 1')
	MASTERREDISIP=$(ssh kaveh@$MASTERNODEIP "sudo docker inspect  --format '{{ .NetworkSettings.Networks.privatenetwork.IPAddress }}' $REDISID")

	REDISID=$(ssh kaveh@$SLAVENODEIP 'sudo docker ps |grep redis2|cut -d" " -f 1')
	REDISMASTERID=$(ssh kaveh@$SLAVENODEIP "sudo docker exec -i $REDISID redis-cli CLUSTER NODES|grep $MASTERREDISIP:6379|cut -d' ' -f1")
	echo "redis2 in $SLAVENODEIP replicatred redis1 in $MASTERREDISIP"
	ssh kaveh@$SLAVENODEIP "sudo docker exec -i $REDISID redis-cli CLUSTER REPLICATE $REDISMASTERID"
done

