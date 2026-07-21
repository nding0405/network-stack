#include "timeout.h"
#include <NetAPI.h>
#if __has_include(<allocator.h>)
#	include <allocator.h>
#endif
#include <atomic>
#include <debug.hh>
#include <fail-simulator-on-error.h>
#include <multiwaiter.h>
#include <thread.h>
#include <thread_pool.h>
#include <tick_macros.h>

using CHERI::Capability;

using Debug            = ConditionalDebug<true, "Multiwaiter server example">;
constexpr bool UseIPv6 = false;

/**
 * Bind capabilities for the three server ports. Use IPv6 if enabled in the
 * configuration, and allow at most 10 simultaneous connections per port.
 * (although the firewall will limit this to 2 per port in this example).
 */
DECLARE_AND_DEFINE_BIND_CAPABILITY(ListenPort80, UseIPv6, 80, 10);
DECLARE_AND_DEFINE_BIND_CAPABILITY(ListenPort8080, UseIPv6, 8080, 10);
DECLARE_AND_DEFINE_BIND_CAPABILITY(ListenPort22, UseIPv6, 22, 10);

DECLARE_AND_DEFINE_ALLOCATOR_CAPABILITY(TestMalloc, 32 * 1024);
#define TEST_MALLOC STATIC_SEALED_VALUE(TestMalloc)

/**
 * Two workers each accept one client from every listener.  This gives two
 * clients per listening socket and six accepted connections in total.
 */
static constexpr size_t   NumListeners        = 3;
static constexpr size_t   NumWorkers          = 2;
static constexpr uint16_t Ports[NumListeners] = {80, 8080, 22};

static Socket                ListeningSockets[NumListeners]          = {};
static Socket                ClientSockets[NumWorkers][NumListeners] = {};
static uint32_t             *AcceptEventSources[NumListeners]        = {};
static std::atomic<uint32_t> AcceptedPerListener[NumListeners]       = {};
static std::atomic<uint32_t> NextWorker{0};
static std::atomic<uint32_t> WorkersFinished{0};
static std::atomic<uint32_t> WorkerFailures{0};

/**
 * Retries close operations so that a transient network-stack
 * restart does not prevent cleanup.
 */
static constexpr uint16_t RestartDelay = 100; // in ticks

/**
 * Close a socket, retrying if the network stack is temporarily unavailable.
 */
static bool close_socket(Socket socket, const char *kind, uint16_t port)
{
	if (!Capability{socket}.is_valid())
	{
		return true;
	}

	for (int retries = 10; retries > 0; retries--)
	{
		Timeout timeout{UnlimitedTimeout};
		if (network_socket_close(&timeout, TEST_MALLOC, socket) == 0)
		{
			return true;
		}

		Timeout sleep{RestartDelay};
		thread_sleep(&sleep);
	}

	Debug::log("Failed to close {} socket for port {}.", kind, port);
	return false;
}

/**
 * Each worker owns one accepted-client slot per listener.  Every worker has
 * its own multiwaiter and waits on all listeners that the current worker has
 * not yet accepted a client from. This function accepts one client per listening
 * socket.
 *
 */

// General workflow:
// |A|  while (1)
// |B|  {
// |C|	 ForEachSocket:
// |D|		call accept() if futex is non-zero;
// |E|		mark as finished if succeed;
// |F|   Create EventSource with expected = 0;
// |G|   multiwaiter_wait();
// |H|  }

// connections arrives at any point...
// A -> C: will be seen by accept() -> no miss
// D -> G: will be intercepted by multiwaiter_wait::set()
// G: arrives between set() and sleep() -> not possible,
//    that is guaranteed by the scheduler
// G -> D: will be seen by accept() -> no miss
static void accept_one_client_per_listener()
{
	uint32_t worker = NextWorker.fetch_add(1);
	if (worker >= NumWorkers)
	{
		Debug::log("Unexpected extra multiwaiter worker {}.", worker);
		WorkerFailures.fetch_add(1);
		WorkersFinished.fetch_add(1);
		return;
	}

	Timeout     unlimited{UnlimitedTimeout};
	MultiWaiter multiwaiter = nullptr;
	if (multiwaiter_create(
	      &unlimited, TEST_MALLOC, &multiwaiter, NumListeners) != 0)
	{
		Debug::log("Worker {} failed to create a multiwaiter.", worker);
		WorkerFailures.fetch_add(1);
		WorkersFinished.fetch_add(1);
		return;
	}

	bool   accepted[NumListeners] = {};
	size_t remaining              = NumListeners;
	bool   failed                 = false;

	while (remaining > 0)
	{
		// Try each listener before sleeping so that already-pending clients are
		// consumed immediately.
		for (size_t i = 0; i < NumListeners; i++)
		{
			if (accepted[i])
			{
				continue;
			}
			if (__atomic_load_n(AcceptEventSources[i], __ATOMIC_ACQUIRE) == 0)
			{
				continue;
			}

			NetworkAddress clientAddress = {0};
			uint16_t       clientPort    = 0;
			Timeout        acceptTimeout{0}; // non-blocking accept.
			Socket clientSocket = network_socket_accept_tcp(&acceptTimeout,
			                                                TEST_MALLOC,
			                                                ListeningSockets[i],
			                                                &clientAddress,
			                                                &clientPort);
			if (!Capability{clientSocket}.is_valid())
			{
				continue;
			}

			ClientSockets[worker][i] = clientSocket;
			accepted[i]              = true;
			remaining--;
			uint32_t count = AcceptedPerListener[i].fetch_add(1) + 1;
			Debug::log("Worker {} accepted client {} of {} on port {} "
			           "(remote port {}).",
			           worker,
			           count,
			           NumWorkers,
			           Ports[i],
			           clientPort);
		}

		if (remaining == 0)
		{
			break;
		}

		// Wait for a pending connection on any listener still needed by this
		// worker.  A value other than zero signals pending accept work.
		EventWaiterSource events[NumListeners];
		size_t            eventCount = 0;
		for (size_t i = 0; i < NumListeners; i++)
		{
			if (!accepted[i])
			{
				events[eventCount] = {AcceptEventSources[i], 0};
				eventCount++;
			}
		}

		Debug::log("Worker {} waiting on {} listeners.", worker, eventCount);
		Timeout waitTimeout{UnlimitedTimeout};
		if (multiwaiter_wait(&waitTimeout, multiwaiter, events, eventCount) !=
		    0)
		{
			Debug::log("Worker {}: multiwaiter_wait failed.", worker);
			failed = true;
			break;
		}
	}

	if (multiwaiter_delete(TEST_MALLOC, multiwaiter) != 0)
	{
		Debug::log("Worker {} failed to delete its multiwaiter.", worker);
		failed = true;
	}

	if (failed || (remaining != 0))
	{
		WorkerFailures.fetch_add(1);
	}
	else
	{
		Debug::log("Worker {} accepted one client on every listener.", worker);
	}
	WorkersFinished.fetch_add(1);
}

void __cheri_compartment("multiwaiter_server_example") example()
{
	network_start();
	auto heapAtStart = heap_quota_remaining(TEST_MALLOC);

	BindCapability bindCapabilities[NumListeners] = {
	  STATIC_SEALED_VALUE(ListenPort80),
	  STATIC_SEALED_VALUE(ListenPort8080),
	  STATIC_SEALED_VALUE(ListenPort22),
	};

	NextWorker.store(0);
	WorkersFinished.store(0);
	WorkerFailures.store(0);
	for (size_t i = 0; i < NumListeners; i++)
	{
		ListeningSockets[i]   = nullptr;
		AcceptEventSources[i] = nullptr;
		AcceptedPerListener[i].store(0);
		for (size_t worker = 0; worker < NumWorkers; worker++)
		{
			ClientSockets[worker][i] = nullptr;
		}
	}

	Debug::log("Starting {}-listener, {}-worker server.",
	           NumListeners,
	           NumWorkers);
	size_t listenersCreated = 0;
	for (size_t i = 0; i < NumListeners; i++)
	{
		Debug::log("Creating a listening socket for port {}.", Ports[i]);
		Timeout timeout{UnlimitedTimeout};
		ListeningSockets[i] =
		  network_socket_listen_tcp(&timeout, TEST_MALLOC, bindCapabilities[i]);
		if (!Capability{ListeningSockets[i]}.is_valid())
		{
			Debug::log("Failed to create listener for port {}.", Ports[i]);
			break;
		}
		listenersCreated++;

		AcceptEventSources[i] = network_socket_get_event_source(
		  ListeningSockets[i], SocketEventType::SocketAcceptEvent);
		if (!Capability{AcceptEventSources[i]}.is_valid())
		{
			Debug::log("Failed to get event source for port {}.", Ports[i]);
			break;
		}
	}

	uint32_t workersScheduled = 0;
	if (listenersCreated == NumListeners)
	{
		for (size_t i = 0; i < NumWorkers; i++)
		{
			int result =
			  thread_pool::async([]() { accept_one_client_per_listener(); });
			if (result != 0)
			{
				Debug::log("Failed to schedule worker {}: {}.", i, result);
				WorkerFailures.fetch_add(1);
				break;
			}
			workersScheduled++;
		}
	}

	while (WorkersFinished.load() < workersScheduled)
	{
		Timeout wait{1};
		thread_sleep(&wait);
	}

	bool receivedAllClients =
	  (workersScheduled == NumWorkers) && (WorkerFailures.load() == 0);
	for (size_t i = 0; i < NumListeners; i++)
	{
		uint32_t accepted = AcceptedPerListener[i].load();
		Debug::log("Port {} accepted {} of {} expected clients.",
		           Ports[i],
		           accepted,
		           NumWorkers);
		receivedAllClients &= (accepted == NumWorkers);
	}

	if (receivedAllClients)
	{
		Debug::log("All {} listeners received {} clients; closing sockets.",
		           NumListeners,
		           NumWorkers);
	}
	else
	{
		Debug::log("The server stopped before all expected clients arrived.");
	}

	// Workers no longer access these sockets after WorkersFinished is updated,
	// so the controller can now close all six clients and all three listeners.
	for (size_t worker = 0; worker < NumWorkers; worker++)
	{
		for (size_t i = 0; i < NumListeners; i++)
		{
			if (Capability{ClientSockets[worker][i]}.is_valid())
			{
				Debug::log(
				  "Closing worker {} client for port {}.", worker, Ports[i]);
				close_socket(ClientSockets[worker][i], "client", Ports[i]);
			}
		}
	}

	for (size_t i = 0; i < listenersCreated; i++)
	{
		Debug::log("Closing listening socket for port {}.", Ports[i]);
		close_socket(ListeningSockets[i], "listening", Ports[i]);
	}

	Debug::log("Checking for leaks.");
	auto heapAtEnd = heap_quota_remaining(TEST_MALLOC);
	if (heapAtEnd < heapAtStart)
	{
		Debug::log("Warning: The implementation leaked {} bytes (start: {} vs. "
		           "end: {}).",
		           heapAtStart - heapAtEnd,
		           heapAtStart,
		           heapAtEnd);
	}
	else
	{
		Debug::log(
		  "No leaks detected (start: {} vs. end: {}).", heapAtStart, heapAtEnd);
	}

	Debug::log("Terminating the server.");
}
