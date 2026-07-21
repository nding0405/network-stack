Multiwaiter TCP Server Example
==============================

This example opens three TCP listeners on ports 80, 8080, and 22 and starts
two worker threads. Every worker uses its own multiwaiter to wait on all
three listeners and accepts one client from each listener.

Connect two clients to each port, in any order. After all six connections
have been accepted, the controller closes the accepted sockets and listening
sockets and checks the allocator quota for leaks.
