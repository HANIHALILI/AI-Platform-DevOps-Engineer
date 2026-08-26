"""CLI: rebuild the Qdrant collection from a directory of *.md files."""

import argparse
import asyncio
from pathlib import Path

from agent.config import settings
from agent.rag import Rag


def main() -> None:
    parser = argparse.ArgumentParser(description="Rebuild the Qdrant collection.")
    # Required: a rebuild drops the collection, so it must not pick up a default.
    parser.add_argument("--path", required=True, type=Path)
    args = parser.parse_args()

    files, chunks = asyncio.run(Rag().rebuild(args.path))
    print(f"indexed {files} files -> {chunks} chunks into collection '{settings.collection}'")


if __name__ == "__main__":
    main()
