def build(n: int) -> dict[int, list[int]]:
    """Fully connected: every device connects to every other device."""
    return {i: [j for j in range(n) if j != i] for i in range(n)}
