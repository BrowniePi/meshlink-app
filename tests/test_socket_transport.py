"""Unit tests for SocketTransport."""
import threading

from transport.socket_transport import SocketTransport


def _make_pair() -> tuple[SocketTransport, SocketTransport]:
    a = SocketTransport()
    b = SocketTransport()
    a.start()
    b.start()
    a.connect_peer(b.address)
    b.connect_peer(a.address)
    return a, b


def test_two_nodes_exchange_message():
    a, b = _make_pair()
    try:
        received: list[bytes] = []
        event = threading.Event()

        b.on_receive(lambda _, data: (received.append(data), event.set()))
        a.send(b.address, b"hello from a")
        event.wait(timeout=1.0)

        assert received == [b"hello from a"]
    finally:
        a.stop()
        b.stop()


def test_receiver_gets_correct_sender_id():
    a, b = _make_pair()
    try:
        received_peers: list[str] = []
        event = threading.Event()

        b.on_receive(lambda peer_id, _: (received_peers.append(peer_id), event.set()))
        a.send(b.address, b"ping")
        event.wait(timeout=1.0)

        assert received_peers == [a.address]
    finally:
        a.stop()
        b.stop()


def test_bidirectional_exchange():
    a, b = _make_pair()
    try:
        a_got: list[bytes] = []
        b_got: list[bytes] = []
        a_event = threading.Event()
        b_event = threading.Event()

        a.on_receive(lambda _, data: (a_got.append(data), a_event.set()))
        b.on_receive(lambda _, data: (b_got.append(data), b_event.set()))

        a.send(b.address, b"a->b")
        b.send(a.address, b"b->a")

        a_event.wait(timeout=1.0)
        b_event.wait(timeout=1.0)

        assert b_got == [b"a->b"]
        assert a_got == [b"b->a"]
    finally:
        a.stop()
        b.stop()


def test_list_peers():
    a, b = _make_pair()
    try:
        assert b.address in a.list_peers()
        assert a.address in b.list_peers()
    finally:
        a.stop()
        b.stop()


def test_large_payload_transfers_intact():
    a, b = _make_pair()
    try:
        data = b"x" * 4096
        received: list[bytes] = []
        event = threading.Event()

        b.on_receive(lambda _, d: (received.append(d), event.set()))
        a.send(b.address, data)
        event.wait(timeout=2.0)

        assert received == [data]
    finally:
        a.stop()
        b.stop()
