# Changelog

## 2026-03-27 — Right-size infrastructure for non-prod environments

### Problem
After reducing instance sizes from metal/xlarge for cost savings, the Nomad/Consul
backplane failed to start. The bastion OOM'd, Packer AMI builds failed, and Nomad
could not schedule jobs because machines were drastically undersized for the workloads
(e.g. API node had 2GB RAM but Nomad jobs required ~14GB).

### Changes

#### Instance sizing
- **Bastion**: `t3.nano` (0.5GB) → `t3.small` (2GB) in both CloudFormation templates
- **Server nodes** (non-prod): `t3.small` (2GB) → `t3.medium` (4GB)
- **API node** (non-prod): `t3.small` (2GB) → `t3.xlarge` (16GB)
- **Packer build instance**: `t3.small` → `t3.medium` — fixes AMI build OOM failures

#### Nomad job resource reductions
All allocations reduced for non-prod workloads:
- `api`: 8192MB / 4000 CPU → 2048MB / 1000 CPU (max 4096MB)
- `client-proxy` (edge): 1024MB / 1000 CPU → 512MB / 500 CPU
- `docker-reverse-proxy`: 512MB / 256 CPU → 256MB / 128 CPU
- `template-manager`: 1024MB / 256 CPU → 512MB / 128 CPU
- `otel-collector`: 1024MB / 256 CPU → 256MB / 128 CPU (system job, every node)
- `logs-collector`: 512MB / 500 CPU → 256MB / 128 CPU (system job, every node)
- `loki`: 1024MB / 500 CPU → 256MB / 250 CPU; embedded caches 2048MB → 256MB

#### Removed redundant Redis Nomad job
- Deleted `nomad/origin/redis.hcl` — ElastiCache (CloudFormation) handles Redis
- Cleaned up commented-out redis entries in `nomad/deploy.sh`

#### Parameterization
- Added `server_count` Terraform variable (default 3) — controls server ASG sizing
  and Nomad `NUM_SERVERS`. Set to 1 for cheaper non-HA dev environments.
- Client startup script (`start-client.sh`) now auto-scales swap and tmpfs from
  detected RAM instead of hardcoding 100GB swap and 65GB tmpfs (sized for metal).
  - Swap: 2x RAM, clamped to 4–100GB
  - Snapshot cache tmpfs: 25% of RAM, minimum 2GB

### Estimated cost
~$373/month for a minimal demo/staging cluster (bastion + 3 servers + 1 API + 1 client).
