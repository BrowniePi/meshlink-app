"""Plain-text event logging for the simulation harness — verify-by-eye output."""
import time

_start = time.monotonic()


def log_event(event: str, device_index: int, **fields) -> None:
    """Print one line: t=<ms-since-start> device=<i> event=<name> k=v ..."""
    elapsed_ms = int((time.monotonic() - _start) * 1000)
    parts = [f"t={elapsed_ms}ms", f"device={device_index}", f"event={event}"]
    parts += [f"{k}={v}" for k, v in fields.items()]
    print(" ".join(parts))
