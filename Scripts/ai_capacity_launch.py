"""Installed entry point; imports only the dashboard beside this file."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from ai_capacity.server import main

if __name__ == '__main__':
    main()
