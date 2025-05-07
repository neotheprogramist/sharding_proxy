# Analysis of CRDT Compliance in Our Implementation

During our review of CRDTs (Conflict-free Replicated Data Types), we found that some of our operations can be mapped to well-known CRDT types:

Add is conceptually similar to a G-Counter (Grow-only Counter) — a structure that only allows increment operations. While the Add operation is not idempotent by itself (reapplying it changes the result), it is still valid within a CRDT context when each replica maintains its own counter and a proper merge function is used.

Set resembles a LWW-Element-Set (Last-Write-Wins Set), where in case of conflicting values, the one with the latest timestamp (or version) is considered the correct one. Our current implementation does not include such a timestamp or version marker, which is required to determine which write "wins." Introducing a monotonically increasing, globally unique marker (e.g., a Lamport timestamp or logical clock) would make it compatible with this CRDT type.

Lock is more challenging to classify within standard CRDT models. It behaves like a one-time write operation that disallows any subsequent changes. While this doesn't map directly to any classical CRDT, it can be thought of as a Write-Once Register or a single-writer CRDT, where the first write deterministically defines the state, and all following operations are rejected.