#!/bin/bash

# Initial Variables
initial_vmid=999

# AlmaLinux 9 Vars
alma_qcow2=AlmaLinux-9-GenericCloud-latest.x86_64.qcow2
alma_qcow2_link=https://repo.almalinux.org/almalinux/9/cloud/x86_64/images/$alma_qcow2
alma_template_name=alma-9-cloud-template
alma_config=user-config-alma.yml

# Debian 12 Vars
debian_qcow2=debian-12-generic-amd64.qcow2
debian_qcow2_link=https://cloud.debian.org/images/cloud/bookworm/latest/$debian_qcow2
debian_template_name=debian-12-cloud-template
debian_config=user-config-debian.yml

# Ubuntu 22.04 Vars
ubuntu_qcow2=ubuntu-22.04-server-cloudimg-amd64.qcow2
ubuntu_img=ubuntu-22.04-server-cloudimg-amd64.img
ubuntu_img_link=https://cloud-images.ubuntu.com/releases/jammy/release/$ubuntu_img
ubuntu_template_name=ubuntu-2204-cloud-template
ubuntu_config=user-config-ubuntu.yml

# PVE Vars
resource_path=/mnt/pve/resources/snippets

# Choose which distro to template
choose_distro () {
    read -p $'Choose distro: \n[1]Ubuntu 22.04 \n[2]AlmaLinux 9 \n[3]Debian 12 \n\nInput: ' choice
    case "$choice" in
        1)
            # Remove Ubuntu img if it exists, then re-download, rename, and resize. Set template to correct name.
            if [ -e $ubuntu_img ]
            then
                rm $ubuntu_img
            fi

            wget $ubuntu_img_link
            mv $ubuntu_img $ubuntu_qcow2
            qemu-img resize $ubuntu_qcow2 10G

            template_name=$ubuntu_template_name
            template_qcow2=$ubuntu_qcow2
            template_config=$ubuntu_config
        ;;  
        2)
            # Remove AlmaLinux QCOW2 if it exists, then redownload. Set template to correct name.
            if [ -e $alma_qcow2 ]
            then
                rm $alma_qcow2
            fi

            wget $alma_qcow2_link

            template_name=$alma_template_name
            template_qcow2=$alma_qcow2
            template_config=$alma_config
        ;;
        3)
            # Remove Debian QCOW2 if it exists, then redownload. Set template to correct name.
            if [ -e $debian_qcow2 ]
            then
                rm $debian_qcow2
            fi

            wget $debian_qcow2_link
            qemu-img resize $debian_qcow2 10G

            template_name=$debian_template_name
            template_qcow2=$debian_qcow2
            template_config=$debian_config
        ;;
    esac
}

# Finds if the template already exists, and destroys it.
name_test () {
    local name_test=$( qm list | grep -w $template_name$ | awk '{print $1}' )
    if [ -n "$name_test" ]
    then
        echo "VM found: $name_test"
        qm stop $name_test
        qm wait $name_test
        qm destroy $name_test --destroy-unreferenced-disks 1
        echo "VM $name_test destroyed"
    fi
}

# If the "-initial" version of the template exists, destroy it.
vmid_test () {
    local vmid_test=$( qm list | grep $initial_vmid | awk '{print $1}' )
    if [ -n "$vmid_test" ]
    then
        echo "VM found: $vmid_test"
        qm stop $vmid_test
        qm wait $vmid_test
        qm destroy $vmid_test --destroy-unreferenced-disks 1
        echo "VM $vmid_test destroyed"
    fi
}


# Finds the lowest available VMID
find_template_vmid () {
    vmids_over_1000=($( pvesh get /cluster/resources --type vm --noborder --noheader | awk '{print $1}' | cut -c 6- | sort | grep -e "1..." ))

    if [ "${vmids_over_1000[0]}" -eq 1000 ]
    then
        for i in "${!vmids_over_1000[@]}"
        do
            j=$(( $i + 1 ))
            if [ $(( "${vmids_over_1000[$j]}" - "${vmids_over_1000[$i]}" )) -ne 1 ]
            then
                template_vmid=$(("${vmids_over_1000[$i]}" + 1 ))
                break
            fi
        done
    else
        template_vmid=1000
    fi 

    echo "Output: $template_vmid"
}


# Checks if cloud-init config file exists.
user_config_test () {
    if [ ! -e $resource_path/$template_config ]
        then
            echo "No config files found."
            exit 1
    fi
}

# Creates initial VM for custom cloud-init configuration
create_initial_vm () {
    qm create $initial_vmid --name "$template_name-initial" --memory 2048 --cores 2 --agent 1 --net0 virtio,bridge=vmbr0 --ostype l26 --cpu host
    qm set $initial_vmid --scsihw virtio-scsi-pci --cicustom "user=resources:snippets/$template_config"
    qm importdisk $initial_vmid $template_qcow2 VM_Storage
    qm set $initial_vmid --scsi0 VM_Storage:vm-$initial_vmid-disk-0,discard=on,ssd=1,iothread=0 --boot order=scsi0
    qm set $initial_vmid --ide0 VM_Storage:cloudinit --serial0 socket --vga serial0 --ipconfig0 "ip=dhcp"
    qm start $initial_vmid
}

# Creates final template config without disk; the disk will be imported later
create_template_vm () {
    qm create $template_vmid --name "$template_name" --memory 2048 --cores 2 --agent 1 --net0 virtio,bridge=vmbr0 --ostype l26 --cpu host
    qm set $template_vmid --scsihw virtio-scsi-pci --ide0 VM_Storage:cloudinit --serial0 socket --vga serial0 --ipconfig0 "ip=dhcp"
}

# Waits for initial VM to boot
wait_for_boot () {
    until [ $( qm guest exec $initial_vmid -- /bin/bash -c 'sudo systemctl status cloud-final' | grep -c "Finished" ) -eq 1 ]
        do 
            echo "Waiting for first VM boot to complete"
    done
}

# Cleans initial VM to create image for template. Then shutsdown inital VM.
clean_initial_vm_and_reboot () {

    echo "First boot complete, cleaning"

    qm guest exec $initial_vmid -- /bin/bash -c 'sudo cloud-init clean --machine-id && sudo shutdown -h now'
    qm wait $initial_vmid
}

# Moves disk from inital VM to template VM, destroys initial VM and templates template VM.
move_disk_and_create_template () {
    qm disk move $initial_vmid scsi0 --target-vmid $template_vmid
    qm set $template_vmid --boot order=scsi0

    qm destroy $initial_vmid

    qm template $template_vmid
    echo "Template created"
}

choose_distro

name_test

vmid_test

find_template_vmid

user_config_test

create_initial_vm

create_template_vm

wait_for_boot

clean_initial_vm_and_reboot

move_disk_and_create_template