# 2026-11-11 12:42:01 by RouterOS 7.25.1
#
# model = CRS310-8G+2S+
/ip ssh
set host-key-type=rsa known-hosts-validation=no
/ip service
set ftp disabled=yes
set ssh available-from=192.168.0.0/24,10.0.10.0/24
set telnet disabled=yes
set www available-from=192.168.0.0/24,10.0.10.0/24
set reverse-proxy available-from=192.168.0.0/24,10.0.10.0/24
set winbox available-from=192.168.0.0/24,10.0.10.0/24
set api disabled=yes
set api-ssl disabled=yes
/interface bridge
add admin-mac=04:F4:1C:5F:88:57 auto-mac=no comment=defconf name=bridge \
    vlan-filtering=yes
/interface vlan
add interface=bridge name=vlan1-mgmt vlan-id=1
add interface=bridge name=vlan10-lab vlan-id=10
add comment=l3-routing interface=bridge name=vlan40-vms vlan-id=40
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
/system ntp client
set enabled=yes
/system ntp client servers
add address=10.0.10.1
add address=time.google.com
/system swos
set address-acquisition-mode=static identity=Mikrotik-switch \
    static-ip-address=192.168.0.3
/user ssh-keys
add info=jsolon@aurelius key="ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCYT+1tcTF1\
    P4aUv2GGhfR1Hd9AFiaDZwkvv+f+N+fgIQyblRzDqUMeZOUGC3RtEiOWdq3Ruk4bcWSvoe3g5F\
    4EuxIppzPQlvSeZZ7zNeXP7VdXsgmmunmKvVDBR8c8dLWygOnkeiceiyvZ0IyeaAhEhGk8vsCw\
    o6wmGkj0t6jNJFDv4svs1u+oppIaFk2pwizblemIxgXrD+ye3dhKTlkGp5v64FeykLkK9oknKB\
    Wq8bPeb+L49MPaiAEtpZwSmfkYVau0hR39/AjBM5WpH1YlNaqpigxpWI5Rw17hJZDvBNnGlDye\
    Z0GdX7zCdTuwwm746qjRUUat/WhU419OY39x0+rz0+KphWs97GE6Jk36KZC9wNujxakyzIwWmm\
    s2ibecU944bufSdn602/YDtC5e8bhvc0A8HZZXFNn9AULaCluZWWJLvaaUo3fF5TgjQ+qEPFtS\
    9fam+UTASHwNZcAsOykeNkvj2u+8FVkDVPR9C4YvoHVZfqbRkQdeXpfLxJc=" user=<REDACTED>
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
