def build(n: int) -> dict[int, list[int]]:
    """Devices 0..n-1 in a line: device i connects only to i-1 and i+1.

    Worst case for hop count — a message from one end must traverse n-1 hops
    to reach the other end.
    """
    adj: dict[int, list[int]] = {i: [] for i in range(n)}
    for i in range(n - 1):
        adj[i].append(i + 1)
        adj[i + 1].append(i)
    return adj
