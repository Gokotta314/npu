Designed a multi-core BF16 hardware accelerator for on-device LLM inference: a dispatcher exposing an AXI4-Lite register interface for task configuration, dispatching to N independent worker cores in a data-parallel, communication-free scheme; each core implements a weight-stationary systolic array for matrix multiplication.

Implemented a per-core L1 cache with an IP-stride hardware prefetcher to hide off-chip memory access latency, instrumented with hit-rate/prefetch-effectiveness counters; verified the full compute-and-memory pipeline using a golden-model cross-checked VCS/Verdi self-checking testbench suite.

Currently upgrading the shared-memory arbiter from single-outstanding round-robin arbitration to tag-based, multi-request pipelined arbitration (MSHR-style), to support concurrent in-flight memory accesses across cores.
