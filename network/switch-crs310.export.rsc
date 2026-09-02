# 2026-09-02 21:11:25 by RouterOS 7.24.1
#
# model = CRS310-8G+2S+
/interface bridge
add admin-mac=04:F4:1C:5F:88:57 auto-mac=no comment=defconf name=bridge \
    vlan-filtering=yes
/interface vlan
add interface=bridge name=vlan1-mgmt vlan-id=1
add interface=bridge name=vlan10-lab vlan-id=10
add comment=l3-routing interface=bridge name=vlan40-vms vlan-id=40
/interface bridge port
add bridge=bridge comment=Stul interface=ether1 pvid=10
add bridge=bridge comment=AP interface=ether2
add bridge=bridge comment=defconf interface=ether3 pvid=10
add bridge=bridge comment=defconf interface=ether4
add bridge=bridge comment=defconf interface=ether5 pvid=10
add bridge=bridge comment=defconf interface=ether6 pvid=10
add bridge=bridge comment=defconf interface=ether7 pvid=20
add bridge=bridge comment=defconf interface=ether8
add bridge=bridge comment=defconf interface=sfp-sfpplus1
add bridge=bridge comment=defconf interface=sfp-sfpplus2
/interface bridge vlan
add bridge=bridge tagged=bridge vlan-ids=1
add bridge=bridge comment=Host tagged=\
    ether7,ether8,ether4,ether6,ether2,bridge untagged=ether1,ether3,ether5 \
    vlan-ids=10
add bridge=bridge comment=IoT tagged=ether8,ether2,bridge,ether4,ether6 \
    untagged=ether7 vlan-ids=20
add bridge=bridge comment=Guest tagged=ether7,ether8,ether2,bridge vlan-ids=\
    30
add bridge=bridge comment=VMs tagged=ether7,ether4,ether6,ether8,bridge \
    vlan-ids=40
/interface ethernet switch
set switch1 l3-hw-offloading=yes
/ip address
add address=10.0.10.2/24 comment=hosts interface=vlan10-lab network=10.0.10.0
add address=192.168.0.3/24 comment=mgmt interface=vlan1-mgmt network=\
    192.168.0.0
add address=10.0.40.2/24 comment=l3-routing interface=vlan40-vms network=\
    10.0.40.0
/ip dns
set servers=10.0.10.1,1.1.1.1
/ip route
add comment=lan-gateway dst-address=0.0.0.0/0 gateway=10.0.10.1
/system clock
set time-zone-name=Europe/Prague
/system swos
set address-acquisition-mode=static identity=Mikrotik-switch \
    static-ip-address=192.168.0.3
