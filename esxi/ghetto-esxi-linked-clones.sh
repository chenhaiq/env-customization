#!/bin/ash

AUTHORS='william2003[at]gmail[dot]com'
AUTHORS+=' duonglt[at]engr[dot]ucsb[dot]edu'
AUTHORS+=' kernelsmith[at]kernelsmith[dot]com'
AUTHORS+=' Michael.Heyman[at]jhuapl[dot]'
CREATED='09/30/2008'
UPDATED='03/03/2014' # ks
#
# Custom Shell script to clone Virtual Machines for Labs at UCSB and JHUAPL
# script takes a number of agruments based on a golden image along with
# designated virtual machine lab name and a range of VMs to be created.
#############################################################################################

ESXI_VMWARE_VIM_CMD=/bin/vim-cmd
CREATE_FIREWALL_RULES="true"
DEVEL_MODE=0
DEBUG=""

#
# ERROR CODES
#
ERR_NO_VIM_CMD=200
ERR_MASTER_VM_BAD=201
ERR_MASTER_VM_ONLINE_NOT_REG=202
ERR_MASTER_VM_SNAP_RAW=203
ERR_MASTER_VM_BAD_ETH0=204
ERR_MASTER_VM_EXCESS_VMDKS=205
ERR_START_VAL_INVALID=210
ERR_COUNT_VAL_INVALID=211
ERR_BAD_PARAMETERS=220
ERR_NOT_DATASTORE=250

#
# Functions
#

debug() {
  if [ "${DEVEL_MODE}" -eq 1 -o -n "${DEBUG}" ]; then echo "[debug] $1" 1>&2;fi
}

debug_var(){
  eval val='${'$1'}'
  debug "$1 is:$val"
}

resolve_datastore() {
  debug "resolve_datastore:  received arguments:$@"
  # $1 is expected to be something like [datastore1] with or without the sq brackets
  # cleanup the provided argument
  ds=`echo $1 | sed 's/^\[//g' | sed 's/\]$//g'` # get rid of sq brackets
  debug_var ds
  # from what I can tell, a datastore name is 1-42 chars not including '/', '\', '%', '[', or ']'
  if ! (echo "$ds" | grep -qe '^[^][/\\%]\{1,42\}')
  then
    echo 'Cannot resolve "$ds" because it does not look like a datastore'
  else
    echo `${ESXI_VMWARE_VIM_CMD} hostsvc/datastore/info "$ds" | grep -E "^\s*url\s*=" | cut -d'"' -f2`
  fi
}

replace_datastore() {
  # $1 should be something like [datastore1]/path_to/my_vm
  debug "replace_datastore:  received arguments:$@"
  orig_path=$1
  debug_var orig_path
  # from what I can tell, a datastore name is 1-42 chars not including '/', '\', '%', '[', or ']'
  if ! (echo $orig_path | grep -qe '^\[[^][/\\%]\{1,42\}\]')
  then
    echo "Cannot replace datastore reference in $orig_path because it does not look like [datastore1]"
  else
    first_half=`echo $orig_path | cut -d ']' -f 1` # becomes ~ [datastore1
    debug_var first_half
    second_half=`echo $orig_path | cut -d ']' -f 2 | sed 's/^ *//'` # becomes ~ /path_to/my_vm
    debug_var second_half
    # the sed above trims leading spaces only
    store=`resolve_datastore ${first_half}`
    debug_var store
    echo "${store}/${second_half}"
  fi
}

mkdir_if_not_exist() {
  if ! [ -d $1 ]; then mkdir -p $1;fi
}

package_vmx() {
  vmx=$1
  debug "Packaging vmx file:$vmx"
  if [ -n "$2" ]
  then
    # a vnc port was provided, let's use it and use a hardcoded password for now
    # NOTE:  You may need to adjust the esxi firewall (for certain versions of esxi)
    #               To do so, checkout the here document at the end of this script
    vnc_port=$2
    vnc_pass="lab"
    # Remove all vnc related lines
    debug "Removing vnc references"
    sed -i '/RemoteDisplay.vnc.*/d' $vmx > /dev/null 2>&1
    # now add them back (except vnc.key) with our stuff
    debug "Adding new vnc references back in"
    echo "RemoteDisplay.vnc.enabled = \"true\"" >> $vmx
    echo "RemoteDisplay.vnc.port = \"$vnc_port\"" >> $vmx
    echo "RemoteDisplay.vnc.password = \"$vnc_pass\"" >> $vmx
  fi

  #
  # All the items below will get regenerated once the vm is booted for the first time
  #

  # Remove remnants of an autogenerated mac address
  debug "Removing mac address and uuid references"
  sed -i '/ethernet0.generatedAddress/d' $vmx > /dev/null 2>&1
  sed -i '/ethernet0.addressType/d' $vmx > /dev/null 2>&1
  sed -i '/uuid.location/d' $vmx > /dev/null 2>&1
  sed -i '/uuid.bios/d' $vmx > /dev/null 2>&1

  # Remove derived name
  debug "Removing derivedName"
  sed -i '/sched.swap.derivedName/d' $vmx > /dev/null 2>&1
}

printBanner() {
  echo "######################################################"
  echo "#"
  echo "# Linked Clones Tool for ESXi"
  echo "# Authors:"
  for author in AUTHORS; do echo -e "#   $author";done
  echo "# Created: $CREATED"
  echo "# Updated: $UPDATED"
  echo "######################################################"
}

validateUserInput() {
  #sanity check to make sure you're executing on an ESX 3.x host
  if [ ! -f ${ESXI_VMWARE_VIM_CMD} ]
  then
    echo "This script is meant to be executed on VMware ESXi, please try again ...."
    exit $ERR_NO_VIM_CMD
  fi
  debug "ESX Version valid (3.x+)"

  if ! (echo ${GOLDEN_VM} | egrep -i '[0-9A-Za-z]+.vmx$' > /dev/null) &&  ! -f "${GOLDEN_VM}" 
  then
    echo "Error: Golden VM Input is not valid"
    exit $ERR_MASTER_VM_BAD
  fi

  if [ "${DEVEL_MODE}" -eq 1 ]; then
    echo -e "\n############# SANITY CHECK START #############\n\nGolden VM vmx file exists"
  fi

  #
  # sanity check to verify Golden VM is offline before duplicating
  #
  ${ESXI_VMWARE_VIM_CMD} vmsvc/get.runtime ${GOLDEN_VM_VMID} | grep -iE "^\s*powerState\s*=" | \
    grep -i "poweredOff" > /dev/null 2>&1
  if [ ! $? -eq 0 ]; then
    echo "Master VM status is currently online, not registered or does not exist, please try again..."
    exit $ERR_MASTER_VM_ONLINE_NOT_REG
  fi

  debug "Golden VM is offline"
  local mastervm_dir=$(dirname "${GOLDEN_VM}")

  if (ls "${mastervm_dir}" | grep -iE '(delta.vmdk$|-rdm.vmdk$|-rdmp.vmdk$)' > /dev/null 2>&1)
  then
    echo "Master VM contains either a Snapshot or Raw Device Mapping, please ensure those " \
        "are gone and please try again..."
    exit $ERR_MASTER_VM_SNAP_RAW
  fi
  debug "Snapshots and RDMs were not found"

  if ! (grep -iE "^\s*ethernet0.present\s*=\s*\"true\"" "${GOLDEN_VM}" > /dev/null 2>&1)
  then
    echo "Master VM does not contain valid eth0 vnic, script requires eth0 to be present "\
        "and valid, please try again..."
    exit $ERR_MASTER_VM_BAD_ETH0
  fi
  debug "eth0 found and is valid"

  vmdks_count=`grep -i scsi "${GOLDEN_VM}" | grep -i fileName | awk -F "\"" '{print $2}' | wc -l`
  if [ "${vmdks_count}" -gt 1 ]
  then
    echo "Found more than 1 VMDK associated with the Master VM, script only supports a "\
        "single VMDK, please unattach the others and try again..."
    exit $ERR_MASTER_VM_EXCESS_VMDKS
  fi

  debug "Single VMDK disk found"

  # sanity check to verify your range is positive
  if [ -n "${START_COUNT}" ]
  then
    if [ "${START_COUNT}" -gt "${END_COUNT}" ]
    then
      echo "Your Start Count can not be greater or equal to your End Count, please try again..."
      exit $ERR_START_VAL_INVALID
    fi
    debug "START and END range is valid"
  else
    debug "Not making numbered linked clones"
  fi


  #
  # end of sanity check
  #
  if [ "${DEVEL_MODE}" -eq 1 ]
  then
    echo -e "\n########### SANITY CHECK COMPLETE ############\n" && exit 0
  fi
}

#
# START
#

usage() {
  printBanner
  if [ -n "$2" ]
  then
      echo -e "$2"
  fi
  echo -e "\nUsage: `basename $0` -m <master .vmx path> -l <linked clone name> [-r <resource pool name>] [-i <start index> ] [-c <count>] [-p] [-d [-d]]"
  echo -e "   -m: Path to an uncloned VM's .vmx file. May start with a datastore"
  echo -e '       (for example: "[datastore1]/foo/bar/bar.vmx")'
  echo -e "   -l: Linked clone name. May be full path to the linked clone"
  echo -e '       directory or start with, for example "[datastore1]". If a,'
  echo -e "       relative path the linked VM will be created under the"
  echo -e "       -m <master .vmx path> datastore."
  echo -e "   -r: Resource pool name to place linked clone under."
  echo -e "   -i: Index to start counting. When making multiple linked clones"
  echo -e "       in one go, this will be the starting index. Defaults to 1"
  echo -e "       if -c is provided."
  echo -e "   -c: Count of linked clones to make. Defaults to 1 if -i is."
  echo -e "       provided."
  echo -e "   -p: Power on the linked clone. (Power will be turned on long"
  echo -e "       enough to get a MAC address whether or not this is selected)."
  echo -e "   -d: Spit out debugging information"
  echo -e "   -d -d: Spit out debugging information and exit after validating"
  echo -e "          parameters."
  echo -e '   -y: Answer "yes" automatically for non-interactive script.'
  echo -e "i.e."
  echo -e "  $0 -m [datastore1]/LabMaster/LabMaster.vmx -l LabClient- -i 1 -c 20 -p"
  echo -e "Output:"
  echo -e "  LabClient-{1-20}"
  exit $1
}

#
# INTERNAL VARIABLES, DO NOT TOUCH UNLESS YOU ARE BASHY
#

# set variables
POWER_OFF="TRUE"
REQUEST_USER_CONFIRMATION="TRUE"
while getopts :m:l:r:i:c:pyd param
do
  case $param in
    m)
      if [ -z "${GOLDEN_VM}" ]
      then
        GOLDEN_VM=${OPTARG}
        debug_var GOLDEN_VM
      else
        usage ${ERR_BAD_PARAMETERS} "Only one -g parameter allowed"
      fi
    ;;

    l)
      if [ -z "${VM_NAMING_CONVENTION}" ]
      then
        VM_NAMING_CONVENTION=`basename ${OPTARG}`
        FINAL_PATH=`dirname ${OPTARG}`
        debug_var VM_NAMING_CONVENTION
        debug_var FINAL_PATH
      else
        usage ${ERR_BAD_PARAMETERS} "Only one -l parameter allowed"
      fi
    ;;

    r)
      if [ -z "${FINAL_RESOURCE_POOL_NAME}" ]
      then
        FINAL_RESOURCE_POOL_NAME=${OPTARG}
        debug_var FINAL_RESOURCE_POOL_NAME
      else
        usage ${ERR_BAD_PARAMETERS} "Only one -r parameter allowed"
      fi
    ;;

    i)
      if [ -z "${START_COUNT}" ]
      then
        START_COUNT=${OPTARG}
        debug_var START_COUNT
        if ! (echo ${START_COUNT} | egrep '^[0-9]+$' > /dev/null)
        then
          usage $ERR_START_VAL_INVALID "-i parameter must be a number"
        fi
      else
        usage ${ERR_BAD_PARAMETERS} "Only one -i parameter allowed"
      fi
    ;;

    c)
      if [ -z "${LINKED_CLONE_COUNT}" ]
      then
        LINKED_CLONE_COUNT=${OPTARG}
        debug_var LINKED_CLONE_COUNT
        if ! (echo ${LINKED_CLONE_COUNT} | egrep '^[0-9]+$' > /dev/null)
        then
          usage $ERR_COUNT_VAL_INVALID "-c parameter must be a number"
        else
          if [ ${LINKED_CLONE_COUNT} -lt 1 ]
          then
            usage $ERR_COUNT_VAL_INVALID "-c parameter must greater than zero"
          fi
        fi
      else
        usage ${ERR_BAD_PARAMETERS} "Only one -c parameter allowed"
      fi
    ;;

    p)
      POWER_OFF=''
    ;;

    y)
      REQUEST_USER_CONFIRMATION=''
    ;;

    d)
      if [ -z "${DEBUG}" ]
      then
        DEBUG="y"
      else
        DEVEL_MODE=1
      fi
    ;;

    \?)
      usage ${ERR_BAD_PARAMETERS} "Invalid parameter -${OPTARG}"
    ;;

    :)
      usage ${ERR_BAD_PARAMETERS} "-${OPTARG} requires an argument"
    ;;
  esac
done
debug_var POWER_OFF
debug_var REQUEST_USER_CONFIRMATION

shift $(($OPTIND - 1))
if [ $# -gt 0 ]
then
  usage ${ERR_BAD_PARAMETERS} "Unexpected parameters: $*"
fi


if [ -z "${GOLDEN_VM}" ]
then
  usage ${ERR_BAD_PARAMETERS} "-m required"
fi

if [ -z "${VM_NAMING_CONVENTION}" ]
then
  usage ${ERR_BAD_PARAMETERS} "-l required"
fi

# get the fullly resolved (no symlinks) absolute path to the vmx file passed into the script
# even accept [datastore1] type references if given as [datastore1] /path/vmx
# basic sanity check on the vm (vmx) file
if ! echo $GOLDEN_VM | grep -qE '\.vmx$'
then
  usage $ERR_MATER_VM_BAD "The provided vm doesn't appear to be a vmx file"
fi
# from what I can tell, a datastore name is 1-42 chars not including '/', '\', '%', '[', or ']'
if (echo ${GOLDEN_VM} | grep -qe '^\[[^][/\\%]\{1,42\}\]')
then
  # found a datastore (starts with [datastore1] or [datastore2] etc)
  echo "[*]  Resolving datastore reference ${GOLDEN_VM}"
  temp_path="`replace_datastore "${GOLDEN_VM}"`"
  debug_var temp_path
  GOLDEN_VM=`/bin/readlink -fn "$temp_path"`
else
  # no datastore reference, so just fully deref the given path
  GOLDEN_VM=`/bin/readlink -fn "$GOLDEN_VM"`
fi
debug_var GOLDEN_VM

if [ -n "${LINKED_CLONE_COUNT}" -a -z "${START_COUNT}" ]
then
  START_COUNT=1
  debug_var START_COUNT
fi

if [ -n "${START_COUNT}" ]
then
  if [ -n "${LINKED_CLONE_COUNT}" ]
  then
    END_COUNT=$((${START_COUNT} + ${LINKED_CLONE_COUNT} - 1))
    debug_var END_COUNT
  else
    END_COUNT=${START_COUNT}
    debug_var END_COUNT
  fi
fi

if [ -n "${FINAL_RESOURCE_POOL_NAME}" ]
then
  FINAL_RESOURCE_POOL_MATCH_COUNT=`grep "<name>${FINAL_RESOURCE_POOL_NAME}</name>" /etc/vmware/hostd/pools.xml | wc -l | sed 's/\s*//g'`
  debug_var FINAL_RESOURCE_POOL_MATCH_COUNT
  if [ ${FINAL_RESOURCE_POOL_MATCH_COUNT} -eq 1 ]
  then
    FINAL_RESOURCE_POOL_ID=`grep "<name>${FINAL_RESOURCE_POOL_NAME}</name>" -A1 /etc/vmware/hostd/pools.xml | tail -1 | sed -e 's/\s*<.\?objID>\s*//g'`
    debug_var FINAL_RESOURCE_POOL_ID
  else
    if [ ${FINAL_RESOURCE_POOL_MATCH_COUNT} -eq 0 ]
    then
      # make a string of resource pool names with two spaces before each line
      AVAILABLE_RESOURCE_POOLS="  "`grep "<name>" /etc/vmware/hostd/pools.xml | sed 's/\s*<.\?name>\s*//g' | sort -u | sed ':a;N;$!ba;s/\n/\n  /g'`
      usage ${ERR_BAD_PARAMETERS} "Resource pool "'"'"${FINAL_RESOURCE_POOL_NAME}"'"'" not found. Try one of:\n${AVAILABLE_RESOURCE_POOLS}"
    else
      usage ${ERR_BAD_PARAMETERS} "Found ${FINAL_RESOURCE_POOL_MATCH_COUNT} matches for resource pool "'"'"${FINAL_RESOURCE_POOL_NAME}"'"'". This code is not\nsophisticated enough to do a path to a resource pool so you need a\nunique resource pool name. Sorry."
    fi
  fi
fi

# get path to vmx w/o the "vmx"
GOLDEN_VM_PATH=`echo ${GOLDEN_VM%%.vmx*}`
debug_var GOLDEN_VM_PATH
# get the golden vm's name
GOLDEN_VM_NAME=`grep -iE "^\s*displayName\s*=" ${GOLDEN_VM} | awk '{print $3}' | sed 's/"//g'`
debug_var GOLDEN_VM_NAME
# get the golden vm's vmid
GOLDEN_VM_VMID=`${ESXI_VMWARE_VIM_CMD} vmsvc/getallvms | grep -iE "^[0-9]+\s+${GOLDEN_VM_NAME}\s+\[" | awk '{print $1}'`
debug_var GOLDEN_VM_VMID
# get the part of the path relative to the datastore
TO_REMOVE=`${ESXI_VMWARE_VIM_CMD} vmsvc/get.config $GOLDEN_VM_VMID|grep -E "^\s*vmPathName\s*="|awk '{print $4}'|sed 's/",//g'`
# now get the base part of the path (which is probably just the real path to the datastore)
STORAGE_PATH=`echo ${GOLDEN_VM%$TO_REMOVE*}`
debug_var STORAGE_PATH

# from what I can tell, a datastore name is 1-42 chars not including '/', '\', '%', '[', or ']'
if (echo ${FINAL_PATH} | grep -qe '^\[[^][/\\%]\{1,42\}\]')
then
  # found a datastore (starts with [datastore1] or [datastore2] etc)
  echo "[*]  Resolving datastore reference ${FINAL_PATH}"
  temp_path="`replace_datastore "${FINAL_PATH}"`"
  debug_var temp_path
  FINAL_PATH=$temp_path
else
  # if the final path does not start with a '/', prepend the storage path to it.
  echo ${FINAL_PATH} | grep -qe '^/'
  if [ "$?" -ne 0 ]
  then
      FINAL_PATH="${STORAGE_PATH}/${FINAL_PATH}"
  fi
fi
debug_var FINAL_PATH

validateUserInput

# print out user configuration - requires user input to verify the configs before duplication
# read in busybox/ash sucks so we use this loop instead
if [ -n "${REQUEST_USER_CONFIRMATION}" ]
then
  echo -e "Requested parameters:"
  echo -e "  - Master Virtual Machine Image: ${GOLDEN_VM}"
  if [ -z "${START_COUNT}" ]
  then
    echo -e "  - Linked Clone output: $VM_NAMING_CONVENTION"
  else
    echo -e "  - Linked Clones output: $VM_NAMING_CONVENTION{${START_COUNT}-${END_COUNT}}"
  fi
  echo
  echo "Would you like to continue with this configuration y/n?"
  read userConfirm
  case $userConfirm in
    yes|YES|y|Y)
      break;;
    *)
      echo "Requested parameters canceled, application exiting"
      exit;;
  esac
fi
if [ -z "${START_COUNT}" ]
then
  echo "Cloning will proceed for $VM_NAMING_CONVENTION"
else
  echo "Cloning will proceed for $VM_NAMING_CONVENTION{${START_COUNT}-${END_COUNT}}"
fi
echo

#
# start duplication
#
if [ -z "${START_COUNT}" ]
then
  COUNT=0
  MAX=0
  TOTAL_VM_CREATE=1
else
  COUNT=$START_COUNT
  MAX=$END_COUNT
  TOTAL_VM_CREATE=$(( ${END_COUNT} - ${START_COUNT} + 1 ))
fi
START_TIME=`date`
S_TIME=`date +%s`

LC_EXECUTION_DIR=/tmp/esxi_linked_clones_run.$$
mkdir_if_not_exist "${LC_EXECUTION_DIR}"
LC_CREATED_VMS=${LC_EXECUTION_DIR}/newly_created_vms.$$
touch ${LC_CREATED_VMS}

WATCH_FILE=${LC_CREATED_VMS}
EXPECTED_LINES=${TOTAL_VM_CREATE}
debug_var COUNT
debug_var MAX
debug_var TOTAL_VM_CREATE
debug_var WATCH_FILE
debug_var EXPECTED_LINES
all_vmids=''
echo "-----------------------------------------------------------------"
while sleep 2;
do
  REAL_LINES=$(wc -l < "${WATCH_FILE}")
  REAL_LINES=`echo ${REAL_LINES} | sed 's/^[ \t]*//;s/[ \t]*$//'`
  P_RATIO=$(( (${REAL_LINES} * 100 ) / ${EXPECTED_LINES} ))
  P_RATIO=${P_RATIO%%.*}
  echo -en "\r${P_RATIO}% Complete! - Linked Clones Created:  ${REAL_LINES}/${EXPECTED_LINES}"
  if [ ${REAL_LINES} -ge ${EXPECTED_LINES} ]; then break; fi
done &

while [ "$COUNT" -le "$MAX" ];
do
  debug "*** $COUNT ***"
  # create final vm name
  if [ -z "${START_COUNT}" ]
  then
    FINAL_VM_NAME="${VM_NAMING_CONVENTION}"
  else
    FINAL_VM_NAME="${VM_NAMING_CONVENTION}${COUNT}"
  fi
  debug_var FINAL_VM_NAME
  FINAL_VM_VNC_PORT=$(( 6000 + $COUNT )) # so if this is vm count 7, vncviewer esxihost::6007
  debug_var FINAL_VM_VNC_PORT
  FINAL_VM_PATH="${FINAL_PATH}/$FINAL_VM_NAME"
  # make new directory for new vm (readlink cleans up extra "/./"s)
  mkdir_if_not_exist "${FINAL_VM_PATH}"
  FINAL_VM_PATH=`readlink -fn "$FINAL_VM_PATH"`
  debug_var FINAL_VM_PATH
  FINAL_VMX_PATH=${FINAL_VM_PATH}/$FINAL_VM_NAME.vmx
  debug_var FINAL_VMX_PATH
  # copy the original vmx there and name it after the final vm name
  cp ${GOLDEN_VM_PATH}.vmx $FINAL_VMX_PATH
  # the original vmdk's path in the config file might be relative or absolute so we
  # get it from vim-cmd instead of from the config file cuz we prefer absolute for esxi 4+
  ORIG_VMDK_PATH=`$ESXI_VMWARE_VIM_CMD vmsvc/get.filelayout $GOLDEN_VM_VMID | grep -A 1 -E "^\s*diskFile\s*=" | tail -n 1`
  ORIG_VMDK_PATH="`echo $ORIG_VMDK_PATH | cut -d '"' -f2`"
  debug_var ORIG_VMDK_PATH
  # vmdk path probably needs a datastore resolution
  # from what I can tell, a datastore name is 1-42 chars not including '/', '\', '%', '[', or ']'
  if (echo $ORIG_VMDK_PATH | grep -qe '^\[[^][/\\%]\{1,42\}\]')
  then
    VMDK_PATH=`replace_datastore "$ORIG_VMDK_PATH"`
  else
    VMDK_PATH=$ORIG_VMDK_PATH
  fi
  debug_var VMDK_PATH
  # replace old display name with the new one
  sed -i 's/displayName = "'${GOLDEN_VM_NAME}'"/displayName ="'${FINAL_VM_NAME}'"/' $FINAL_VMX_PATH
  # delete original vmdk line
  sed -i '/scsi0:0.fileName/d' $FINAL_VMX_PATH
  # add the repaired vmdk line back in (absolute path to vmkd)
  echo "scsi0:0.fileName = \"${VMDK_PATH}\"" >> $FINAL_VMX_PATH
  # replace nvram reference
  sed -i 's/nvram = "'${GOLDEN_VM_NAME}.nvram'"/nvram ="'${FINAL_VM_NAME}.nvram'"/' $FINAL_VMX_PATH
  # replace the extendedConfigFile reference
  sed -i 's/extendedConfigFile ="'${GOLDEN_VM_NAME}.vmxf'"/extendedConfigFile ="'${FINAL_VM_NAME}.vmxf'"/' \
    $FINAL_VMX_PATH
  # package the vmx so vmware/esxi won't think it previously existed
  package_vmx $FINAL_VMX_PATH $FINAL_VM_VNC_PORT
  # register the new vm with esxi so it knows about it
  debug "Registering $FINAL_VMX_PATH"
  if [ -n ${FINAL_RESOURCE_POOL_ID} ]
  then
    ${ESXI_VMWARE_VIM_CMD} solo/registervm $FINAL_VMX_PATH ${FINAL_VM_NAME} ${FINAL_RESOURCE_POOL_ID} > /dev/null 2>&1
  else
    ${ESXI_VMWARE_VIM_CMD} solo/registervm $FINAL_VMX_PATH > /dev/null 2>&1
  fi
  # get the new vms vmid
  FINAL_VM_VMID=`${ESXI_VMWARE_VIM_CMD} vmsvc/getallvms | grep -iE "^[0-9]+\s+${FINAL_VM_NAME}\s+\[" | awk '{print $1}'`
  debug_var FINAL_VM_VMID
  # Create a snapshot, this actually creates the linked clone's delta vmdk'?
  debug "Creating snapshot for ${FINAL_VM_VMID}"
  ${ESXI_VMWARE_VIM_CMD} vmsvc/snapshot.create ${FINAL_VM_VMID} Cloned "${FINAL_VM_NAME} Cloned from ${GOLDEN_VM_NAME}" > /dev/null 2>&1

  # Check if the snapshotting worked
  ls ${GOLDEN_VM_PATH}-[0-9]*.vmdk > /dev/null 2>&1
  if [ "$?" -eq 0 ]
  then
    # Move the snapshot disks to the final directory
    debug "mv ${GOLDEN_VM_PATH}-[0-9]*.vmdk ${FINAL_VM_PATH}"
    mv ${GOLDEN_VM_PATH}-[0-9]*.vmdk "${FINAL_VM_PATH}"
    FINAL_VMDK_PATH=`ls ${FINAL_VM_PATH}/*-[0-9]*[0-9].vmdk`
    debug_var FINAL_VMDK_PATH
    # Change the parent to the full path to the golden directory
    sed -i 's|parentFileNameHint="'${GOLDEN_VM_NAME}'.vmdk"|parentFileNameHint="'${VMDK_PATH}'"|' ${FINAL_VMDK_PATH}

    # output to file to later use
    echo "$FINAL_VMX_PATH" >> "${LC_CREATED_VMS}"
    # collect all the vmids in case user wants us to shut them down
    all_vmids="${all_vmids}${FINAL_VM_VMID} "
    # set the file path to the correct directory
    sed -i -r 's|scsi0:0.fileName = "[^"]+"|scsi0:0.fileName ="'${FINAL_VMDK_PATH}'"|' $FINAL_VMX_PATH

    # start the vm so it will get a new mac etc
    echo "[*] Starting VM:  ${FINAL_VM_VMID}"
    ${ESXI_VMWARE_VIM_CMD} vmsvc/power.on ${FINAL_VM_VMID}
  else
    echo Failed: ${ESXI_VMWARE_VIM_CMD} vmsvc/snapshot.create ${FINAL_VM_VMID} Cloned '"'${FINAL_VM_NAME} Cloned from ${GOLDEN_VM_NAME}'"'
    echo "" >> "${LC_CREATED_VMS}"
  fi

  COUNT=$(( $COUNT + 1 ))
done

END_TIME=`date`
E_TIME=`date +%s`

# This here document will create a rule in the firewall to allow vnc for the linked clones
# it allows inbound on 6000 thru 6500 to accomodate up to 501 linked clones
rule=/etc/vmware/firewall/vnc_for_linked_clones.xml
# if CREATE_FIREWALL_RULES is true, and the rules dir exists, and this rule doesn't exist
if ([ -n "$CREATE_FIREWALL_RULES" ] && [ -d /etc/vmware/firewall/ ] && ! [ -f $rule ])
then
echo "Creating Firewall Rules for VNC"
cat <<__EOF__ > $rule
 <!-- Firewall configuration information for VNC LINKED CLONES -->
  <ConfigRoot>
    <service>
        <id>VNC_LINKED_CLONES</id>
        <rule id='0000'>
            <direction>inbound</direction>
            <protocol>tcp</protocol>
            <porttype>dst</porttype>
            <port>
                <begin>6000</begin>
                <end>6500</end>
            </port>
        </rule>
        <rule id='0001'>
            <direction>outbound</direction>
            <protocol>tcp</protocol>
            <porttype>dst</porttype>
            <port>
                <begin>0</begin>
                <end>65535</end>
            </port>
        </rule>
        <enabled>true</enabled>
        <required>false</required>
    </service>
 </ConfigRoot>
__EOF__

  # refresh the firewall ruleset
  echo "Refreshing the firewall ruleset"
  /sbin/esxcli network firewall refresh
  debug "VNC firewall rule active? " `/sbin/esxcli network firewall ruleset list | grep -E "^VNC_LINKED_CLONES"`
fi

echo -e "\n\nWaiting for Virtual Machine(s) to startup and obtain MAC addresses...\n"
sleep 1

#grab mac addresses of newly created VMs (file to populate dhcp static config etc)
if [ -f ${LC_CREATED_VMS} ]
then
  for i in `cat ${LC_CREATED_VMS}`
  do
    TMP_LIST=${LC_EXECUTION_DIR}/vm_list.$$
    VM_P=`echo ${i##*/}`
    VM_NAME=`echo ${VM_P%.vmx*}`
    VM_MAC=`grep -iE "^\s*ethernet0.generatedAddress\s*=" "${i}"|awk '{print $3}'|sed 's/\"//g'|head -1|sed 's/://g'`
    while [ "${VM_MAC}" == "" ]
    do
      sleep 1
      VM_MAC=`grep -iE "^\s*ethernet0.generatedAddress\s*=" "${i}"|awk '{print $3}'|sed 's/\"//g'|head -1|sed 's/://g'`
    done
    echo "${VM_NAME}  ${VM_MAC}" >> ${TMP_LIST}
  done
  LCS_OUTPUT="lcs_created_on-`date +%F-%H%M%S`"
  echo -e "Linked clones VM MAC addresses stored at:"
  cat ${TMP_LIST} | sed 's/digit:/ &/1' | sort -k2n | sed 's/ //1' > "${LCS_OUTPUT}"
  echo -e "\t${LCS_OUTPUT}"
fi

echo
echo "Start time: ${START_TIME}"
echo "End   time: ${END_TIME}"
DURATION=`echo $((E_TIME - S_TIME))`

#calculate overall completion time
if [ ${DURATION} -le 60 ]
then
  echo "Duration  : ${DURATION} Seconds"
else
  echo "Duration  : `awk 'BEGIN{ printf "%.2f\n", '${DURATION}'/60}'` Minutes"
fi
echo
rm -rf ${LC_EXECUTION_DIR}

# power off the vms if requested
if ([ -n "$POWER_OFF" ] && [ -n "$all_vmids" ])
then
  echo "[*] Powering off VMs"
  for id in $all_vmids; do debug_var "id" && $ESXI_VMWARE_VIM_CMD vmsvc/power.off $id; done
fi
