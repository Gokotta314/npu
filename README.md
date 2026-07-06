# NPU — A Multi-Core BF16 Systolic-Array Accelerator with Cache + Prefetching

A small multi-core neural network accelerator built in Verilog.

## Status

| Component                                                              | Status          |
|------------------------------------------------------------------------|-----------------|
| BF16 systolic-array compute core (PE / PE_row / PE_array)              |  Done, verified |
| Multi-core dispatcher (AXI4-Lite slave, task descriptors, IRQ)         |  Done, verified |
| Per-core memory subsystem: L1 cache + IP-stride hardware prefetcher    |  Done, verified |
| Shared-memory interconnect: round-robin arbiter (single-outstanding)   |  Done, verified |
| MSHR-style multi-outstanding arbiter (tag-based response routing)      |  In progress    |
| 16×16 array / tiled matmul with partial-sum accumulation               | 📋 Planned, after MSHR |


## Architecture

                 AXI4-Lite (task descriptors, status, IRQ)
   [ Host ] ───────────────────────────────► [ npu_dispatcher ]
                                                            │
                                    ┌───────────────────────┼───────────────────────┐
                                    ▼                       ▼                       ▼
                              [ worker_core 0 ]       [ worker_core 1 ]   ...  [ worker_core N-1 ]
                              (data-parallel, no inter-core communication)
                                    │                       │                       │
                             cache+prefetch          cache+prefetch          cache+prefetch
                                    │                       │                       │
                                    └───────────────────────┼───────────────────────┘
                                                            ▼
                                                     [ mem_arbiter ]
                                                            │
                                                            ▼
                                                  [ shared memory / DRAM ]

Each `worker_core` wraps:
- an BF16 systolic-array compute datapath (`accelerator` → `controller`
  + `PE_array` → `PE_row` → `PE`, with `bf16_mul`/`bf16_add` arithmetic units),
- a private `l1_cache` (direct-mapped, read-only) with an embedded
  `stride_prefetcher` for the weight/activation fetch streams,
- a direct (non-cached) write-back path for results.

Workers are data-parallel and never talk to each other; the `npu_dispatcher`
only hands out independent tasks and never mediates data movement between
cores.

## Repository layout

npu_v1/
Makefile                  # VCS/Verdi/irun/Questa run targets, reads file list from files.f
files.f                   # filelist for compilation; testbench line is uncommented to pick which tb to build

rtl/
  accelerator.v, controller.v, PE.v, PE_row.v, PE_array.v,
  bf16_add.v, bf16_mul.v, shifter.v, SRAM.v,
  input_buffer.v, weight_buffer.v, output_buffer.v   # compute datapath
  worker_core.v           # wraps the compute datapath with cache/prefetch/writeback
  l1_cache.v              # per-core L1 cache (single-outstanding fill, pre-MSHR)
  stride_prefetcher.v     # IP-stride hardware prefetcher
  mem_arbiter.v           # shared-memory arbiter (round-robin, single-outstanding/locked)
  npu_dispatcher.v        # AXI4-Lite slave, task descriptors + status
  npu_top.v               # top-level: dispatcher + N workers + arbiter
  main_memory.v           # behavioral fixed-latency memory model, for simulation only

tb/
  tb_pe.v                 # standalone PE (single systolic-array cell) self-check
  tb_core.v               # standalone controller/datapath self-check (pre-accelerator wrapper)
  tb_accelerator_direct.v # drives accelerator directly, dumps output_buffer contents for golden comparison
  tb_main_memory.v        # main_memory.v latency/pipelining/RAW self-check
  tb_l1_cache.v           # l1_cache + stride_prefetcher self-check (hit/miss/prefetch counters)
  tb_worker_core.v        # worker_core vs. golden accelerator cross-check
  tb_mem_arbiter.v        # two-master round-robin arbiter self-check (response routing + fairness)
  tb_npu_dispatcher.v     # AXI4-Lite BFM driving the dispatcher register file
  tb_npu_top.v            # full-stack integration test: AXI4-Lite -> dispatcher -> workers -> arbiter -> memory

data/
  pe_testvector_generator.py   # generates bf16 test vectors for tb_pe.v
  pe_test_vectors.txt          # generated input vectors (hex bf16) consumed by tb_pe.v
  pe_test_results.txt          # expected output vectors for tb_pe.v
  pe_test_check.py             # compares simulated PE output against pe_test_results.txt
  single_core_test_check.py    # compares tb_core.v/single-core sim output against golden results
  single_core_test_vectors.txt # input vectors for the single-core controller/datapath test
  single_core_test_results.txt # expected output for the single-core controller/datapath test
  
All RTL in this repository has been simulated and passes the corresponding
self-checking testbench with VCS.


## Design simplifications

- **Bus protocol**: every internal interface (worker ↔ cache ↔ arbiter ↔
  memory) uses a simplified single-channel `valid/ready` request/response
  handshake, not full AXI4 (separate AR/R/AW/W/B channels). Only the
  dispatcher's CVA6-facing port is real AXI4-Lite. A thin adapter layer would
  be needed to present the worker-side interfaces as true AXI4.
- **Cache line size = 1 word**: no multi-word lines or burst fills; spatial
  locality is entirely handled by the stride prefetcher rather than by wide
  cache lines.
- **Arbiter is single-outstanding / locked**: only one request across all
  workers is in flight at the shared-memory port at a time — see "in
  progress" above.
- **Write-back bypasses the cache**: only reads (weight/activation fetch) are
  cached and prefetched; results are written directly.
