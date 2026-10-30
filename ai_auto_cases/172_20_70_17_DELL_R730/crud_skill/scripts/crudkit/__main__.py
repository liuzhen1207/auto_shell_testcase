"""Entry point so `python3 -m crudkit` behaves like `scripts/crud.sh`."""
from __future__ import annotations

import sys

from .cli import main

if __name__ == "__main__":
    sys.exit(main())
