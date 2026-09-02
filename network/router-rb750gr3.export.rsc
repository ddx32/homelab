# 2026-09-02 21:11:21 by RouterOS 7.24
#
# model = RB750Gr3
/interface bridge
add admin-mac=18:FD:74:2B:0F:A4 auto-mac=no comment="Internal LAN" \
    ingress-filtering=no name=lan_bridge port-cost-mode=short vlan-filtering=\
    yes
/interface vlan
add interface=lan_bridge name=vlan10-lab vlan-id=10
add interface=lan_bridge name=vlan20-iot vlan-id=20
add interface=lan_bridge name=vlan30-guest vlan-id=30
add interface=lan_bridge name=vlan40-vms vlan-id=40
add interface=ether1 name=vlan848-isp vlan-id=848
/interface pppoe-client
add add-default-route=yes disabled=no interface=vlan848-isp max-mru=1492 \
    max-mtu=1492 name=pppoe-o2 user=<REDACTED>
/interface list
add comment=defconf name=WAN
add comment=defconf name=LAN
/interface lte apn
set [ find default=yes ] ip-type=ipv4 use-network-apn=no
/interface wireless security-profiles
set [ find default=yes ] supplicant-identity=MikroTik
/ip dhcp-server option
add code=121 name=classless-v10-121 value=0x000A000A01180A00280A000A02
add code=249 name=classless-v10-249 value=0x000A000A01180A00280A000A02
add code=121 name=classless-v40-121 value=0x000A002801180A000A0A002802
add code=249 name=classless-v40-249 value=0x000A002801180A000A0A002802
/ip pool
add comment="IoT devices" name=vlan20-iot ranges=10.0.20.50-10.0.20.254
add name=vlan10-lab ranges=10.0.10.50-10.0.10.200
add name=netadmin ranges=192.168.0.50-192.168.0.150
add name=vlan30-guest ranges=10.0.30.50-10.0.30.200
add name=vlan40-vms ranges=10.0.40.50-10.0.40.200
/ip dhcp-server
add address-pool=netadmin interface=lan_bridge lease-time=6h name=defconf
add address-pool=vlan10-lab interface=vlan10-lab lease-time=12h name=\
    vlan10-lab
add address-pool=vlan20-iot interface=vlan20-iot lease-time=6h name=\
    vlan20-iot
add address-pool=vlan30-guest interface=vlan30-guest name=vlan30-guest
add address-pool=vlan40-vms interface=vlan40-vms name=vlan40-vms
/ip smb users
set [ find default=yes ] disabled=yes
/routing bgp template
set default disabled=no output.network=bgp-networks
/routing ospf instance
add disabled=no name=default-v2
/routing ospf area
add disabled=yes instance=default-v2 name=backbone-v2
/routing table
add fib name=prusa-vpn
/interface bridge port
add bridge=lan_bridge comment=defconf interface=ether2 internal-path-cost=10 \
    path-cost=10
add bridge=lan_bridge comment=defconf ingress-filtering=no interface=ether3 \
    internal-path-cost=10 path-cost=10 pvid=10
add bridge=lan_bridge comment=defconf ingress-filtering=no interface=ether4 \
    internal-path-cost=10 path-cost=10
add bridge=lan_bridge comment=defconf ingress-filtering=no interface=ether5 \
    internal-path-cost=10 path-cost=10
/ip firewall connection tracking
set udp-timeout=10s
/ip neighbor discovery-settings
set discover-interface-list=LAN
/ipv6 settings
set disable-ipv6=yes max-neighbor-entries=8192
/interface bridge vlan
add bridge=lan_bridge tagged=ether2 vlan-ids=20
add bridge=lan_bridge tagged=ether2 vlan-ids=10
add bridge=lan_bridge tagged=ether2 vlan-ids=30
add bridge=lan_bridge tagged=ether2 vlan-ids=40
add bridge=lan_bridge comment="added by pvid" untagged=lan_bridge vlan-ids=1
/interface detect-internet
set detect-interface-list=all
/interface list member
add comment=defconf interface=lan_bridge list=LAN
add comment=defconf interface=ether1 list=WAN
/interface ovpn-server server
add auth=sha1,md5 mac-address=FE:01:7A:F1:0F:9A name=ovpn-server1
/ip address
add address=192.168.0.1/24 comment="Internal LAN subnet" interface=lan_bridge \
    network=192.168.0.0
add address=10.0.10.1/24 interface=vlan10-lab network=10.0.10.0
add address=10.0.20.1/24 interface=vlan20-iot network=10.0.20.0
add address=10.0.30.1/24 interface=vlan30-guest network=10.0.30.0
add address=10.0.40.1/24 interface=vlan40-vms network=10.0.40.0
/ip dhcp-client
add comment=defconf interface=ether1 name=ether1
/ip dhcp-server lease
add address=10.0.20.251 client-id=1:64:90:c1:5:c:19 comment="Valetudo robot" \
    mac-address=64:90:C1:05:0C:19 server=vlan20-iot
add address=10.0.10.128 client-id=1:d8:3a:dd:95:6:ed mac-address=\
    D8:3A:DD:95:06:ED server=vlan10-lab
add address=10.0.20.248 comment="Corleone CORE ONE" mac-address=\
    3C:E9:0E:DC:03:E1 server=vlan20-iot
add address=10.0.10.156 comment="Garazista mk3.5" mac-address=\
    C4:D8:D5:1D:95:FD server=vlan10-lab
add address=10.0.20.229 client-id=1:14:5d:34:95:71:e4 comment=\
    "Buddy3D camera" mac-address=14:5D:34:95:71:E4 server=vlan20-iot
/ip dhcp-server network
add address=10.0.10.0/24 comment=vlan10-lab dhcp-option=\
    classless-v10-121,classless-v10-249 dns-server=192.168.0.1 domain=\
    lan.jehli.net gateway=10.0.10.1 netmask=24
add address=10.0.20.0/24 comment=vlan20-iot dns-server=10.0.20.1 gateway=\
    10.0.20.1 netmask=24
add address=10.0.30.0/24 comment=vlan30-guest dns-server=1.1.1.1,8.8.8.8 \
    gateway=10.0.30.1 netmask=24
add address=10.0.40.0/24 comment=vlan40-vms dhcp-option=\
    classless-v40-121,classless-v40-249 dns-server=10.0.40.1 gateway=\
    10.0.40.1 netmask=24
add address=192.168.0.0/24 dns-server=192.168.0.1 domain=lan.jehli.net \
    gateway=192.168.0.1 netmask=24
/ip dns
set allow-remote-requests=yes max-udp-packet-size=512 mdns-repeat-ifaces=\
    vlan10-lab,vlan20-iot,vlan40-vms servers=8.8.8.8,1.1.1.1
/ip dns static
add address=192.168.88.1 comment=defconf name=router.lan type=A
add address=10.2.0.29 name=dev.connect.prusa type=A
add comment="k8s CoreDNS - LAN infra names" forward-to=10.0.40.102 \
    match-subdomain=yes name=lan.jehli.net type=FWD
/ip firewall address-list
add address=192.168.0.0/24 comment=\
    "RFC1918 segments - used by VLAN isolation rules" list=internal
add address=10.0.10.0/24 comment=\
    "RFC1918 segments - used by VLAN isolation rules" list=internal
add address=10.0.20.0/24 comment=\
    "RFC1918 segments - used by VLAN isolation rules" list=internal
add address=10.0.30.0/24 comment=\
    "RFC1918 segments - used by VLAN isolation rules" list=internal
add address=10.0.40.0/24 comment=\
    "RFC1918 segments - used by VLAN isolation rules" list=internal
add address=192.168.0.0/24 comment="may reach router management services" \
    list=mgmt-allowed
add address=10.0.10.0/24 comment="may reach router management services" list=\
    mgmt-allowed
/ip firewall filter
add action=accept chain=input comment=\
    "defconf: accept established,related,untracked" connection-state=\
    established,related,untracked
add action=drop chain=input comment="defconf: drop invalid" connection-state=\
    invalid
add action=accept chain=input comment="defconf: accept ICMP" protocol=icmp
add action=accept chain=input comment=\
    "defconf: accept to local loopback (for CAPsMAN)" dst-address=127.0.0.1
add action=accept chain=forward comment="defconf: accept in ipsec policy" \
    ipsec-policy=in,ipsec
add action=accept chain=forward comment="defconf: accept out ipsec policy" \
    ipsec-policy=out,ipsec
add action=fasttrack-connection chain=forward comment="defconf: fasttrack" \
    connection-state=established,related
add action=accept chain=forward comment=\
    "defconf: accept established,related, untracked" connection-state=\
    established,related,untracked
add action=drop chain=forward comment="defconf: drop invalid" \
    connection-state=invalid
add action=drop chain=forward comment=\
    "defconf: drop all from WAN not DSTNATed" connection-nat-state=!dstnat \
    connection-state=new in-interface-list=WAN
add action=accept chain=forward comment="Allow internet traffic" \
    in-interface-list=LAN out-interface-list=WAN
add action=accept chain=forward comment="iot: allow MQTT to broker" \
    dst-address=10.0.40.0/24 dst-port=1883 in-interface=vlan20-iot protocol=\
    tcp
add action=drop chain=forward comment="isolate iot from other VLANs" \
    dst-address-list=internal in-interface=vlan20-iot log=yes log-prefix=\
    iot-drop
add action=drop chain=forward comment="isolate guest from other VLANs" \
    dst-address-list=internal in-interface=vlan30-guest log=yes log-prefix=\
    guest-drop
add action=accept chain=input comment="input: DHCP (all VLANs)" dst-port=\
    67,68 protocol=udp
add action=accept chain=input comment="input: DNS udp from LAN" dst-port=53 \
    protocol=udp src-address-list=internal
add action=accept chain=input comment="input: DNS tcp from LAN" dst-port=53 \
    protocol=tcp src-address-list=internal
add action=accept chain=input comment="input: mDNS repeater" dst-port=5353 \
    protocol=udp
add action=accept chain=input comment="input: IGMP for multicast" protocol=\
    igmp
add action=accept chain=input comment="input: MikroTik neighbour discovery" \
    dst-port=5678 protocol=udp src-address-list=internal
add action=accept chain=input comment="input: management from mgmt+lab only" \
    dst-port=2200,8291,80,443 protocol=tcp src-address-list=mgmt-allowed
add action=drop chain=input comment="input: drop everything else" log=yes \
    log-prefix=inputdrop
/ip firewall mangle
add action=mark-routing chain=prerouting new-routing-mark=prusa-vpn \
    src-address=192.168.1.12
/ip firewall nat
add action=masquerade chain=srcnat out-interface=pppoe-o2
/ip firewall service-port
set ftp disabled=yes
/ip ipsec profile
set [ find default=yes ] dpd-interval=2m dpd-maximum-failures=5
/ip route
add disabled=yes distance=1 dst-address=0.0.0.0/0 gateway="" pref-src="" \
    routing-table=prusa-vpn scope=30 target-scope=10
/ip service
set ftp disabled=yes
set telnet disabled=yes
set www available-from=192.168.0.0/24,10.0.10.0/24
set www-ssl available-from=192.168.0.0/24,10.0.10.0/24 disabled=no
set ssh available-from=192.168.0.0/24,10.0.10.0/24 port=2200
set winbox available-from=192.168.0.0/24,10.0.10.0/24
set api disabled=yes
set api-ssl disabled=yes
/routing bfd configuration
add disabled=no interfaces=all min-rx=200ms min-tx=200ms multiplier=5
/system clock
set time-zone-name=Europe/Prague
/system identity
set name=Godfrey
/tool mac-server
set allowed-interface-list=LAN
/tool mac-server mac-winbox
set allowed-interface-list=LAN
/tool sniffer
set filter-interface=lan_bridge filter-ip-address=10.0.40.100/32
