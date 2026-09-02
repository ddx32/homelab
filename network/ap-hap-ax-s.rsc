# hAP ax S — Wi-Fi access point
#
# Idempotent: find-then-add-or-update throughout.
# Apply:  /import file-name=ap-hap-ax-s.rsc
#
# Pure L2 AP: it holds no client addresses and does no routing. Each SSID is
# pinned to a VLAN by a wifi datapath, and ether1 trunks those VLANs to the
# switch. Wi-Fi passphrases are NOT in version control - see the end of this file.

:log info "netcfg: ap begin"

# ---------------------------------------------------------------- bridge
:local b [/interface/bridge/find where name="bridge"]
:if ([:len $b] = 0) do={
  /interface/bridge/add name=bridge comment=defconf vlan-filtering=yes auto-mac=no
} else={
  /interface/bridge/set $b vlan-filtering=yes
}

:local vm [/interface/vlan/find where name="vlan1-mgmt"]
:if ([:len $vm] = 0) do={
  /interface/vlan/add name=vlan1-mgmt vlan-id=1 interface=bridge
} else={
  /interface/vlan/set $vm vlan-id=1 interface=bridge
}

# -------------------------------------------------------- wifi datapaths
# This is what puts each SSID on its VLAN.
:local dps { {"dp-vlan10";10}; {"dp-vlan20";20}; {"dp-vlan30";30} }
:foreach d in=$dps do={
  :local n [:pick $d 0]; :local id [:pick $d 1]
  :local f [/interface/wifi/datapath/find where name=$n]
  :if ([:len $f] = 0) do={
    /interface/wifi/datapath/add name=$n bridge=bridge vlan-id=$id
  } else={
    /interface/wifi/datapath/set $f bridge=bridge vlan-id=$id
  }
}

# --------------------------------------------------------- wifi security
# sec-iot is WPA2-only on purpose: several IoT devices cannot associate with WPA3.
:local secs {
  {"sec-main";"wpa2-psk,wpa3-psk";"yes"};
  {"sec-iot";"wpa2-psk";"no"};
  {"sec-guest";"wpa2-psk,wpa3-psk";"no"}
}
:foreach s in=$secs do={
  :local n [:pick $s 0]; :local at [:pick $s 1]; :local ft [:pick $s 2]
  :local f [/interface/wifi/security/find where name=$n]
  :if ([:len $f] = 0) do={
    /interface/wifi/security/add name=$n authentication-types=$at disabled=no
    :set f [/interface/wifi/security/find where name=$n]
  } else={
    /interface/wifi/security/set $f authentication-types=$at disabled=no
  }
  # 802.11r fast transition, for roaming on the main SSID
  :if ($ft = "yes") do={ /interface/wifi/security/set $f ft=yes ft-over-ds=yes }
}

# ------------------------------------------------------- radios (masters)
# One SSID across both bands so clients roam between them.
:local w1 [/interface/wifi/find where default-name="wifi1"]
:if ([:len $w1] > 0) do={
  /interface/wifi/set $w1 configuration.mode=ap configuration.ssid="Jehli-Fi" \
    security=sec-main datapath=dp-vlan10 disabled=no \
    channel.band=2ghz-ax channel.width=20/40mhz channel.skip-dfs-channels=10min-cac
}
:local w2 [/interface/wifi/find where default-name="wifi2"]
:if ([:len $w2] > 0) do={
  /interface/wifi/set $w2 configuration.mode=ap configuration.ssid="Jehli-Fi" \
    security=sec-main datapath=dp-vlan10 disabled=no \
    channel.band=5ghz-ax channel.width=20/40/80mhz \
    channel.frequency=5500,5520,5540,5560 channel.skip-dfs-channels=10min-cac
}

# ------------------------------------------------------- virtual SSIDs
# name / ssid / security / datapath / master
:local vaps {
  {"wifi-iot";"jehlifi_iot";"sec-iot";"dp-vlan20";"wifi1"};
  {"wifi-guest-2g";"Jehli-Fi Guest";"sec-guest";"dp-vlan30";"wifi1"};
  {"wifi-guest-5g";"Jehli-Fi Guest";"sec-guest";"dp-vlan30";"wifi2"}
}
:foreach v in=$vaps do={
  :local n [:pick $v 0]; :local ss [:pick $v 1]; :local sc [:pick $v 2]
  :local dp [:pick $v 3]; :local ms [:pick $v 4]
  :local f [/interface/wifi/find where name=$n]
  :if ([:len $f] = 0) do={
    /interface/wifi/add name=$n master-interface=$ms configuration.mode=ap \
      configuration.ssid=$ss security=$sc datapath=$dp disabled=no
  } else={
    /interface/wifi/set $f master-interface=$ms configuration.mode=ap \
      configuration.ssid=$ss security=$sc datapath=$dp disabled=no
  }
}

# --------------------------------------------------------- bridge ports
# ether1 is the trunk to the switch. The rest admit untagged only, so a stray
# cable cannot inject tagged frames into a VLAN.
:local up [/interface/bridge/port/find where interface="ether1"]
:if ([:len $up] = 0) do={
  /interface/bridge/port/add bridge=bridge interface=ether1 comment="trunk to switch"
} else={
  /interface/bridge/port/set $up comment="trunk to switch"
}
:foreach p in={"ether2";"ether3";"ether4";"ether5";"sfp1"} do={
  :local f [/interface/bridge/port/find where interface=$p]
  :if ([:len $f] = 0) do={
    /interface/bridge/port/add bridge=bridge interface=$p \
      frame-types=admit-only-untagged-and-priority-tagged
  } else={
    /interface/bridge/port/set $f frame-types=admit-only-untagged-and-priority-tagged
  }
}

# ------------------------------------------------- bridge vlan (tagging)
# id / tagged / untagged
:local bvlans {
  {1;"bridge";"ether1,ether2,ether3,ether4,ether5,sfp1"};
  {10;"ether1,wifi1,wifi2";""};
  {20;"ether1,wifi-iot";""};
  {30;"ether1,wifi-guest-2g,wifi-guest-5g";""}
}
:foreach v in=$bvlans do={
  :local id [:pick $v 0]; :local tg [:pick $v 1]; :local ut [:pick $v 2]
  :local f [/interface/bridge/vlan/find where bridge="bridge" and vlan-ids=$id and !dynamic]
  :if ([:len $f] = 0) do={
    /interface/bridge/vlan/add bridge=bridge vlan-ids=$id tagged=$tg untagged=$ut
  } else={
    /interface/bridge/vlan/set $f tagged=$tg untagged=$ut
  }
}

# --------------------------------------------------- management addressing
:local a [/ip/address/find where interface="vlan1-mgmt" and !dynamic]
:if ([:len $a] = 0) do={
  /ip/address/add address=192.168.0.4/24 interface=vlan1-mgmt comment=mgmt
} else={
  /ip/address/set $a address=192.168.0.4/24 comment=mgmt
}
/ip/dns/set servers=192.168.0.1
:if ([:len [/ip/route/find where dst-address="0.0.0.0/0" and gateway="192.168.0.1"]] = 0) do={
  /ip/route/add dst-address=0.0.0.0/0 gateway=192.168.0.1
}

/system/clock/set time-zone-name=Europe/Prague
/system/identity/set name=hAP-ax-S
/ipv6/settings/set disable-ipv6=yes

# ------------------------------------------------------------ passphrases
# Deliberately not in version control. Set once per security profile:
#   /interface/wifi/security/set [find name=sec-main]  passphrase="..."
#   /interface/wifi/security/set [find name=sec-iot]   passphrase="..."
#   /interface/wifi/security/set [find name=sec-guest] passphrase="..."
:foreach s in={"sec-main";"sec-iot";"sec-guest"} do={
  :local f [/interface/wifi/security/find where name=$s]
  :if ([:len $f] > 0) do={
    :if ([/interface/wifi/security/get $f passphrase] = "") do={
      :log warning ("netcfg: wifi security '" . $s . "' has no passphrase set")
      :put ("WARNING: set passphrase for " . $s)
    }
  }
}

:log info "netcfg: ap done"
:put "ap: converged"
