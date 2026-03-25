# Social Post (LinkedIn / X)

---

Built an AI-driven code optimization framework that autonomously profiles, identifies bottlenecks, and implements fixes for open-source C++ projects.

First target: ClickHouse's Arena allocator.

The agent:
1. Profiled baseline — found Arena accounts for 56% of peak query memory
2. Identified that Arena::realloc permanently wastes old memory regions
3. Added a free-list data structure to recycle wasted allocations

Result: -7.8% peak RSS (134 MB) on aggregation workloads, zero performance regression. Same-version A/B benchmark with identical build config.

Key lesson: our first approach ("guess and test") produced a flashy -62% number that was entirely an artifact. Switching to "profile first, then target" produced a smaller but real, reproducible result.

Code + full experiment report: [link]

Feedback welcome — especially from ClickHouse contributors. Is the Arena free-list approach sound? What are we missing?

#clickhouse #performance #memoryoptimization #opensource #ai

---
