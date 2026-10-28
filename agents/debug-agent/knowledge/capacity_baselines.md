# Capacity Baselines

<!-- TODO: fill in real numbers once confirmed per cluster/environment.
This is the "known-good" reference the debug agent compares live numbers
against when deciding if something is actually abnormal, vs. normal
variance. Without this, every sweep has nothing to compare against. -->

## Aurora cluster (shared by data-agent's sources)

| Metric                | Known-good range | Notes |
|------------------------|-------------------|-------|
| max_connections        | TODO              |       |
| typical connections    | TODO              |       |
| CPUUtilization          | TODO              |       |
| FreeableMemory          | TODO              |       |
| ReplicaLag              | TODO              |       |
| ReadIOPS / WriteIOPS    | TODO              |       |

## Per-database notes

<!-- TODO: anything specific to security_master / atlas / invest databases
on this cluster worth noting (e.g. a known-heavy table, an expected
periodic connection spike from a batch job, etc). -->
