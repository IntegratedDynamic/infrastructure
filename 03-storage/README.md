# 03-storage — what this domain is for

The cluster's **persistence layer**. Every workload on this cluster — the
cluster itself, really — is designed to be interruptible: nodes can be
destroyed and recreated, the whole cluster can be torn down and stood back
up. What survives that and lets it come back to the same state is whatever
this domain holds. A bucket here isn't "storage for a tool"; it's part of
what makes the cluster's interruptibility survivable in the first place.

No distinction is drawn between *who* consumes a bucket (platform tooling
like OpenBao's snapshot agent or Velero, vs. a product/application) or
*what kind* of data it holds (a backup, metrics/log storage for something
like Prometheus or Loki, business data an application owns). All of it is
"persistent state the cluster depends on across a restart," and that's the
one property this domain cares about — not the consumer, not the data's
shape.

## The contract

- **One bucket, one workload identity, per consumer.** Never share a bucket
  across two consumers even if their permission needs are identical.
- **Deletion is an admin human action, not something Terraform or CI can do.**
  Buckets here hold data the cluster needs to come back from a restart;
  `prevent_destroy` plus no destroy trigger in any CI workflow are both
  load-bearing, not incidental.

## What deliberately doesn't belong here

- The CI identity that applies this root module — a separate credential
  from each bucket's own workload identity, minted in
  `01-iam/bootstrap/scaleway`, not something this domain creates for itself.
- Any data that doesn't need to survive the cluster being torn down and
  recreated — ephemeral scratch state has no reason to live here.
