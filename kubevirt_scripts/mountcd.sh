#!/bin/bash
set -ux -o pipefail

#### IMPORTANT: This script is only meant to show how to implement required scripts to make custom hardware compatible with FakeFish.
#### This script has to mount the iso in the server's virtualmedia and return 0 if operation succeeded, 1 otherwise
#### Note: Iso image to mount will be received as the first argument ($1)
#### You will get the following vars as environment vars
#### BMC_ENDPOINT - Has the BMC IP
#### BMC_USERNAME - Has the username configured in the BMH/InstallConfig and that is used to access BMC_ENDPOINT
#### BMC_PASSWORD - Has the password configured in the BMH/InstallConfig and that is used to access BMC_ENDPOINT

ISO=${1}
IS_HTTPS=false

export VM_NAME=$(echo "${BMC_ENDPOINT}" | awk -F "_" '{print $1}')
export VM_NAMESPACE=$(echo "${BMC_ENDPOINT}" | awk -F "_" '{print $2}')

SCRIPTPATH="$( cd "$(dirname "$0")" >/dev/null 2>&1 && pwd -P )"

source "${SCRIPTPATH}/common.sh"

if [[ -r /var/tmp/kubeconfig ]]; then
  export KUBECONFIG=/var/tmp/kubeconfig
fi


CLUSTER_STORAGE_CLASS=$(oc get storageclass --insecure-skip-tls-verify=true | awk '/(virtualization)/ {print $1}')
if [ $? -ne 0 ]; then
  echo "Failed to get virtualization cluster's storage class."
  exit 1
fi

if [ -z "${CLUSTER_STORAGE_CLASS}" ];then
  CLUSTER_STORAGE_CLASS=ocs-storagecluster-ceph-rbd
fi

if echo "${ISO}" | grep -q https://; then
  IS_HTTPS=true
fi

if oc -n "${VM_NAMESPACE}" get pvc "${VM_NAME}-bootiso" --insecure-skip-tls-verify=true; then
  echo "PVC already exists."
  exit 0
fi

curl -k "${ISO}" -o /tmp/test.iso

# we need to poweroff the VM if it's running
VM_WAS_RUNNING=$(oc -n "${VM_NAMESPACE}" get vm "${VM_NAME}" --insecure-skip-tls-verify=true -o jsonpath='{.spec.running}')
if [ $? -ne 0 ]; then
  echo "Failed to get VM power state."
  exit 1
fi
stop_vm
if [ $? -ne 0 ]; then
  echo "Failed to poweroff VM."
  exit 1
fi

if [ ${IS_HTTPS} == "true" ]; then
  virtctl image-upload pvc "${VM_NAME}-bootiso" \
    --image-path="/tmp/test.iso" \
    --size=1Gi \
    --storage-class="${CLUSTER_STORAGE_CLASS}" \
    --namespace="${VM_NAMESPACE}" \
    --insecure

  if [ $? -ne 0 ]; then
    echo "Failed to create PVC."
    exit 1
  fi
else
  virtctl image-upload pvc "${VM_NAME}-bootiso" \
    --image-path="/tmp/test.iso" \
    --size=1Gi \
    --storage-class="${CLUSTER_STORAGE_CLASS}" \
    --namespace="${VM_NAMESPACE}"

  if [ $? -ne 0 ]; then
    echo "Failed to create PVC."
    exit 1
  fi
fi

STATUS=$(oc -n "${VM_NAMESPACE}" get pvc "${VM_NAME}-bootiso" --insecure-skip-tls-verify=true -o jsonpath='{.metadata.annotations.cdi\.kubevirt\.io/storage\.condition\.running\.message}')
if [ $? -ne 0 ]; then
  echo "Failed to get CDI import state."
  exit 1
fi
MAX_WAIT=60
WAIT=0
while [[ ${STATUS} != "Upload Complete" ]]
do
  WAIT=$((WAIT + 2))
  sleep 2
  if [ ${WAIT} -ge ${MAX_WAIT} ]; then
    # This will make the request fail, Metal3 will retry the operation.
    echo "Timeout waiting for ISO to be uploaded"
    exit 1
  fi
  echo "Waiting for ISO to be uploaded [${WAIT}/${MAX_WAIT}]"
  STATUS=$(oc -n "${VM_NAMESPACE}" get pvc "${VM_NAME}-bootiso" --insecure-skip-tls-verify=true -o jsonpath='{.metadata.annotations.cdi\.kubevirt\.io/storage\.condition\.running\.message}')
  if [ $? -ne 0 ]; then
    echo "Failed to get CDI import state."
    exit 1
  fi
done

NUM_VOLUMES=$(oc -n "${VM_NAMESPACE}" get vm "${VM_NAME}" --insecure-skip-tls-verify=true -o jsonpath='{.spec.template.spec.volumes[*].name}' | tr " " ";" | { grep -o ";" || true; } | wc -l)
if [ $? -ne 0 ]; then
  echo "Failed to get VM volumes."
  exit 1
fi

cat <<EOF > "/tmp/${VM_NAME}.patch"
[
  {
    "op": "add",
    "path": "/spec/template/spec/volumes/$((NUM_VOLUMES + 1))",
    "value": {
      "name": "${VM_NAME}-bootiso",
      "persistentVolumeClaim": {
         "claimName": "${VM_NAME}-bootiso"
      }
    }
  }
]
EOF

# Add it to VM object if it doesn't exist
VOLUME_EXIST=$(oc -n "${VM_NAMESPACE}" get vm "${VM_NAME}" --insecure-skip-tls-verify=true -o jsonpath='{.spec.template.spec.volumes[*].name}' | { grep -c "${VM_NAME}-bootiso" || true; })
if [ $? -ne 0 ]; then
  echo "Failed to get VM volumes."
  exit 1
fi

if [ "${VOLUME_EXIST}" -eq 0 ]; then
  oc -n "${VM_NAMESPACE}" patch vm "${VM_NAME}" --insecure-skip-tls-verify=true --patch-file "/tmp/${VM_NAME}.patch" --type json
  if [ $? -eq 0 ]; then
    echo "Volume added to the VM"
  else
    echo "Failed to add bootiso volume to the VM"
    exit 1
  fi
else
  echo "Volume already added to the VM"
fi

# We get the number of disks, since we need to delete the one we just added to fix the config
NUM_DISK=$(oc -n "${VM_NAMESPACE}" get vm "${VM_NAME}" --insecure-skip-tls-verify=true -o jsonpath='{.spec.template.spec.domain.devices.disks[*].name}' | tr " " ";" | { grep -o ";" || true; } | wc -l)
if [ $? -ne 0 ]; then
  echo "Failed to get VM disks."
  exit 1
fi

cat <<EOF > "/tmp/${VM_NAME}.patch"
[
  {
    "op": "add",
    "path": "/spec/template/spec/domain/devices/disks/$((NUM_DISK + 1))",
    "value": {
      "bootOrder": $((NUM_DISK + 2)),
      "cdrom": {
         "bus": "sata"
      },
      "name": "${VM_NAME}-bootiso"
    }
  }
]
EOF

# Add it to VM object if it doesn't exist
DISK_EXIST=$(oc -n "${VM_NAMESPACE}" get vm "${VM_NAME}" --insecure-skip-tls-verify=true -o jsonpath='{.spec.template.spec.domain.devices.disks[*].name}' | { grep -c "${VM_NAME}-bootiso" || true; })
if [ $? -ne 0 ]; then
  echo "Failed to get VM volumes."
  exit 1
fi

if [ "${DISK_EXIST}" -eq 0 ]; then
  oc -n "${VM_NAMESPACE}" patch vm "${VM_NAME}" --insecure-skip-tls-verify=true --patch-file "/tmp/${VM_NAME}.patch" --type json
  if [ $? -eq 0 ]; then
    echo "Disk added to the VM"
  else
    echo "Failed to add bootiso disk to the VM"
    exit 1
  fi
else
  echo "Volume already added to the VM"
fi

# If VM was running, restore it
if [[ "${VM_WAS_RUNNING}" == "true" ]]; then
  start_vm
  if [ $? -ne 0 ]; then
    echo "Failed to poweron VM."
    exit 1
  fi
fi
