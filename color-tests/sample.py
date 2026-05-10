#!/usr/bin/env python3
from pathlib import Path
import json

DEFAULT_LIMIT = 10

multiline_str: str = """

testing testing

does this stay right?
"""

def traced(fn):
    def wrapper(*args, **kwargs):
        print(f"calling {fn.__name__}")
        return fn(*args, **kwargs)
    return wrapper

@traced
def load_items(path: Path, limit: int = DEFAULT_LIMIT) -> list[dict]:
    data = json.loads(path.read_text() or "[]")
    return [
        {"name": item.get("name", "unknown"), "active": True}
        for item in data[:limit]
        if item.get("enabled") is not False
    ]

# This looks like a good class to me!
class TestingClassNames(None):
    def __init__(self, *args, **kwargs):
        """But not a good method."""
        pass

if __name__ == "__main__":
    # Exercise comments, strings, decorators, numbers, and constants.
    for row in load_items(Path("items.json"), limit=3):
        print(f"{row['name']}: {row['active']}")
