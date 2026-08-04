-- Copyright CHERIoT Contributors.
-- SPDX-License-Identifier: MIT

-- Update this to point to the location of the CHERIoT SDK
sdkdir = path.absolute("../../../cheriot-rtos/sdk")

set_project("CHERIoT SNTP Example")

includes(sdkdir)

set_toolchains("cheriot-clang")

includes(path.join(sdkdir, "lib"))

-- define a table of all compartment names
local networkComponents = {
  "MQTT",
  "TLS",
  "SNTP",
  "NetAPI",
  "DNS",
  "TCPIP",
  "Firewall"
}

-- define each configuration
local MONO = "mono"
local ISOLATE_MQTT = "mqtt"
local ISOLATE_TLS = "mqtt-tls"
local ISOLATE_SNTP = "mqtt-tls-sntp"
local ISOLATE_NETAPI = "mqtt-tls-sntp-netapi"
local ISOLATE_DNS = "mqtt-tls-sntp-netapi-dns"
local FULL = "full"

-- define a dictionary, The square brackets mean:
-- evaluate this variable and use its value as the table key.
local compartmentConfigurations = {
  [MONO] = {},
  [ISOLATE_MQTT] = {"MQTT"},
  [ISOLATE_TLS] = {"MQTT", "TLS"},
  [ISOLATE_SNTP] = {"MQTT", "TLS", "SNTP"},
  [ISOLATE_NETAPI] = {"MQTT", "TLS", "SNTP", "NetAPI"},
  [ISOLATE_DNS] = {"MQTT", "TLS", "SNTP", "NetAPI", "DNS"},
  [FULL] = networkComponents
}
-- define a configurable option named `compartment`
option("compartment")
  set_default(FULL)
  set_values(MONO, ISOLATE_MQTT, ISOLATE_TLS, ISOLATE_SNTP,
             ISOLATE_NETAPI, ISOLATE_DNS, FULL)
  set_description("Select the network compartment layout")
  set_showmenu(true)

  -- define the isolated compartment table.
  -- for each name appears in the config, set
  -- the table slot to true. It basically isolates
  -- and records the name of the compartments specified
  -- by the config.
local isolatedCompartments = {}
for _, name in ipairs(
  compartmentConfigurations[get_config("compartment") or FULL]) do
  isolatedCompartments[name] = true
end

-- if the comparment is isolated, return it's own name,
-- otherwise, name the compartment as "NetworkStack"
local networkCompartments = {}
for _, name in ipairs(networkComponents) do
  networkCompartments[name] =
    isolatedCompartments[name] and name or "NetworkStack"
end

-- name all .cc macros with actual name.
-- %q: add quotation marks.
-- networkCompartments.NetAPI: does not have quotation marks.
local function addNetworkDefines()
  for _, name in ipairs(networkComponents) do
    add_defines(("CHERIOT_NETWORK_COMPARTMENT_%s=%q"):format(
                  name:upper(), networkCompartments[name]))
  end
  add_defines("CHERIOT_NETWORK_COMPARTMENT_NETAPI_TOKEN=" ..
                networkCompartments.NetAPI)
end

-- Add dependencies using the selected compartment configuration.
-- Replace merged network components with NetworkStack, remove duplicates,
-- e.g. NetworkStack, NetworkStack, NetworkStack, NetworkStack, SNTP
-- becomes: NetworkStack, SNTP
-- and leave non-network dependencies unchanged.
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

-- Creates a xmake rule named cheriot.network-stack.component
-- If logical name == physical name, keep the component as a isolated compartment.
-- If they differ, stop producing isolated compartment and compile the component
-- as object files assigned to the selected physical compartment.
rule("cheriot.network-stack.component")
  -- rule dependency, not firmware dependency
  add_deps("cheriot.compartment")
  -- Xmake calls this function for every network target using the rule.
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
    addNetworkDefines() -- gives it the selected compartment macros.
    add_rules("cheriot.network-stack.component") -- attaches the layout-conversion rule
    set_values("cheriot.network-stack.logical-name", name) -- records its original logical name for that rule.
end

-- Assign each physical compartments, the logical components
local physicalCompartments = {}
local physicalCompartmentOrder = {}
for _, name in ipairs(networkComponents) do
  local physicalCompartment = networkCompartments[name]
  if not physicalCompartments[physicalCompartment] then
    physicalCompartments[physicalCompartment] = {} -- if it is the first here, create an empty list
    table.insert(physicalCompartmentOrder, physicalCompartment)
  end
  table.insert(physicalCompartments[physicalCompartment], name)
end
for _, name in ipairs(physicalCompartmentOrder) do
  local components = physicalCompartments[name]
  -- multiple components must be combined OR there is only 1 component under a physical
  -- compartment, but the name doesn't match.
  if #components > 1 or components[1] ~= name then
    compartment(name) -- define a combined compartment
      set_default(false)
      add_deps(table.unpack(components)) -- adds all grouped objects to the compartment.
      -- If TLS is merged into this compartment,
      -- its time-support library must also be linked there.
      if table.contains(components, "TLS") then
        add_deps("time_helpers")
      end
      add_ldflags("--allow-multiple-definition", {force = true})
  end
end

option("board")
  set_default("ibex-arty-a7-100")

compartment("sntp_example")
  addNetworkDefines()
  add_includedirs("../../include")
  addNetworkDeps("freestanding", "SNTP")
  add_files("sntp.cc")
  add_rules("cheriot.network-stack.ipv6")

firmware("01.sntp_example")
  set_policy("build.warning", true)
  addNetworkDeps("DNS", "TCPIP", "Firewall", "NetAPI", "SNTP", "sntp_example", "atomic8", "time_helpers", "debug")
  -- stdio only needed for debug prints in SNTP, can be removed with --debug-sntp=n
  add_deps("stdio")
  on_load(function(target)
    target:values_set("board", "$(board)")
    target:values_set("threads", {
      {
        compartment = "sntp_example",
        priority = 1,
        entry_point = "example",
        stack_size = 0xe00,
        trusted_stack_frames = 6
      },
      {
        -- TCP/IP stack thread.
        compartment = networkCompartments.TCPIP,
        priority = 1,
        entry_point = "ip_thread_entry",
        stack_size = 0xe00,
        trusted_stack_frames = 5
      },
      {
        -- Firewall thread, handles incoming packets as they arrive.
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
