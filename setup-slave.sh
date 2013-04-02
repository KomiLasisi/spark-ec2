#!/bin/bash

# Make sure we are in the spark-ec2 directory
cd /root/spark-ec2

source ec2-variables.sh

# Set hostname based on EC2 private DNS name, so that it is set correctly
# even if the instance is restarted with a different private DNS name
PRIVATE_DNS=`wget -q -O - http://instance-data.ec2.internal/latest/meta-data/local-hostname`
hostname $PRIVATE_DNS
echo $PRIVATE_DNS > /etc/hostname
HOSTNAME=$PRIVATE_DNS  # Fix the bash built-in hostname variable too

echo "Setting up slave on `hostname`..."

# Mount options to use for ext3 and xfs disks (the ephemeral disks
# are ext3, but we use xfs for EBS volumes to format them faster)
EXT3_MOUNT_OPTS="defaults,noatime,nodiratime"
XFS_MOUNT_OPTS="defaults,noatime,nodiratime,allocsize=8m"

# Mount any ephemeral volumes we might have beyond /mnt
function make_filesystem {
  device=$1
  mkfs.ext4 $device
  sleep 3
}

function setup_extra_volume {
  device=$1
  mount_point=$2
  if [[ -e $device && ! -e $mount_point ]]; then
    mkdir -p $mount_point
    mount -t ext4 -o $EXT3_MOUNT_OPTS $device $mount_point
    sleep 3
    echo "$device $mount_point auto $EXT3_MOUNT_OPTS 0 0" >> /etc/fstab
  fi
}
rmdir /mnt
umount /media/ephemeral0 # EC2 likes to mount first ephemeral storage here
make_filesystem /dev/xvdb
setup_extra_volume /dev/xvdb /mnt
possible_drives=( a b c d e f g h i j k l m n o p q r s t u v w x y z)
for i in {2..26}
do
  drive=${possible_drives[$i]}
  make_filesystem /dev/xvd${drive}
done

for i in {2..26}
do
  drive=${possible_drives[$i]}
  setup_extra_volume /dev/xvd${drive} /mnt$i
done

# Mount cgroup file system
if [[ ! -e /cgroup ]]; then
  mkdir -p /cgroup
  mount -t cgroup none /cgroup
  echo "none /cgroup cgroup defaults 0 0" >> /etc/fstab
fi

# Format and mount EBS volume (/dev/sdv) as /vol if the device exists
# and we have not already created /vol
if [[ -e /dev/sdv && ! -e /vol ]]; then
  mkdir /vol
  if mkfs.xfs -q /dev/sdv; then
    mount -o $XFS_MOUNT_OPTS /dev/sdv /vol
    echo "/dev/sdv /vol xfs $XFS_MOUNT_OPTS 0 0" >> /etc/fstab
    chmod -R a+w /vol
  else
    # mkfs.xfs is not installed on this machine or has failed;
    # delete /vol so that the user doesn't think we successfully
    # mounted the EBS volume
    rmdir /vol
  fi
elif [[ ! -e /vol ]]; then
  # Not using EBS, but let's mkdir /vol so that we can chmod it
  mkdir /vol
  chmod -R a+w /vol
fi

# Make data dirs writable by non-root users, such as CDH's hadoop user
chmod -R a+w /mnt*

# Remove ~/.ssh/known_hosts because it gets polluted as you start/stop many
# clusters (new machines tend to come up under old hostnames)
rm -f /root/.ssh/known_hosts

# Create swap space on /mnt
/root/spark-ec2/create-swap.sh $SWAP_MB

# Allow memory to be over committed. Helps in pyspark where we fork
echo 1 > /proc/sys/vm/overcommit_memory
