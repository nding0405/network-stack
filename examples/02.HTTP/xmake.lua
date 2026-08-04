-- Copyright CHERIoT Contributors.
-- SPDX-License-Identifier: MIT

-- Update this to point to the location of the CHERIoT SDK
sdkdir = path.absolute("../../../cheriot-rtos/sdk")

set_project("CHERIoT HTTP Example")

includes(sdkdir)

set_toolchains("cheriot-clang")

includes(path.join(sdkdir, "lib"))

local networkComponents = {
  "MQTT",
  "TLS",
  "SNTP",
  "NetAPI",
  "DNS",
  "TCPIP",
  "Firewall"
}

local MONO = "mono"
local ISOLATE_MQTT = "mqtt"
local ISOLATE_TLS = "mqtt-tls"
local ISOLATE_SNTP = "mqtt-tls-sntp"
local ISOLATE_NETAPI = "mqtt-tls-sntp-netapi"
local ISOLATE_DNS = "mqtt-tls-sntp-netapi-dns"
local FULL = "full"

local compartmentConfigurations = {
  [MONO] = {},
  [ISOLATE_MQTT] = {"MQTT"},
  [ISOLATE_TLS] = {"MQTT", "TLS"},
  [ISOLATE_SNTP] = {"MQTT", "TLS", "SNTP"},
  [ISOLATE_NETAPI] = {"MQTT", "TLS", "SNTP", "NetAPI"},
  [ISOLATE_DNS] = {"MQTT", "TLS", "SNTP", "NetAPI", "DNS"},
  [FULL] = networkComponents
}

option("compartment")
  set_default(FULL)
  set_values(MONO, ISOLATE_MQTT, ISOLATE_TLS, ISOLATE_SNTP,
             ISOLATE_NETAPI, ISOLATE_DNS, FULL)
  set_description("Select the network compartment layout")
  set_showmenu(true)

local isolatedCompartments = {}
for _, name in ipairs(
  compartmentConfigurations[get_config("compartment") or FULL]) do
  isolatedCompartments[name] = true
end

local networkCompartments = {}
for _, name in ipairs(networkComponents) do
  networkCompartments[name] =
    isolatedCompartments[name] and name or "NetworkStack"
end

local function addNetworkDefines()
  for _, name in ipairs(networkComponents) do
    add_defines(("CHERIOT_NETWORK_COMPARTMENT_%s=%q"):format(
                  name:upper(), networkCompartments[name]))
  end
  add_defines("CHERIOT_NETWORK_COMPARTMENT_NETAPI_TOKEN=" ..
                networkCompartments.NetAPI)
end

local function addNetworkDeps(...)
  local dependencies = {}
  local seen = {}
  for _, name in ipairs({...}) do
    local dependency = networkCompartments[name] or name
    if not seen[dependency] then
      table.insert(dependencies, dependency)
      seen[dependency] = true
    end
  end
  add_deps(table.unpack(dependencies))
end

rule("cheriot.network-stack.component")
  add_deps("cheriot.compartment")
  on_load(function(target)
    local name = target:values("cheriot.network-stack.logical-name")
    local physicalCompartment = networkCompartments[name]
    local dependencies = {}
    local seen = {}
    for _, dependency in ipairs(table.wrap(target:get("deps"))) do
      local mappedDependency = networkCompartments[dependency] or dependency
      if mappedDependency ~= physicalCompartment and
         not seen[mappedDependency] then
        table.insert(dependencies, mappedDependency)
        seen[mappedDependency] = true
      end
    end
    target:set("deps", table.unpack(dependencies))
    if physicalCompartment ~= name then
      target:set("cheriot.compartment", physicalCompartment)
      target:set("cheriot.debug-name", name)
      target:set("cheriot.type", "object")
      target:set("kind", "object")
    end
  end)

includes("../../lib")

target("time_helpers")
  addNetworkDefines()

for _, name in ipairs(networkComponents) do
  target(name)
    addNetworkDefines()
    add_rules("cheriot.network-stack.component")
    set_values("cheriot.network-stack.logical-name", name)
end

local physicalCompartments = {}
local physicalCompartmentOrder = {}
for _, name in ipairs(networkComponents) do
  local physicalCompartment = networkCompartments[name]
  if not physicalCompartments[physicalCompartment] then
    physicalCompartments[physicalCompartment] = {}
    table.insert(physicalCompartmentOrder, physicalCompartment)
  end
  table.insert(physicalCompartments[physicalCompartment], name)
end
for _, name in ipairs(physicalCompartmentOrder) do
  local components = physicalCompartments[name]
  if #components > 1 or components[1] ~= name then
    compartment(name)
      set_default(false)
      add_deps(table.unpack(components))
      if table.contains(components, "TLS") then
        add_deps("time_helpers")
      end
      add_ldflags("--allow-multiple-definition", {force = true})
  end
end

option("board")
  set_default("ibex-arty-a7-100")

compartment("http_example")
  addNetworkDefines()
  add_includedirs("../../include")
  addNetworkDeps("freestanding", "TCPIP", "NetAPI")
  add_files("http.cc")
  add_rules("cheriot.network-stack.ipv6")

firmware("02.http_example")
  set_policy("build.warning", true)
  addNetworkDeps("DNS", "TCPIP", "Firewall", "NetAPI", "http_example", "atomic8", "debug")
  on_load(function(target)
    target:values_set("board", "$(board)")
    target:values_set("threads", {
      {
        compartment = "http_example",
        priority = 1,
        entry_point = "example",
        -- TLS requires *huge* stacks!
        stack_size = 0xe00,
        trusted_stack_frames = 6
      },
      {
        compartment = networkCompartments.TCPIP,
        priority = 1,
        entry_point = "ip_thread_entry",
        stack_size = 0xe00,
        trusted_stack_frames = 5
      },
      {
        compartment = networkCompartments.Firewall,
        -- Higher priority, this will be back-pressured by the message
        -- queue if the network stack can't keep up, but we want
        -- packets to arrive immediately.
        priority = 2,
        entry_point = "ethernet_run_driver",
        stack_size = 0x1000,
        trusted_stack_frames = 5
      }
    }, {expand = false})
  end)
