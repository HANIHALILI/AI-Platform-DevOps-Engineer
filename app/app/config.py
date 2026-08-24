from pydantic import Field, field_validator, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="AGENT_")

    llm_url: str = "http://ollama:11434/v1"
    llm_model: str = "llama3.2:3b"
    llm_key: str = "not-needed"
    llm_temperature: float = Field(default=0.1, ge=0.0, le=2.0)
    embed_url: str = "http://ollama:11434"
    embed_model: str = "all-minilm"
    qdrant_url: str = "http://qdrant:6333"
    qdrant_key: str | None = None
    collection: str = "docs"
    top_k: int = Field(default=3, ge=1)
    top_k_max: int = Field(default=5, ge=1)
    chunk_size: int = Field(default=800, ge=1)
    chunk_overlap: int = Field(default=100, ge=0)
    max_iterations: int = Field(default=5, ge=1, le=10)
    log_level: str = "INFO"

    # A key left empty in a Secret is a key that was not set, but pydantic hands
    # it over as "" and the Qdrant client sends anything non-None as an api-key
    # header — over plain HTTP, with a warning.
    @field_validator("qdrant_key", mode="after")
    @classmethod
    def _blank_is_unset(cls, value: str | None) -> str | None:
        return value or None

    @model_validator(mode="after")
    def _check_pairs(self):
        if self.chunk_overlap >= self.chunk_size:
            raise ValueError("chunk_overlap must be smaller than chunk_size")
        if self.top_k > self.top_k_max:
            raise ValueError("top_k must not exceed top_k_max")
        return self


settings = Settings()
