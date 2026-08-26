import asyncio
import logging
import time
from pathlib import Path
from typing import NamedTuple

from langchain_core.documents import Document
from langchain_ollama import OllamaEmbeddings
from langchain_qdrant import QdrantVectorStore
from langchain_text_splitters import RecursiveCharacterTextSplitter
from qdrant_client.http.exceptions import UnexpectedResponse

from app.config import settings
from app.observability import event, qdrant_search_seconds

EMBED_TIMEOUT = 30


class RagUnavailable(Exception): ...


def _splitter() -> RecursiveCharacterTextSplitter:
    return RecursiveCharacterTextSplitter(
        chunk_size=settings.chunk_size, chunk_overlap=settings.chunk_overlap
    )


class Hit(NamedTuple):
    text: str
    source: str
    score: float


class Rag:
    def __init__(self):
        self.embeddings = OllamaEmbeddings(
            model=settings.embed_model,
            base_url=settings.embed_url,
            client_kwargs={"timeout": EMBED_TIMEOUT},
        )
        self._store: QdrantVectorStore | None = None

    async def _connect(self) -> QdrantVectorStore:
        if self._store is None:
            self._store = await asyncio.to_thread(
                QdrantVectorStore.from_existing_collection,
                collection_name=settings.collection,
                embedding=self.embeddings,
                url=settings.qdrant_url,
                api_key=settings.qdrant_key,
            )
        return self._store

    # Additive, unlike rebuild: creates the collection if missing, appends to it otherwise.
    async def ingest(self, name: str, text: str) -> int:
        chunks = _splitter().create_documents([text], metadatas=[{"source": name}])
        if not chunks:
            return 0
        try:
            await QdrantVectorStore.afrom_documents(
                chunks,
                embedding=self.embeddings,
                url=settings.qdrant_url,
                api_key=settings.qdrant_key,
                collection_name=settings.collection,
            )
        except Exception as exc:
            raise RagUnavailable(type(exc).__name__) from exc
        return len(chunks)

    async def search(self, query: str, k: int) -> list[Hit]:
        started = time.perf_counter()
        status = "ok"
        try:
            store = await self._connect()
            results = await store.asimilarity_search_with_score(query, k=k)
        except Exception as exc:
            status = "error"
            if isinstance(exc, UnexpectedResponse) and exc.status_code == 404:
                event("collection_missing", logging.WARNING)
            raise RagUnavailable(type(exc).__name__) from exc
        finally:
            qdrant_search_seconds.labels(status).observe(time.perf_counter() - started)
        return [Hit(doc.page_content, doc.metadata["source"], score) for doc, score in results]

    # force_recreate: no incremental path, so stale chunks from edited files cannot survive.
    async def rebuild(self, path: Path) -> tuple[int, int]:
        def load():
            files = sorted(path.rglob("*.md"))
            return files, [
                Document(page_content=f.read_text(encoding="utf-8"), metadata={"source": f.name})
                for f in files
            ]

        files, docs = await asyncio.to_thread(load)
        chunks = _splitter().split_documents(docs)
        await QdrantVectorStore.afrom_documents(
            chunks,
            embedding=self.embeddings,
            url=settings.qdrant_url,
            api_key=settings.qdrant_key,
            collection_name=settings.collection,
            force_recreate=True,
        )
        return len(files), len(chunks)

    async def ping(self) -> bool:
        try:
            await self._connect()
        except Exception:
            return False
        return True
