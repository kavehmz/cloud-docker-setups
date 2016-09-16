#!/bin/bash -x
ID=$1;H=$(docker ps|grep $ID|tr -s ' '|cut -d' ' -f1|xargs docker inspect |grep IPAddress|tail -n1|cut -d '"' -f4);ssh -i servers/ssh/id_rsa -A root@$H
