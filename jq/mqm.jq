module { "name": "mqm" };
##
# jq module containing a generator for mqmgateway configurations
##

import "dimplex" as dimplex { search: "./" };
import "mqtt" as mqtt { search: "./" };
import "nums" as nums { search: "./" };

def hexChr:
  floor | if . < 10 then . else ["A", "B", "C", "D", "E", "F"][. % 10] end
;

def toHex:
  def toHex:
      if . / 16 >= 1 then 
          (. / 16 | toHex), (. % 16 | hexChr)
      else
          . % 16 | hexChr
      end
  ;
  [toHex] | join("")
;

##
# Calculates the effective Modbus address of a register.
#
# Input:  A register definition
# Environment variables:
#   MQM_ADDRESS_OFFSET:
#         Address offset (integer)
# Output: Effective Modbus address of the register
##
def address:
  if .address | tostring | startswith( "0x" ) then
    ( "0x" + ( ( ( .address[2:] | nums::from_base( 16 ) ) + ($ENV.MQM_ADDRESS_OFFSET // 0 | tonumber) ) | toHex ) )
  else
    ( .address + ($ENV.MQM_ADDRESS_OFFSET // 0 | tonumber) )
  end
;

##
# Map input enum definitions to mqmgateway map converter definitions
#
# Input:    A list of enum definitions
# $version: A version string, e.g. "M3.13", "M3", "M"
# Output:   An object containing a `.register_type` map.
#             Each entry contains a mapping from register name
#             to enum values in mqmgateway map converter syntax
#
# Example:
#  { 
#    "Holding": { 
#      "Betriebsmodus": "0:\"Sommer\",1:\"Winter\"",
#      "Auswahl Heizkreis": "2:\"2.Heizkreis\",3:\"3.Heizkreis\""
#    },
#    "Coil": {
#      "Zustand Stellventil": "0:\"geschlossen\",1:\"geöffnet\""
#    }
#  }
##
def enums($version):
  . // []
  | dimplex::enums($version)
  | group_by([.register_type, .name])
  | reduce .[] as $item ({}; . * { ($item[0] | .register_type): {
      ($item[0] | (.name)):
      ($item | map("\(.value):\(dimplex::enumvalue | tojson)") | join(","))
    }
  })
;

def mqmdatamap($type):
  if $type[0:3] == "str" then
    { "size": ( ( $type[3:] | tonumber ) / 2 ), "std": "std.string", "expr": null }
  else
    {
      "int8":     { "size": 1, "first": false, "swap": false, "std": "std.int8()",                                 "expr": "int16(R0)" },
      "int8f":    { "size": 1, "first": false, "swap": false, "std": "std.int8(first=true)",                       "expr": "int16(R0)" },
      "uint8":    { "size": 1, "first": false, "swap": false, "std": "std.uint8()",                                "expr": "R0" },
      "uint8f":   { "size": 1, "first": false, "swap": false, "std": "std.uint8(first=true)",                      "expr": "R0" },

      "int16":    { "size": 1, "first": false, "swap": false, "std": "std.int16()",                                "expr": "int16(R0)" },
      "uint16":   { "size": 1, "first": false, "swap": false, "std": null,                                         "expr": "R0" },

      "int32":    { "size": 2, "first": false, "swap": false, "std": "std.int32()",                                "expr": "int32(R0,R1)" },
      "int32l":   { "size": 2, "first": true,  "swap": false, "std": "std.int32(low_first=true)",                  "expr": "int32(R1,R0)" },
      "int32s":   { "size": 2, "first": false, "swap": true,  "std": "std.int32(swap_bytes=true)",                 "expr": "int32bs(R0,R1)" },
      "int32ls":  { "size": 2, "first": true,  "swap": true,  "std": "std.int32(low_first=true,swap_bytes=true)",  "expr": "int32bs(R1,R0)" },

      "uint32":   { "size": 2, "first": false, "swap": false, "std": "std.uint32()",                               "expr": "uint32(R0,R1)" },
      "uint32l":  { "size": 2, "first": true,  "swap": false, "std": "std.uint32(low_first=true)",                 "expr": "uint32(R1,R0)" },
      "uint32s":  { "size": 2, "first": false, "swap": true,  "std": "std.uint32(swap_bytes=true)",                "expr": "uint32bs(R0,R1)" },
      "uint32ls": { "size": 2, "first": true,  "swap": true,  "std": "std.uint32(low_first=true,swap_bytes=true)", "expr": "uint32bs(R1,R0)" },

    }[$type] // { "size": 1, "first": false, "swap": false, "std": null, "expr": "R0" }
  end
;

##
# Map a register definition to an mqmgateway converter
#
# Input:      A register definition
# $direction: One of: [ "from-modbus", "to-modbus" ]
# $enums:     An object containing mqmgateway map converter definitions
# Output:     An object containing a mqmgateway converter,
#              or `null` if the register does not require a converter
#
# Examples:
#   Input:      { ..., "conversion": 0.1 }
#   $direction: "from-modbus",
#   => Output:  { "converter": "std.multiply(0.1)" }
#
#   Input:      { ..., "name": "Betriebsmodus", "conversion": "enum" }
#   $enums:    { "Holding": { "Betriebsmodus": "0:\"Sommer\",1:\"Winter\"" } },
#   => Output:  { "converter": "std.map('0:\"Sommer\",1:\"Winter\"')" }
##
def mqmconverter($direction; $enums):
  .name as $name
  | dimplex::enum($enums) as $enum
  | mqmdatamap(.data_type) as $datamap
  | (if $enum != null then $enum | "std.map(\(@sh))"
    elif .scale | type == "number" then
      ( ( .scale|tostring|length ) - ( .scale|tostring|index(".") ) - 1 ) as $precision
      | {
        "from-modbus": "expr.evaluate(\"\($datamap.expr) * \(.scale)\",precision=\($precision))",
        "to-modbus": "std.divide(\(.scale),precision=\($precision),low_first=\($datamap.first),swap_bytes=\($datamap.swap))"
      }[$direction]
      | select(. != null)
    elif $datamap.std then $datamap.std
    else empty
    end | { "converter": . }) // null
;

def mqmcount($data_type; $enums):
  mqmdatamap($data_type) as $datamap
  | (
    if $datamap.size > 1 then { "count": $datamap.size }
    else null
    end
  )
;

##
# Map register definitions to mqmgateway object definitions
#
# Input:     A list of register definitions
# $version:  A (target) version string, e.g. "M3.13", "M3", "M"
# $enumlist: A list of enum definitions
# Environment variables:
#   MQM_NETWORK:
#            mqmgateway name of the Modbus network the registers belong to
#            Optional. Default: "network"
#   MQM_SLAVE_ADDRESS:
#            Modbus slave address the registers belong to
#            Optional. Default: 1
# Output:    An object containing mqmgateway object definitions
#
# Example:
#  {
#    "objects": [
#      {
#        "topic": "mqmgateway/einstellungen-1-heiz-kuehlkreis/heating/hk1/raumtemperatur",
#        "state": {
#            "register": "network.1.47"
#            "name": "state"
#            "converter": "expr.evaluate(\"R0 * 0.1\", 1)"
#        },
#        "command": {
#            "register": "network.1.47"
#            "register_type": "holding"
#            "name": "set"
#            "converter": "std.divide(0.1)"
#        }
#      },
#      {
#        "topic": "mqmgateway/systemstatus/statusmeldungen",
#        "state": {
#          "register": "net.1.104"
#          "name": "state"
#          "converter": "std.map('0:\"Kein Status\",1:\"Aus\",2:\"Heizen\",3:\"Schwimmbad\",4:\"Warmwasser\",5:\"Kühlen\",10:\"Abtauen\",11:\"Durchflussüberwachung\",24:\"Verzögerung Betriebsmodusumschaltung\",30:\"Sperre\"')"
#      }
#    ]
#  }
#
##
def mqttobjects($version; $enumlist):
  .
  | ($ENV.MQM_NETWORK // "network")
    as $network
  | ($ENV.MQM_SLAVE_ADDRESS // 1)
    as $slave_address
  | ($enumlist | enums($version))
    as $enums
  | dimplex::registers($version)
  | [
    .[]
    | (.access | ascii_downcase)
      as $access
    | ([ $network, $slave_address, address ] | join("."))
      as $register
    | (.type | ascii_downcase)
      as $register_type
    | ({ register: $register, name: mqtt::state }
      + if $register_type == "holding" then null
        else { register_type: $register_type } end
      + mqmconverter("from-modbus"; $enums)
      + mqmcount(.data_type; $enums))
      as $state
    | ({ register: $register, register_type: $register_type, name: mqtt::command }
      + mqmconverter("to-modbus"; $enums))
      as $command

    | { topic: mqtt::topic }
    + mqtt::wrap( if .refresh and .refresh != "" then .refresh else null end; "refresh" )
    + if $access | contains("r") then { state: $state } else {} end
    + if $access | contains("w") then { commands: $command } else {} end
  ] | { mqtt: { objects: . } }
;

def config($version; $enumlist; $device):
  mqttobjects($version; $enumlist)
;
