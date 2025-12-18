# Make sure the template is off
virsh shutdown netBridge1

# Create and start the first worker
virt-clone --original netBridge1 --name netBridge1-service-1 --auto-clone
virsh start netBridge1-service-1
