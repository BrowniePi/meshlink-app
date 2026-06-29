def build(n: int) -> dict[int, list[int]]:
    """Device 0 is the central relay; devices 1..n-1 connect only to device 0."""
    adj: dict[int, list[int]] = {i: [] for i in range(n)}
    for i in range(1, n):
        adj[0].append(i)
        adj[i].append(0)
    return adj
