# CRS310 — VLAN switching, L3 hardware offload
#
# Idempotent: find-then-add-or-update throughout.
# Apply:  /import file-name=switch-crs310.rsc
#
# Port roles and what is plugged into them are in README.md. ether8 is the
# uplink to the router; ether2 is the trunk to the AP.

:log info "netcfg: switch begin"

# ---------------------------------------------------------------- bridge
:local b [/interface/bridge/find where name="bridge"]
:if ([:len $b] = 0) do={
  /interface/bridge/add name=bridge comment=defconf vlan-filtering=yes auto-mac=no
} else={
  /interface/bridge/set $b vlan-filtering=yes
}

# ------------------------------------------------------- vlan interfaces
# Only the VLANs the switch itself needs an address on. vlan10 and vlan40 are
# here because the switch routes between them in hardware.
:local vlans { {"vlan1-mgmt";1}; {"vlan10-lab";10}; {"vlan40-vms";40} }
:foreach v in=$vlans do={
  :local n [:pick $v 0]; :local id [:pick $v 1]
  :local f [/interface/vlan/find where name=$n]
  :if ([:len $f] = 0) do={
    /interface/vlan/add name=$n vlan-id=$id interface=bridge
  } else={
    /interface/vlan/set $f vlan-id=$id interface=bridge
  }
}

# --------------------------------------------------------- bridge ports
# port / pvid (0 = leave at default 1) / comment
:local ports {
  {"ether1";10;"Stul"};
  {"ether2";0;"AP"};
  {"ether3";10;"overwatcher"};
  {"ether4";0;"pve"};
  {"ether5";10;""};
  {"ether6";10;"holly"};
  {"ether7";20;""};
  {"ether8";0;"router uplink"};
  {"sfp-sfpplus1";0;""};
  {"sfp-sfpplus2";0;""}
}
:foreach p in=$ports do={
  :local i [:pick $p 0]; :local pv [:pick $p 1]; :local c [:pick $p 2]
  :local f [/interface/bridge/port/find where interface=$i]
  :if ([:len $f] = 0) do={
    /interface/bridge/port/add bridge=bridge interface=$i comment=$c
    :set f [/interface/bridge/port/find where interface=$i]
  } else={
    /interface/bridge/port/set $f comment=$c
  }
  :if ($pv > 0) do={ /interface/bridge/port/set $f pvid=$pv }
}

# ------------------------------------------------- bridge vlan (tagging)
# id / tagged / untagged / comment
:local bvlans {
  {1;"bridge";"";""};
  {10;"ether2,ether4,ether6,ether7,ether8,bridge";"ether1,ether3,ether5";"Host"};
  {20;"ether2,ether4,ether6,ether8,bridge";"ether7";"IoT"};
  {30;"ether2,ether7,ether8,bridge";"";"Guest"};
  {40;"ether4,ether6,ether7,ether8,bridge";"";"VMs"}
}
:foreach v in=$bvlans do={
  :local id [:pick $v 0]; :local tg [:pick $v 1]
  :local ut [:pick $v 2]; :local c [:pick $v 3]
  :local f [/interface/bridge/vlan/find where bridge="bridge" and vlan-ids=$id and !dynamic]
  :if ([:len $f] = 0) do={
    /interface/bridge/vlan/add bridge=bridge vlan-ids=$id tagged=$tg untagged=$ut comment=$c
  } else={
    /interface/bridge/vlan/set $f tagged=$tg untagged=$ut comment=$c
  }
}

# ------------------------------------------------------------ addressing
# NOTE: the live device also carries a second 192.168.0.3 on the bridge as a
# /24 alongside the /16 on vlan1-mgmt. That is redundant; only the vlan1-mgmt
# address is reproduced here. Add the bridge one back if something depends on it.
:local addrs {
  {"192.168.0.3/16";"vlan1-mgmt";"mgmt"};
  {"10.0.10.2/24";"vlan10-lab";"hosts"};
  {"10.0.40.2/24";"vlan40-vms";"l3-routing"}
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

# ------------------------------------------------- L3 hardware offloading
# Routes vlan10 <-> vlan40 in switch silicon; that traffic never reaches the
# router. Requires an address on each of those VLANs, set above.
/interface/ethernet/switch/set [find] l3-hw-offloading=yes

# --------------------------------------------------------- dns and routing
/ip/dns/set servers=10.0.10.1,1.1.1.1
:if ([:len [/ip/route/find where dst-address="0.0.0.0/0" and gateway="10.0.10.1"]] = 0) do={
  /ip/route/add dst-address=0.0.0.0/0 gateway=10.0.10.1 comment=lan-gateway
}

/system/clock/set time-zone-name=Europe/Prague
/system/identity/set name=CRS310

:log info "netcfg: switch done"
:put "switch: converged"
