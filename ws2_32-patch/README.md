# ws2_32-patch

`winecx-own-hostname.patch` changes `getaddrinfo()` in `dlls/ws2_32/protocol.c` (the PE half).
On macOS the host's resolver answers this machine's own name (`gethostname()`, e.g.
`<name>.local`) with lo0's addresses first (`::1`, `fe80::1`, `127.0.0.1`, `127.0.2.x`) and the
real ones after them. Windows never returns loopback for its own name, and programs take the
first result as their local address: TEKKEN 8's online SDK then hangs in ranked matchmaking.

When the queried name is the local host name (as `gethostname()` or the DNS FQDN returns it,
case-insensitive, with or without `.local`, or its first label; `""` too, which Wine already
maps to the FQDN), the patch drops loopback (`127.0.0.0/8`, `::1`, `::ffff:127.x`) and IPv6
link-local (`fe80::/10`) results while a routable one remains, else only loopback while any
other remains, else changes nothing. Order is kept. `localhost`, other names, numeric hosts
and `NULL` are untouched. `GetAddrInfoW`, `GetAddrInfoExW` and their async forms go through
the same `getaddrinfo()`. `gethostbyname()` of the own name already answers from the routing
table (`get_local_ips`) and is unchanged. Wine master and Proton 10 have no such change
(checked 2026-10-11). Against winecx `e0aa380`; the build and pin are in `docs/WINECX.md`
(Own host name).
