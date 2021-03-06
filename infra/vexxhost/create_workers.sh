#!/bin/bash -eE
set -o pipefail

[ "${DEBUG,,}" == "true" ] && set -x

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

source "$my_dir/definitions"
source "$my_dir/functions.sh"
source "$WORKSPACE/global.env"

ENV_FILE="$WORKSPACE/stackrc.$JOB_NAME.env"
IMAGE_TEMPLATE_NAME="${OS_IMAGES["${ENVIRONMENT_OS^^}"]}"
IMAGE_NAME=$(openstack image list --status active -c Name -f value | grep "${IMAGE_TEMPLATE_NAME}" | sort -nr | head -n 1)
IMAGE=$(openstack image show -c id -f value "$IMAGE_NAME")
IMAGE_SSH_USER=${OS_IMAGE_USERS["${ENVIRONMENT_OS^^}"]}

VM_TYPE=${VM_TYPE:-'medium'}
INSTANCE_TYPE=${VM_TYPES[$VM_TYPE]}
if [[ -z "$INSTANCE_TYPE" ]]; then
    echo "ERROR: invalid VM_TYPE=$VM_TYPE"
    exit 1
fi
echo "INFO: VM_TYPE=$VM_TYPE"

#multinodes parameters definition
CONTROLLER_NODES_COUNT=${CONTROLLER_NODES_COUNT:-1}
AGENT_NODES_COUNT=${AGENT_NODES_COUNT:-0}
VM_RETRIES=${VM_RETRIES:-5}

total_instances=$(( CONTROLLER_NODES_COUNT + AGENT_NODES_COUNT ))
if (( total_instances == 0 ))
then
  echo "ERROR: Nothing to create. Exit"
  exit 1
fi

controller_name="CONTROLLER-${BUILD_TAG}"
agent_name="AGENT-${BUILD_TAG}"
controller_job_tag="JobTag=${controller_name}"
agent_job_tag="JobTag=${agent_name}"
#find vcpu for flavor
instance_vcpu=$(openstack flavor show $INSTANCE_TYPE | awk '/vcpus/{print $4}')
total_vcpu=$(( instance_vcpu * total_instances ))

function clean_up_job () {
  local job_tag=$1
  local termination_list="$(list_instances JobTag=${job_tag})"
  local down_list="$(list_instances JobTag=${job_tag} DOWN=)"
  if [[ -n "${termination_list}" ]] ; then
      if [[ -n "${down_list}" ]] ; then
        down_instances $down_list || true
      fi

      echo "INFO: Instances to terminate: $termination_list"
      nova delete $(echo "$termination_list")
  fi
}

function wait_for_instance_availability () {  
  local instance_ip=$1   
  timeout 300 bash -c "\
  while /bin/true ; do \
      ssh -i $WORKER_SSH_KEY $SSH_OPTIONS $IMAGE_SSH_USER@$instance_ip 'uname -a' && break ; \
      sleep 10 ; \
  done"
  if [[ $? != 0 ]] ; then
    echo "ERROR: VM  with ip $instance_ip is unreachable. Exit "
    return 1
  fi
  image_up_script=${OS_IMAGES_UP["${ENVIRONMENT_OS^^}"]}
  if [[ -n "$image_up_script" && -e ${my_dir}/../hooks/${image_up_script}/up.sh ]] ; then
    ${my_dir}/../hooks/${image_up_script}/up.sh
  fi
}
#start main block with retries
for (( i=1; i<=$VM_RETRIES ; ++i ))
do
  
  CONTROLLER_NODES=""
  AGENT_NODES=""
  CONTROLLER_INSTANCE_IDS=""
  AGENT_INSTANCE_IDS=""
  INSTANCE_IDS=""
  ready_nodes=0  
  touch "$ENV_FILE"
  #resource availability on every retry
  while true; do
    [[ "$(($(nova list --tags "SLAVE=$SLAVE"  --field status | grep -c 'ID\|ACTIVE') + total_instances ))" -lt "$MAX_COUNT_VM" ]] && break
    echo "INFO: waiting for free worker"
    sleep 60
  done

  while true; do
    [[ "$(($(nova quota-show --detail | grep cores | sed 's/}.*/}/'| tr -d "}" | awk '{print $NF}') + total_vcpu ))" -lt "$MAX_COUNT_VCPU" ]] && break
    echo "INFO: waiting for CPU resources"
    sleep 60
  done

  #create CONTROLLER NODES
  if (( CONTROLLER_NODES_COUNT > 0 )) ; then
    nova boot --flavor ${INSTANCE_TYPE} \
                  --security-groups ${OS_SG} \
                  --key-name=worker \
                  --min-count ${CONTROLLER_NODES_COUNT} \
                  --tags "PipelineBuildTag=${PIPELINE_BUILD_TAG},${controller_job_tag},SLAVE=${SLAVE},DOWN=${OS_IMAGES_DOWN["${ENVIRONMENT_OS^^}"]}" \
                  --nic net-name=${OS_NETWORK} \
                  --block-device source=image,id=$IMAGE,dest=volume,shutdown=remove,size=120,bootindex=0 \
                  --poll \
                  ${controller_name}
    if [[ $? != 0 ]] ; then
      echo "ERROR: Controller instances creation is failed on nova boot. Retry"
      clean_up_job ${controller_job_tag}
      continue
    fi    
    CONTROLLER_INSTANCE_IDS="$( list_instances ${controller_job_tag} )"
  fi

  #create AGENT NODES
  if (( AGENT_NODES_COUNT > 0 )) ; then    
    nova boot --flavor ${INSTANCE_TYPE} \
                  --security-groups ${OS_SG} \
                  --key-name=worker \
                  --min-count ${AGENT_NODES_COUNT} \
                  --tags "PipelineBuildTag=${PIPELINE_BUILD_TAG},${agent_job_tag},SLAVE=${SLAVE},DOWN=${OS_IMAGES_DOWN["${ENVIRONMENT_OS^^}"]}" \
                  --nic net-name=${OS_NETWORK} \
                  --block-device source=image,id=$IMAGE,dest=volume,shutdown=remove,size=120,bootindex=0 \
                  --poll \
                  ${agent_name}
    if [[ $? != 0 ]] ; then

      echo "ERROR: Controller instances creation is failed on nova boot. Retry"
      clean_up_job ${controller_job_tag}
      clean_up_job ${agent_job_tag}
      continue

    fi
    AGENT_INSTANCE_IDS="$( list_instances ${AGENT_JOB_TAG} )"
  fi
  INSTANCE_IDS="$(echo "$CONTROLLER_INSTANCE_IDS $AGENT_INSTANCE_IDS" | sed 's/ /,/g')"  
  echo "export INSTANCE_IDS=$INSTANCE_IDS" >> "$ENV_FILE"

  #check availability for controller nodes
  if [[ -n "$CONTROLLER_INSTANCE_IDS" ]] ; then
    for instance_id in $CONTROLLER_INSTANCE_IDS
    do
      instance_ip=$(get_instance_ip $instance_id)
      wait_for_instance_availability $instance_ip
      if [[ $? != 0 ]] ; then
        echo "ERROR: Node with $instance_ip is not available. Clean up"
        clean_up_job ${controller_job_tag}
        clean_up_job ${agent_job_tag}        
        break
      fi
      ready_nodes=$(( ready_nodes + 1 ))
      CONTROLLER_NODES+="$instance_ip,"
      #support single node case and old behavior
      if (( ready_nodes == 1 )) ; then        
        echo "export instance_ip=$instance_ip" >> "$ENV_FILE"
      fi
    done
  fi
  if [[ -n "${AGENT_INSTANCE_IDS}"  ]] ; then
    if (( ready_nodes == CONTROLLER_NODES_COUNT )) ; then
    #check availability for agent nodes
      for instance_id in $AGENT_INSTANCE_IDS
      do
        instance_ip=$(get_instance_ip $instance_id)
        wait_for_instance_availability $instance_ip
        if [[ $? != 0 ]] ; then
          echo "ERROR: Node with $instance_ip is not available. Clean up"
          clean_up_job ${controller_job_tag}
          clean_up_job ${agent_job_tag}          
          break
        fi
        ready_nodes=$(( ready_nodes + 1 ))
        AGENT_NODES+="$instance_ip,"
      done
    fi
  fi
  #check if all nodes are created then exit from retry loop
  if (( ready_nodes == total_instances )) ; then
    if [[ -n "$AGENT_NODES" ]] ; then
      echo "INFO: Agent nodes ${AGENT_NODES} are created"
      AGENT_NODES=$(echo "$AGENT_NODES" | sed 's/\(.*\),/\1 /')
      echo "export AGENT_NODES=$AGENT_NODES" >> "$ENV_FILE"
    fi
    if [[ -n "$CONTROLLER_NODES" ]] ; then
      echo "INFO: Controller nodes ${CONTROLLER_NODES} are created"
      CONTROLLER_NODES=$(echo "$CONTROLLER_NODES" | sed 's/\(.*\),/\1 /')
      echo "export CONTROLLER_NODES=$CONTROLLER_NODES" >> "$ENV_FILE"
    fi
    break
  else
    echo "INFO: All Nodes are not created. Retry"
    continue
  fi
done

if (( ready_nodes != total_instances )) ; then
  echo "ERROR: Instances were not created. Exit"
  touch "$ENV_FILE"
  exit 1
fi

#Final filling of ENV_FILE
echo "export OS_REGION_NAME=${OS_REGION_NAME}" >> "$ENV_FILE"
echo "export ENVIRONMENT_OS=${ENVIRONMENT_OS}" >> "$ENV_FILE"
echo "export IMAGE=$IMAGE" >> "$ENV_FILE"
echo "export IMAGE_SSH_USER=$IMAGE_SSH_USER" >> "$ENV_FILE"
###At the end of the script I have CONTROLLER_NODES='ip1,ip2,ip3' and AGENT_NODES='ip1,ip2,ip3'
