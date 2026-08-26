# Quality run

- Model: `qwen3:4b-q4_K_M`
- Cases: `benchmarks/quality/cases.tsv`

## readiness_vs_liveness — PASS

A Kubernetes readiness probe determines if a container is ready to receive traffic, while a liveness probe checks if a container is still running and needs to be restarted. The readiness probe affects whether the container is considered "ready" for traffic, and the liveness probe decides whether to restart the container if it fails.

## rag_grounding — PASS

Retrieval-augmented generation reduces hallucinations by incorporating information from relevant sources during the generation process. This approach allows the model to abstain from making up information not supported by the retrieved data.

## context_window — PASS

An LLM service uses a context-window limit to manage the amount of input data it can process at once, ensuring efficient use of resources. This limit helps maintain performance and prevents excessive memory usage by restricting the number of tokens in the context.

## quantization_tradeoff — PASS

4-bit quantization reduces model size and memory usage compared to 8-bit, but sacrifices more precision and may slightly slow down inference. 8-bit quantization offers a balance between memory efficiency, speed, and higher precision than 4-bit, making it suitable for most practical applications.

## parallel_requests — PASS

Increasing LLM parallel requests allows more tasks to be processed simultaneously, boosting overall throughput. However, each additional request requires more memory, leading to higher memory usage.

