#!/bin/bash

[ "${DEBUG,,}" == "true" ] && set -x

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

source "$my_dir/definitions"

ssh_cmd="ssh -i $WORKER_SSH_KEY $SSH_OPTIONS $SSH_EXTRA_OPTIONS"
SANITY_LOGS_PATH="contrail-test-runs"

rm -rf $WORKSPACE/logs
mkdir -p $WORKSPACE/logs
testdir=$(eval $ssh_cmd $IMAGE_SSH_USER@$instance_ip ls -1 $SANITY_LOGS_PATH 2>/dev/null | sort | tail -1)
rsync -a -e "$ssh_cmd" $IMAGE_SSH_USER@$instance_ip:$SANITY_LOGS_PATH/$testdir/reports/ $WORKSPACE/logs/ || /bin/true
rsync -a -e "$ssh_cmd" $IMAGE_SSH_USER@$instance_ip:$SANITY_LOGS_PATH/$testdir/logs $WORKSPACE/logs/ || /bin/true

FULL_LOGS_PATH="${LOGS_PATH}/${JOB_LOGS_PATH}/sanity"
ssh -i $LOGS_HOST_SSH_KEY $SSH_OPTIONS $LOGS_HOST_USERNAME@$LOGS_HOST "mkdir -p $FULL_LOGS_PATH"
rsync -a -e "ssh -i $LOGS_HOST_SSH_KEY $SSH_OPTIONS" $WORKSPACE/logs/ $LOGS_HOST_USERNAME@$LOGS_HOST:$FULL_LOGS_PATH
rm -rf $WORKSPACE/logs

echo "INFO: Sanity logs saved"
