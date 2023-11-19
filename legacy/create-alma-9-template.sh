#!/bin/bash

# This script creates 2 VMs. The first configures itself using a custom-cloud init, then cleans it's configuration and shuts down.
# The second VM is a carbon copy of the first, sans hard drive and custom cloud-init (cicustom flag).
# The disk of the first VM is then moved to the second VM. This ensures a clean config for the template. 
# The second VM is templated and the first is destroyed.


# The reason I have to do this is because proxmox will pass all configuration data to Terraform using the provider, including the cicustom parameter.
# When the cicustom configuration is set, it will not pass any proxmox default cloud-init drive data to the VM, including hostname, etc.
# What I wanted was a VM that has a custom cloud-init config, but also had a dynamic hostname, based on the Terraform config.
# In order to do that, I had to configure the first VM, then move the disk to the second VM, to ensure a clean config for Terraform.

# Variables
vmid_0=1004
vmid_1=$(($vmid_0 + 1))
alma_qcow2=AlmaLinux-9-GenericCloud-latest.x86_64.qcow2
resource_path=/mnt/pve/resources/snippets

# Test if VMs exist already, stop and destroy if true
vm_test () {
    i=0    
    while [ $i -lt 2 ]
    do
        vmid_test=$( qm list | awk '{print $1}' | grep $(($vmid_0 + $i)) )
        echo "VM queried: $(($vmid_0 + $i))"
        echo "VM found: $vmid_test"
        if [ "$vmid_test" == "$(($vmid_0 + $i))" ]
        then
            qm stop $(($vmid_0 + $i))
            qm wait $(($vmid_0 + $i))
            qm destroy $(($vmid_0 + $i)) --destroy-unreferenced-disks 1
            echo "VM $(($vmid_0 + $i)) destroyed"
        fi
        ((i++))
    done
}
vm_test 

# Get almalinux cloud image and convert to qcow2, then resize
# wget https://repo.almalinux.org/almalinux/9/cloud/x86_64/images/AlmaLinux-9-GenericCloud-latest.x86_64.qcow2
# qemu-img resize $alma_qcow2 16G

# Check for cloud-init files
if [ ! -e $resource_path/alma-user-config.yml ]
    then
        echo "No config files found."
        exit 1
fi

# Create, configure VMs
create_vm () {
    local vmid_var=$(($vmid_0 + $1))
    qm create $vmid_var --name "alma-9-cloud-template$1" --memory 2048 --cores 2 --agent 1 --net0 virtio,bridge=vmbr0 --ostype l26 --cpu host
    qm set $vmid_var --scsihw virtio-scsi-pci
    if [ "$vmid_var" == "$vmid_0" ]
        then
            qm set $vmid_var --cicustom "user=resources:snippets/alma-user-config.yml"
            qm importdisk $vmid_var $alma_qcow2 VM_Storage
            qm set $vmid_var --scsi0 VM_Storage:vm-$vmid_var-disk-0,discard=on,ssd=1,iothread=0
            qm set $vmid_var --boot order=scsi0
    fi
    qm set $vmid_var --ide0 VM_Storage:cloudinit
    qm set $vmid_var --serial0 socket --vga serial0
    qm set $vmid_var --ipconfig0 "ip=dhcp"
}

create_vm 0
create_vm 1

qm start $vmid_0

# Wait for VM 1 to boot, then clean by resetting machine-id and cloud-init clean
until [ $( qm guest exec $vmid_0 -- /bin/bash -c 'sudo systemctl status cloud-final' | grep -c "Finished" ) -eq 1 ]
    do 
        echo "Waiting for first VM boot to complete"
done

echo "First boot complete, cleaning"

qm guest exec $vmid_0 -- /bin/bash -c 'sudo cloud-init clean --machine-id && sudo shutdown -h now'
qm wait $vmid_0


# Move disk from VM1 to VM2 and set boot device for VM2
qm disk move $vmid_0 scsi0 --target-vmid $(($vmid_0 + 1))
qm set $vmid_1 --boot order=scsi0

# Destroy VM1
qm destroy $vmid_0

# Create template
qm template $vmid_1
echo "Template created"