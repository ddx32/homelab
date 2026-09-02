# RB750Gr3 (hEX) — router, DHCP, DNS, firewall
#
# Idempotent: every block is find-then-add-or-update, so re-running converges.
# Not covered: defconf firewall/NAT rules, PPPoE credentials, per-host DHCP leases.
# Apply:  /import file-name=router-rb750gr3.rsc
#
# See README.md for what this describes and why.

:log info "netcfg: router begin"

# ---------------------------------------------------------------- bridge
:local b [/interface/bridge/find where name="lan_bridge"]
:if ([:len $b] = 0) do={
  /interface/bridge/add name=lan_bridge comment="Internal LAN" vlan-filtering=yes auto-mac=no
} else={
  /interface/bridge/set $b comment="Internal LAN" vlan-filtering=yes
}

# ------------------------------------------------------- vlan interfaces
# name / id / parent
:local vlans {
  {"vlan10-lab";10;"lan_bridge"};
  {"vlan20-iot";20;"lan_bridge"};
  {"vlan30-guest";30;"lan_bridge"};
  {"vlan40-vms";40;"lan_bridge"};
  {"vlan848-isp";848;"ether1"}
}
:foreach v in=$vlans do={
  :local n [:pick $v 0]; :local id [:pick $v 1]; :local par [:pick $v 2]
  :local f [/interface/vlan/find where name=$n]
  :if ([:len $f] = 0) do={
    /interface/vlan/add name=$n vlan-id=$id interface=$par
  } else={
    /interface/vlan/set $f vlan-id=$id interface=$par
  }
}

# --------------------------------------------------------- bridge ports
# ether2 is the trunk to the CRS310. ether3-5 are unused lab access ports.
:foreach p in={"ether2";"ether3";"ether4";"ether5"} do={
  :if ([:len [/interface/bridge/port/find where interface=$p]] = 0) do={
    /interface/bridge/port/add bridge=lan_bridge interface=$p
  }
}
# ether3 carries untagged vlan10 if anything is plugged in
:local p3 [/interface/bridge/port/find where interface="ether3"]
:if ([:len $p3] > 0) do={ /interface/bridge/port/set $p3 pvid=10 }

# ------------------------------------------------- bridge vlan (tagging)
# All four service VLANs are tagged toward the switch on ether2.
:foreach id in={10;20;30;40} do={
  :local f [/interface/bridge/vlan/find where bridge="lan_bridge" and vlan-ids=$id and !dynamic]
  :if ([:len $f] = 0) do={
    /interface/bridge/vlan/add bridge=lan_bridge vlan-ids=$id tagged=ether2
  } else={
    /interface/bridge/vlan/set $f tagged=ether2
  }
}

# ---------------------------------------------------- interface lists
:foreach l in={"WAN";"LAN"} do={
  :if ([:len [/interface/list/find where name=$l]] = 0) do={ /interface/list/add name=$l }
}
:if ([:len [/interface/list/member/find where list="LAN" and interface="lan_bridge"]] = 0) do={
  /interface/list/member/add list=LAN interface=lan_bridge
}
:if ([:len [/interface/list/member/find where list="WAN" and interface="ether1"]] = 0) do={
  /interface/list/member/add list=WAN interface=ether1
}

# ------------------------------------------------------------ addressing
# address / interface / comment
:local addrs {
  {"192.168.0.1/24";"lan_bridge";"Management"};
  {"10.0.10.1/24";"vlan10-lab";"lab"};
  {"10.0.20.1/24";"vlan20-iot";"iot"};
  {"10.0.30.1/24";"vlan30-guest";"guest"};
  {"10.0.40.1/24";"vlan40-vms";"vms"}
}
:foreach a in=$addrs do={
  :local ad [:pick $a 0]; :local i [:pick $a 1]; :local c [:pick $a 2]
  :local f [/ip/address/find where interface=$i and !dynamic]
  :if ([:len $f] = 0) do={
    /ip/address/add address=$ad interface=$i comment=$c
  } else={
    /ip/address/set $f address=$ad comment=$c
  }
}

# ------------------------------------------------------------- dhcp pools
# name / range
:local pools {
  {"netadmin";"192.168.0.50-192.168.0.150"};
  {"vlan10-lab";"10.0.10.50-10.0.10.200"};
  {"vlan20-iot";"10.0.20.50-10.0.20.254"};
  {"vlan30-guest";"10.0.30.50-10.0.30.200"};
  {"vlan40-vms";"10.0.40.50-10.0.40.200"}
}
:foreach p in=$pools do={
  :local n [:pick $p 0]; :local r [:pick $p 1]
  :local f [/ip/pool/find where name=$n]
  :if ([:len $f] = 0) do={ /ip/pool/add name=$n ranges=$r } else={ /ip/pool/set $f ranges=$r }
}

# ----------------------------------------------------------- dhcp servers
# name / interface / pool / lease
:local dhcp {
  {"defconf";"lan_bridge";"netadmin";"6h"};
  {"vlan10-lab";"vlan10-lab";"vlan10-lab";"12h"};
  {"vlan20-iot";"vlan20-iot";"vlan20-iot";"6h"};
  {"vlan30-guest";"vlan30-guest";"vlan30-guest";"10m"};
  {"vlan40-vms";"vlan40-vms";"vlan40-vms";"10m"}
}
:foreach d in=$dhcp do={
  :local n [:pick $d 0]; :local i [:pick $d 1]; :local pl [:pick $d 2]; :local lt [:pick $d 3]
  :local f [/ip/dhcp-server/find where name=$n]
  :if ([:len $f] = 0) do={
    /ip/dhcp-server/add name=$n interface=$i address-pool=$pl lease-time=$lt disabled=no
  } else={
    /ip/dhcp-server/set $f interface=$i address-pool=$pl lease-time=$lt disabled=no
  }
}

# ---------------------------------------------------- dhcp network options
# subnet / gateway / dns / domain   (empty domain = none handed out)
:local nets {
  {"10.0.10.0/24";"10.0.10.1";"192.168.0.1";"lan.jehli.net";"vlan10-lab"};
  {"10.0.20.0/24";"10.0.20.1";"10.0.20.1";"";"vlan20-iot"};
  {"10.0.30.0/24";"10.0.30.1";"1.1.1.1,8.8.8.8";"";"vlan30-guest"};
  {"10.0.40.0/24";"10.0.40.1";"10.0.40.1";"";"vlan40-vms"};
  {"192.168.0.0/24";"192.168.0.1";"192.168.0.1";"lan.jehli.net";"mgmt"}
}
:foreach n in=$nets do={
  :local sub [:pick $n 0]; :local gw [:pick $n 1]; :local dns [:pick $n 2]
  :local dom [:pick $n 3]; :local cm [:pick $n 4]
  :local f [/ip/dhcp-server/network/find where address=$sub]
  :if ([:len $f] = 0) do={
    /ip/dhcp-server/network/add address=$sub gateway=$gw dns-server=$dns comment=$cm netmask=24
  } else={
    # netmask is an explicit override and does NOT follow the address - changing
    # the address alone leaves clients with the old mask.
    /ip/dhcp-server/network/set $f gateway=$gw dns-server=$dns comment=$cm netmask=24
  }
  :if ($dom != "") do={
    /ip/dhcp-server/network/set [/ip/dhcp-server/network/find where address=$sub] domain=$dom
  }
}

# -------------------------------------------------------------------- dns
# Recursive resolver for all VLANs. mDNS repeated across the VLANs that need
# cross-VLAN discovery (vlan40 is where the NAS lives).
/ip/dns/set servers=8.8.8.8,1.1.1.1 allow-remote-requests=yes \
  mdns-repeat-ifaces=vlan10-lab,vlan20-iot,vlan40-vms

# lan.jehli.net is served by CoreDNS in k3s. One forward-to per entry: a
# comma-separated list parses but SERVFAILs every query.
:local dnsfwd [/ip/dns/static/find where name="lan.jehli.net" and forward-to="10.0.40.102"]
:if ([:len $dnsfwd] = 0) do={
  /ip/dns/static/add name=lan.jehli.net type=FWD forward-to=10.0.40.102 \
    match-subdomain=yes comment="k8s CoreDNS - LAN infra names"
} else={
  /ip/dns/static/set $dnsfwd type=FWD match-subdomain=yes disabled=no \
    comment="k8s CoreDNS - LAN infra names"
}

# Second replica. Disabled on purpose: RouterOS only uses the first matching
# entry, so this is a manual switch, not automatic failover.
:local dnsfwd2 [/ip/dns/static/find where name="lan.jehli.net" and forward-to="10.0.40.104"]
:if ([:len $dnsfwd2] = 0) do={
  /ip/dns/static/add name=lan.jehli.net type=FWD forward-to=10.0.40.104 \
    match-subdomain=yes disabled=yes \
    comment="k8s CoreDNS replica 2 - MANUAL fallback only, no auto-failover"
}

:local prusa [/ip/dns/static/find where name="dev.connect.prusa"]
:if ([:len $prusa] = 0) do={
  /ip/dns/static/add name=dev.connect.prusa type=A address=10.2.0.29
} else={
  /ip/dns/static/set $prusa type=A address=10.2.0.29
}

# ------------------------------------------------------------------- wan
# PPPoE to O2 over vlan848. Credentials are NOT in version control - set once:
#   /interface/pppoe-client/set [find name=pppoe-o2] user=<u> password=<p>
:local pppoe [/interface/pppoe-client/find where name="pppoe-o2"]
:if ([:len $pppoe] = 0) do={
  /interface/pppoe-client/add name=pppoe-o2 interface=vlan848-isp \
    add-default-route=yes max-mtu=1492 max-mru=1492 disabled=no
  :log warning "netcfg: pppoe-o2 created WITHOUT credentials - set user/password"
} else={
  /interface/pppoe-client/set $pppoe interface=vlan848-isp add-default-route=yes \
    max-mtu=1492 max-mru=1492 disabled=no
}

# -------------------------------------------------- vlan isolation (iot/guest)
# IoT and guest may reach the internet but must not initiate connections into
# any other VLAN. Traffic in the other direction still works: the defconf
# "accept established,related" rule sits ahead of these drops, so replies to
# connections started from mgmt/lab/vms flow normally.
#
# These rules only need to exist on the router because it is the only L3 hop
# for vlan20 and vlan30 — the CRS310 has no address on those VLANs.

:foreach n in={"192.168.0.0/24";"10.0.10.0/24";"10.0.20.0/24";"10.0.30.0/24";"10.0.40.0/24"} do={
  :if ([:len [/ip/firewall/address-list/find where list="internal" and address=$n]] = 0) do={
    /ip/firewall/address-list/add list=internal address=$n \
      comment="RFC1918 segments - used by VLAN isolation rules"
  }
}
:local fb [/ip/firewall/address-list/find where list="fallback-lan"]
:if ([:len $fb] > 0) do={ /ip/firewall/address-list/set $fb address=192.168.0.0/24 }

# MUST come before the IoT drop. Five IoT devices hold long-lived MQTT sessions
# to mosquitto in k3s; without this, Home Assistant silently loses every sensor.
:if ([:len [/ip/firewall/filter/find where comment="iot: allow MQTT to broker"]] = 0) do={
  /ip/firewall/filter/add chain=forward action=accept in-interface=vlan20-iot \
    dst-address=10.0.40.0/24 protocol=tcp dst-port=1883 \
    comment="iot: allow MQTT to broker"
}
:if ([:len [/ip/firewall/filter/find where comment="isolate iot from other VLANs"]] = 0) do={
  /ip/firewall/filter/add chain=forward action=drop in-interface=vlan20-iot \
    dst-address-list=internal log=yes log-prefix=iot-drop \
    comment="isolate iot from other VLANs"
}
:if ([:len [/ip/firewall/filter/find where comment="isolate guest from other VLANs"]] = 0) do={
  /ip/firewall/filter/add chain=forward action=drop in-interface=vlan30-guest \
    dst-address-list=internal log=yes log-prefix=guest-drop \
    comment="isolate guest from other VLANs"
}

# --------------------------------------------------- input chain lockdown
# The input chain had no drop rule, so every VLAN — and, but for CGNAT, the
# internet — could reach SSH, Winbox, WebFig and the DNS resolver.
#
# The allow list below is not guesswork: a non-terminating log rule was left on
# the input chain first, and these are the flows it actually saw. Removing any
# of them breaks something real:
#   DHCP   - all VLANs, or clients get no lease
#   DNS    - lab, iot, vms and mgmt all resolve through the router
#   mDNS   - the repeater; without it nas.local stops working across VLANs
#   IGMP   - multicast group membership that mDNS relies on
#   5678   - MikroTik neighbour discovery, how /ip neighbor sees switch and AP
#
# Broadcast chatter that is NOT allowed and is safely dropped: udp/17500
# (Dropbox LAN sync), udp/1900 (SSDP), udp/6667. None are addressed to the
# router; they merely land on input because they are broadcasts.

:foreach n in={"192.168.0.0/24";"10.0.10.0/24"} do={
  :if ([:len [/ip/firewall/address-list/find where list="mgmt-allowed" and address=$n]] = 0) do={
    /ip/firewall/address-list/add list=mgmt-allowed address=$n \
      comment="may reach router management services"
  }
}

# comment / protocol / ports / src-address-list ("" = any source)
:local inrules {
  {"input: DHCP (all VLANs)";"udp";"67,68";""};
  {"input: DNS udp from LAN";"udp";"53";"internal"};
  {"input: DNS tcp from LAN";"tcp";"53";"internal"};
  {"input: mDNS repeater";"udp";"5353";""};
  {"input: MikroTik neighbour discovery";"udp";"5678";"internal"};
  {"input: management from mgmt+lab only";"tcp";"2200,8291,80,443";"mgmt-allowed"}
}
:foreach r in=$inrules do={
  :local c [:pick $r 0]; :local p [:pick $r 1]
  :local d [:pick $r 2]; :local sl [:pick $r 3]
  :if ([:len [/ip/firewall/filter/find where comment=$c]] = 0) do={
    :if ($sl = "") do={
      /ip/firewall/filter/add chain=input action=accept protocol=$p dst-port=$d comment=$c
    } else={
      /ip/firewall/filter/add chain=input action=accept protocol=$p dst-port=$d \
        src-address-list=$sl comment=$c
    }
  }
}
:if ([:len [/ip/firewall/filter/find where comment="input: IGMP for multicast"]] = 0) do={
  /ip/firewall/filter/add chain=input action=accept protocol=igmp \
    comment="input: IGMP for multicast"
}

# MUST be last in the input chain. Logged so anything unexpectedly blocked is
# visible rather than silent.
:if ([:len [/ip/firewall/filter/find where comment="input: drop everything else"]] = 0) do={
  /ip/firewall/filter/add chain=input action=drop log=yes log-prefix=inputdrop \
    comment="input: drop everything else"
}

# Defence in depth: the service restriction holds even if the rules above are
# reordered or disabled. Use the bare service name as the selector - [find
# name=...] matches the wrong item here and silently edits telnet.
/ip service set www     address=192.168.0.0/24,10.0.10.0/24
/ip service set www-ssl address=192.168.0.0/24,10.0.10.0/24
/ip service set ssh     address=192.168.0.0/24,10.0.10.0/24
/ip service set winbox  address=192.168.0.0/24,10.0.10.0/24

# ----------------------------------------------------------------- system
/system/clock/set time-zone-name=Europe/Prague
/ip/neighbor/discovery-settings/set discover-interface-list=LAN
/ipv6/settings/set disable-ipv6=yes

:log info "netcfg: router done"
:put "router: converged"
