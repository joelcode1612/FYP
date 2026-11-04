def rank(items):
    return sorted(items, key=lambda x: x.get("score", 0) if isinstance(x, dict) else 0, reverse=True)
