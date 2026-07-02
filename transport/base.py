from abc import ABC, abstractmethod
from typing import Callable


class Transport(ABC):
    @abstractmethod
    def start(self) -> None: ...

    @abstractmethod
    def stop(self) -> None: ...

    @abstractmethod
    def send(self, peer_id: str, data: bytes) -> None:
        """Send raw bytes to a peer identified by peer_id."""

    @abstractmethod
    def on_receive(self, callback: Callable[[str, bytes], None]) -> None:
        """Register a callback invoked as callback(peer_id, data) on each received message."""

    @abstractmethod
    def list_peers(self) -> list[str]:
        """Return the peer_ids of all known peers."""
