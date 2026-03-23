# ClickHouse Source-Level Memory Optimization Experiments

## Context

- Source-built binary: peak_rss_mb=400.5 (down from 1149.9 stock)
- Code segment: ~234 MB, leaving ~166 MB of optimizable runtime memory
- 103 memory allocations through MemoryTracker, 99 in the 1-16 MB range
- INSERT peaks at 11.6 MB, GROUP BY at 2.5-2.7 MB
- TrackedMemory: 171 MB, MemoryTracking: 114 MB

## Analysis Findings

### Finding 1: Per-Column 1 MB Write Buffers (PRIMARY TARGET)

**What the code does:**
Each column in a MergeTree INSERT creates a `MergeTreeWriterStream` (file: `src/Storages/MergeTree/MergeTreeWriterStream.h`).
Each stream contains a buffer chain:

```
compressed_hashing -> compressor (CompressedWriteBuffer, 1 MB) -> plain_hashing -> plain_file (WriteBufferFromFile, 1 MB)
marks_compressed_hashing -> marks_compressor -> marks_hashing -> marks_file (4 KB)
```

The `CompressedWriteBuffer` allocates `buf_size = DBMS_DEFAULT_BUFFER_SIZE = 1,048,576` (1 MB) at construction
(`src/Compression/CompressedWriteBuffer.cpp:81`). The underlying `WriteBufferFromFile` (`plain_file`) also
allocates `max_compress_block_size` bytes (default 1 MB) as its I/O buffer (`src/Storages/MergeTree/MergeTreeWriterStream.cpp:72`).

**Why it's a hot spot:**
For a table with N columns, each INSERT creates N streams. Each stream allocates TWO 1 MB buffers
(one CompressedWriteBuffer + one WriteBufferFromFile), totaling 2 MB per column. A 6-column table = 12 MB just
for write buffers, matching the observed 11.6 MB INSERT peak.

**Existing mitigation:**
ClickHouse has an adaptive write buffer mechanism (`use_adaptive_write_buffer`) that starts at 16 KB and grows
to 1 MB. However, the MergeTree setting `min_columns_to_activate_adaptive_write_buffer` defaults to **500**
(`src/Storages/MergeTree/MergeTreeSettings.cpp:980`), meaning adaptive buffers are only used for tables with
500+ columns. For typical tables with <500 columns, every column gets full 1 MB buffers.

**Key constants:**
- `DBMS_DEFAULT_BUFFER_SIZE = 1,048,576` (1 MB) -- `src/Core/Defines.h:21`
- `DBMS_DEFAULT_INITIAL_ADAPTIVE_BUFFER_SIZE = 16,384` (16 KB) -- `src/Core/Defines.h:24`
- `max_compress_block_size` default = `1,048,576` (1 MB) -- `src/Core/Settings.cpp:121`
- `min_columns_to_activate_adaptive_write_buffer` default = `500` -- `src/Storages/MergeTree/MergeTreeSettings.cpp:980`
- `adaptive_write_buffer_initial_size` default = `16,384` (16 KB) -- `src/Storages/MergeTree/MergeTreeSettings.cpp:987`

### Finding 2: TemporaryDataOnDisk Buffer Size for GROUP BY

**What the code does:**
`TemporaryDataOnDisk` creates `CompressedWriteBuffer` with `buffer_size` from `TemporaryDataOnDiskSettings`,
which defaults to `DBMS_DEFAULT_BUFFER_SIZE` = 1 MB (`src/Interpreters/TemporaryDataOnDisk.h:58`).
This is used by aggregation (GROUP BY), sorting, and JOIN operations when spilling to disk.

The buffer is allocated at `TemporaryDataBuffer` construction (`src/Interpreters/TemporaryDataOnDisk.cpp:392`):
```cpp
out_compressed_buf(file_holder->write(), getCodec(...), parent->getSettings().buffer_size)
```

The `buffer_size` can be overridden through the `temporary_files_buffer_size` setting, which also defaults
to `DBMS_DEFAULT_BUFFER_SIZE` (`src/Core/Settings.cpp:3391`).

**Why it's a hot spot:**
For small workloads, a 1 MB buffer for temporary data is excessive. GROUP BY peaks at 2.5-2.7 MB;
a significant portion of that is the compression buffer itself.

### Finding 3: PODArray Default Initial Capacity

**What the code does:**
`PODArray` and `PaddedPODArray` use a default `initial_bytes = 4096` (`src/Common/PODArray_fwd.h:19,25`).
This means the first allocation for any PODArray is 4 KB. The `empty_pod_array` static sentinel is 1024 bytes
(`src/Common/PODArray.h:69`).

**Why it may contribute:**
4 KB is reasonable for most use cases. This is NOT the primary hot spot -- the 1 MB write buffers are
far more impactful. PODArray defaults are well-tuned and changing them risks regressions.

---

## Experiment Plan (Ordered by Expected Impact)

### Experiment 1: Lower `min_columns_to_activate_adaptive_write_buffer` from 500 to 1

**Expected impact:** ~10 MB reduction for a 6-column INSERT (from 12 MB to ~1.2 MB)

**What to change:**
- File: `src/Storages/MergeTree/MergeTreeSettings.cpp`
- Line 980: Change `DECLARE(UInt64, min_columns_to_activate_adaptive_write_buffer, 500, ...)` to
  `DECLARE(UInt64, min_columns_to_activate_adaptive_write_buffer, 1, ...)`

**Mechanism:**
This activates the adaptive write buffer for ALL tables, not just those with 500+ columns.
With adaptive buffers enabled, each `CompressedWriteBuffer` starts at 16 KB and grows to 1 MB
only if needed. The `WriteBufferFromFile` also starts at 16 KB (`DBMS_DEFAULT_INITIAL_ADAPTIVE_BUFFER_SIZE`).

For small INSERT workloads, buffers will stay small (16 KB or 32 KB) instead of
immediately allocating 1 MB. For a 6-column table: 6 columns x 2 buffers x 16 KB = 192 KB
instead of 6 x 2 x 1 MB = 12 MB.

**Activation path in code:**
- `MergeTreeDataPartWriterWide.cpp:192-195`: checks `min_columns_to_activate_adaptive_write_buffer`
  and sets `query_write_settings.use_adaptive_write_buffer = true`
- This flows to `MergeTreeWriterStream.cpp:74`: `CompressedWriteBuffer` gets `use_adaptive_buffer_size=true`
  with `adaptive_buffer_initial_size=16384`
- And to `DiskLocal.cpp:387-388`: `WriteBufferFromFile` gets `use_adaptive_buffer_size_=true`
  with `adaptive_write_buffer_initial_size=16384`

**Risk:** Low. The adaptive mechanism already exists and is used for tables with 500+ columns.
Setting the threshold to 1 just enables it unconditionally. Buffers still grow to the full 1 MB
if data throughput requires it, so large workloads are unaffected.

### Experiment 2: Reduce `DBMS_DEFAULT_BUFFER_SIZE` from 1 MB to 256 KB

**Expected impact:** ~3-8 MB reduction across all buffer allocations

**What to change:**
- File: `src/Core/Defines.h`
- Line 21: Change `static constexpr auto DBMS_DEFAULT_BUFFER_SIZE = 1048576ULL;`
  to `static constexpr auto DBMS_DEFAULT_BUFFER_SIZE = 262144ULL;`

**Mechanism:**
This constant is the default buffer size for:
- `CompressedWriteBuffer` (compression blocks)
- `BufferWithOwnMemory<WriteBuffer>` (I/O buffers)
- `TemporaryDataOnDisk` (GROUP BY / JOIN spill buffers)
- `max_compress_block_size` default (compression block size)
- `temporary_files_buffer_size` default
- All `WriteBufferFromFile` and `ReadBufferFromFile` defaults

Reducing from 1 MB to 256 KB shrinks EVERY non-adaptive buffer by 4x. This affects both
write buffers that don't use adaptive sizing and the max cap for those that do.

**Risk:** Medium. This is a global constant affecting read AND write paths. Smaller buffers mean
more system calls for I/O-intensive workloads. The `max_compress_block_size` setting (which controls
compression block granularity) is also keyed off this default, so compression ratio could be
slightly affected. Would need benchmarking under production-like loads.

### Experiment 3: Reduce `temporary_files_buffer_size` default to 64 KB

**Expected impact:** ~1-2 MB reduction for GROUP BY spill buffers

**What to change:**
- File: `src/Core/Settings.cpp`
- Line 3391: Change `DECLARE(NonZeroUInt64, temporary_files_buffer_size, DBMS_DEFAULT_BUFFER_SIZE, ...)`
  to `DECLARE(NonZeroUInt64, temporary_files_buffer_size, 65536, ...)`

**Mechanism:**
This only affects `TemporaryDataOnDisk` buffers used for aggregation/sorting/join spills.
The buffer is the `CompressedWriteBuffer` inside `TemporaryDataBuffer`
(`src/Interpreters/TemporaryDataOnDisk.cpp:392`).

For small workloads, 64 KB is sufficient for the compression buffer since the actual data
being compressed per block is small. This narrows the scope compared to Experiment 2
(only affects temp data, not MergeTree writes).

**Risk:** Low. This is a user-facing setting with a clear scope. Users with large spill
workloads can override it. The 64 KB value is still 4x the `min_compress_block_size` default (64 KB),
so compression blocks will still form efficiently.

---

## Summary Table

| Experiment | File | Change | Expected Savings | Risk |
|---|---|---|---|---|
| 1 | MergeTreeSettings.cpp:980 | min_columns_to_activate_adaptive_write_buffer: 500 -> 1 | ~10 MB | Low |
| 2 | Defines.h:21 | DBMS_DEFAULT_BUFFER_SIZE: 1 MB -> 256 KB | ~3-8 MB | Medium |
| 3 | Settings.cpp:3391 | temporary_files_buffer_size: 1 MB -> 64 KB | ~1-2 MB | Low |

**Recommended order:** Experiment 1 first (highest impact, lowest risk), then Experiment 3,
then Experiment 2 only if more savings are needed.
