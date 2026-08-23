"""CLI: rebuild the Qdrant collection from a directory of *.md files."""

import argparse
import asyncio
from pathlib import Path

from app.config import settings
from app.rag import Rag


def main() -> None:
    parser = argparse.ArgumentParser(description="Rebuild the Qdrant collection.")
    # Required, so a rebuild is never run against a directory by accident.
    parser.add_argument("--path", required=True, type=Path)
    args = parser.parse_args()

    files, chunks = asyncio.run(Rag().rebuild(args.path))
    print(f"indexed {files} files -> {chunks} chunks into collection '{settings.collection}'")


if __name__ == "__main__":
    main()
