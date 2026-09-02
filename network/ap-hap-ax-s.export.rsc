# 2026-09-02 23:11:24 by RouterOS 7.20.4
#
# model = E62iUGS-2axD5axT
/interface bridge
add admin-mac=04:F4:1C:E9:5A:4B auto-mac=no comment=defconf name=bridge \
    vlan-filtering=yes
/interface vlan
add interface=bridge name=vlan1-mgmt vlan-id=1
/interface wifi datapath
add bridge=bridge name=dp-vlan10 vlan-id=10
add bridge=bridge name=dp-vlan20 vlan-id=20
add bridge=bridge name=dp-vlan30 vlan-id=30
/interface wifi security
add authentication-types=wpa2-psk,wpa3-psk disabled=no ft=yes ft-over-ds=yes \
    name=sec-main
add authentication-types=wpa2-psk disabled=no name=sec-iot
add authentication-types=wpa2-psk,wpa3-psk disabled=no name=sec-guest
/interface wifi
set [ find default-name=wifi1 ] channel.band=2ghz-ax .skip-dfs-channels=\
    10min-cac .width=20/40mhz configuration.mode=ap .ssid=Jehli-Fi datapath=\
    dp-vlan10 disabled=no security=sec-main security.authentication-types=\
    wpa2-psk,wpa3-psk .ft=yes .ft-over-ds=yes
set [ find default-name=wifi2 ] channel.band=5ghz-ax .frequency=\
    5500,5520,5540,5560 .skip-dfs-channels=10min-cac .width=20/40/80mhz \
    configuration.mode=ap .ssid=Jehli-Fi datapath=dp-vlan10 disabled=no \
    security=sec-main security.authentication-types=wpa2-psk,wpa3-psk .ft=yes \
    .ft-over-ds=yes
add configuration.mode=ap .ssid="Jehli-Fi Guest" datapath=dp-vlan30 disabled=\
    no mac-address=06:F4:1C:E9:5A:51 master-interface=wifi1 name=\
    wifi-guest-2g security=sec-guest
add configuration.mode=ap .ssid="Jehli-Fi Guest" datapath=dp-vlan30 disabled=\
    no mac-address=06:F4:1C:E9:5A:52 master-interface=wifi2 name=\
    wifi-guest-5g security=sec-guest
add configuration.mode=ap .ssid=jehlifi_iot datapath=dp-vlan20 disabled=no \
    mac-address=06:F4:1C:E9:5A:50 master-interface=wifi1 name=wifi-iot \
    security=sec-iot
/disk settings
set auto-media-interface=bridge auto-media-sharing=yes auto-smb-sharing=yes
/interface bridge port
add bridge=bridge comment=defconf frame-types=\
    admit-only-untagged-and-priority-tagged interface=ether2
add bridge=bridge comment=defconf frame-types=\
    admit-only-untagged-and-priority-tagged interface=ether3
add bridge=bridge comment=defconf frame-types=\
    admit-only-untagged-and-priority-tagged interface=ether4
add bridge=bridge comment=defconf frame-types=\
    admit-only-untagged-and-priority-tagged interface=ether5
add bridge=bridge comment=defconf frame-types=\
    admit-only-untagged-and-priority-tagged interface=sfp1
add bridge=bridge interface=ether1
/ip neighbor discovery-settings
set discover-interface-list=all
/interface bridge vlan
add bridge=bridge tagged=bridge untagged=\
    ether1,ether2,ether3,ether4,ether5,sfp1 vlan-ids=1
add bridge=bridge tagged=ether1,wifi1,wifi2 vlan-ids=10
add bridge=bridge tagged=ether1,wifi-iot vlan-ids=20
add bridge=bridge tagged=ether1,wifi-guest-2g,wifi-guest-5g vlan-ids=30
/ip address
add address=192.168.0.4/24 interface=vlan1-mgmt network=192.168.0.0
/ip dns
set servers=192.168.0.1
/ip dns static
add address=192.168.88.1 comment=defconf name=router.lan type=A
/ip route
add gateway=192.168.0.1
/ipv6 firewall address-list
add address=::/128 comment="defconf: unspecified address" list=bad_ipv6
add address=::1/128 comment="defconf: lo" list=bad_ipv6
add address=fec0::/10 comment="defconf: site-local" list=bad_ipv6
add address=::ffff:0.0.0.0/96 comment="defconf: ipv4-mapped" list=bad_ipv6
add address=::/96 comment="defconf: ipv4 compat" list=bad_ipv6
add address=100::/64 comment="defconf: discard only " list=bad_ipv6
add address=2001:db8::/32 comment="defconf: documentation" list=bad_ipv6
add address=2001:10::/28 comment="defconf: ORCHID" list=bad_ipv6
add address=3ffe::/16 comment="defconf: 6bone" list=bad_ipv6
/ipv6 firewall filter
add action=accept chain=input comment=\
    "defconf: accept established,related,untracked" connection-state=\
    established,related,untracked
add action=drop chain=input comment="defconf: drop invalid" connection-state=\
    invalid
add action=accept chain=input comment="defconf: accept ICMPv6" protocol=\
    icmpv6
add action=accept chain=input comment="defconf: accept UDP traceroute" \
    dst-port=33434-33534 protocol=udp
add action=accept chain=input comment=\
    "defconf: accept DHCPv6-Client prefix delegation." dst-port=546 protocol=\
    udp src-address=fe80::/10
add action=accept chain=input comment="defconf: accept IKE" dst-port=500,4500 \
    protocol=udp
add action=accept chain=input comment="defconf: accept ipsec AH" protocol=\
    ipsec-ah
add action=accept chain=input comment="defconf: accept ipsec ESP" protocol=\
    ipsec-esp
add action=accept chain=input comment=\
    "defconf: accept all that matches ipsec policy" ipsec-policy=in,ipsec
add action=drop chain=input comment=\
    "defconf: drop everything else not coming from LAN" in-interface-list=\
    !*2000011
add action=fasttrack-connection chain=forward comment="defconf: fasttrack6" \
    connection-state=established,related
add action=accept chain=forward comment=\
    "defconf: accept established,related,untracked" connection-state=\
    established,related,untracked
add action=drop chain=forward comment="defconf: drop invalid" \
    connection-state=invalid
add action=drop chain=forward comment=\
    "defconf: drop packets with bad src ipv6" src-address-list=bad_ipv6
add action=drop chain=forward comment=\
    "defconf: drop packets with bad dst ipv6" dst-address-list=bad_ipv6
add action=drop chain=forward comment="defconf: rfc4890 drop hop-limit=1" \
    hop-limit=equal:1 protocol=icmpv6
add action=accept chain=forward comment="defconf: accept ICMPv6" protocol=\
    icmpv6
add action=accept chain=forward comment="defconf: accept HIP" protocol=139
add action=accept chain=forward comment="defconf: accept IKE" dst-port=\
    500,4500 protocol=udp
add action=accept chain=forward comment="defconf: accept ipsec AH" protocol=\
    ipsec-ah
add action=accept chain=forward comment="defconf: accept ipsec ESP" protocol=\
    ipsec-esp
add action=accept chain=forward comment=\
    "defconf: accept all that matches ipsec policy" ipsec-policy=in,ipsec
add action=drop chain=forward comment=\
    "defconf: drop everything else not coming from LAN" in-interface-list=\
    !*2000011
/system clock
set time-zone-name=Europe/Prague
/system identity
set name=hAP-ax-S
/tool mac-server
set allowed-interface-list=*2000011
/tool mac-server mac-winbox
set allowed-interface-list=*2000011
