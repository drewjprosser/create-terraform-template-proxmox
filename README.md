# Template creation script on proxmox for terraform compatibility

This script creates 2 VMs. The first configures itself using a custom-cloud init, then cleans it's configuration and shuts down.
The second VM is a carbon copy of the first, sans hard drive and custom cloud-init (cicustom flag).
The disk of the first VM is then moved to the second VM. This ensures a clean config for the template.
The second VM is templated and the first is destroyed.

The reason I have to do this is because proxmox will pass all configuration data to Terraform using the provider, including the cicustom parameter.
When the cicustom configuration is set, it will not pass any proxmox default cloud-init drive data to the VM, including hostname, etc.
What I wanted was a VM that has a custom cloud-init config, but also had a dynamic hostname, based on the Terraform config.
In order to do that, I had to configure the first VM, then move the disk to the second VM, to ensure a clean config for Terraform.
