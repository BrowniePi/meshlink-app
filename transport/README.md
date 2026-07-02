# transport

This package defines the transport abstraction used by the relay pipeline and provides a socket-based stand-in for BLE.

## Abstract interface (`base.py`)

Any transport must implement `Transport`:

| Method | Description |
|---|---|
| `start()` | Begin listening for incoming messages |
| `stop()` | Shut down the transport |
| `send(peer_id, data)` | Send raw bytes to a peer |
| `on_receive(callback)` | Register `callback(peer_id, data)` for incoming messages |
| `list_peers()` | Return known peer IDs |

The pipeline only ever calls this interface. It never imports `SocketTransport` directly.

## Socket transport (`socket_transport.py`)

A TCP-based implementation that stands in for BLE during Phase 0. Each instance:
- Binds a local TCP server on `127.0.0.1:<port>` (port 0 = OS-assigned)
- Embeds its own listening address in every outgoing frame so the receiver can call `send()` back
- Exposes `address` (e.g. `"127.0.0.1:54321"`) as the `peer_id` other nodes use to reach it
- Accepts peers via `connect_peer(peer_id)` — manually wired in tests, equivalent to BLE scan/connect in Phase 1

## Swapping in real BLE (Phase 1)

Implement `Transport` in a new `ble_transport.py`, pass it into the node in place of `SocketTransport`. No pipeline code changes required.
