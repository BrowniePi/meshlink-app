import socket
import threading
from typing import Callable

from .base import Transport

# Frame format over the wire:
#   [1 byte: len(sender_addr)] [sender_addr bytes] [4 bytes: len(data)] [data bytes]
# Embedding the sender's listening address lets the receiver call send() back to the
# correct port — mirrors how BLE gives the central the peripheral's address.


class SocketTransport(Transport):
    def __init__(self, host: str = "127.0.0.1", port: int = 0) -> None:
        self._host = host
        self._port = port
        self._server: socket.socket | None = None
        self._callback: Callable[[str, bytes], None] | None = None
        self._peers: set[str] = set()
        self._running = False

    @property
    def address(self) -> str:
        return f"{self._host}:{self._port}"

    def start(self) -> None:
        self._server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self._server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._server.bind((self._host, self._port))
        self._server.listen(16)
        self._port = self._server.getsockname()[1]
        self._running = True
        t = threading.Thread(target=self._accept_loop, daemon=True)
        t.start()

    def stop(self) -> None:
        self._running = False
        if self._server:
            self._server.close()
            self._server = None

    def connect_peer(self, peer_id: str) -> None:
        self._peers.add(peer_id)

    def send(self, peer_id: str, data: bytes) -> None:
        host, port_str = peer_id.rsplit(":", 1)
        addr_bytes = self.address.encode()
        frame = (
            bytes([len(addr_bytes)])
            + addr_bytes
            + len(data).to_bytes(4, "big")
            + data
        )
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.connect((host, int(port_str)))
            s.sendall(frame)

    def on_receive(self, callback: Callable[[str, bytes], None]) -> None:
        self._callback = callback

    def list_peers(self) -> list[str]:
        return list(self._peers)

    def _accept_loop(self) -> None:
        while self._running:
            try:
                conn, _ = self._server.accept()
            except OSError:
                break
            threading.Thread(target=self._handle, args=(conn,), daemon=True).start()

    def _handle(self, conn: socket.socket) -> None:
        with conn:
            def recv_exact(n: int) -> bytes | None:
                buf = b""
                while len(buf) < n:
                    chunk = conn.recv(n - len(buf))
                    if not chunk:
                        return None
                    buf += chunk
                return buf

            addr_len_raw = recv_exact(1)
            if not addr_len_raw:
                return
            addr_bytes = recv_exact(addr_len_raw[0])
            if not addr_bytes:
                return
            data_len_raw = recv_exact(4)
            if not data_len_raw:
                return
            data = recv_exact(int.from_bytes(data_len_raw, "big"))
            if data is None:
                return

            sender_id = addr_bytes.decode()
            if self._callback:
                self._callback(sender_id, data)
