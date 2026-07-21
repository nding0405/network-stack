-- Copyright CHERIoT Contributors.
-- SPDX-License-Identifier: MIT

-- Update this to point to the location of the CHERIoT SDK
sdkdir = path.absolute("../../../cheriot-rtos/sdk")

set_project("CHERIoT Multiwaiter Server Example")

includes(sdkdir)

set_toolchains("cheriot-clang")

includes(path.join(sdkdir, "lib"))
includes("../../lib")

option("board")
  set_default("ibex-arty-a7-100")

compartment("multiwaiter_server_example")
  add_includedirs("../../include")
  add_deps("freestanding", "TCPIP", "NetAPI")
  add_files("multiwaiter_server.cc")
  add_rules("cheriot.network-stack.ipv6")

firmware("06.multiwaiter_server_example")
  set_policy("build.warning", true)
  add_deps("DNS", "TCPIP", "Firewall", "NetAPI", "multiwaiter_server_example", "atomic8", "debug", "thread_pool")
  on_load(function(target)
    target:values_set("board", "$(board)")
    target:values_set("threads", {
      {
        compartment = "multiwaiter_server_example",
        priority = 1,
        entry_point = "example",
        stack_size = 0xe00,
        trusted_stack_frames = 6
      },
      {
        compartment = "TCPIP",
        priority = 1,
        entry_point = "ip_thread_entry",
        stack_size = 0xe00,
        trusted_stack_frames = 5
      },
      {
        compartment = "Firewall",
        -- Higher priority, this will be back-pressured by the message
        -- queue if the network stack can't keep up, but we want
        -- packets to arrive immediately.
        priority = 2,
        entry_point = "ethernet_run_driver",
        stack_size = 0x1000,
        trusted_stack_frames = 5
      },
      {
        compartment = "thread_pool",
        entry_point = "thread_pool_run",
        priority = 1,
        stack_size = 0x1000,
        trusted_stack_frames = 8
      },
      {
        compartment = "thread_pool",
        entry_point = "thread_pool_run",
        priority = 1,
        stack_size = 0x1000,
        trusted_stack_frames = 8
      },
      {
        compartment = "thread_pool",
        entry_point = "thread_pool_run",
        priority = 1,
        stack_size = 0x1000,
        trusted_stack_frames = 8
      }
    }, {expand = false})
  end)
