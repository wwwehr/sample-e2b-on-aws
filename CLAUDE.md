# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

E2B on AWS deploys secure, scalable AI sandbox infrastructure (based on E2B's open-source `infra` repo) into a customer's AWS account. It uses Firecracker microVMs orchestrated by HashiCorp Nomad, with Consul for service discovery, PostgreSQL (Aurora) for state, and S3 for artifacts.

## Build & Deploy Commands

```bash
# Environment management (reads .env.<ENV> files, tracks in .last_used_env)
make ENV=dev switch-env       # Switch active environment
make check-env                # Validate environment configuration
make check-aws                # Verify AWS CLI setup

# Infrastructure
make init                     # Initialize Terraform with S3 state backend
make plan                     # Terraform plan
make apply                    # Terraform apply
make destroy                  # Terraform destroy (preserves buckets)
make build-aws-ami            # Build EC2 AMI via Packer

# Application builds (Docker multi-stage → ECR)
make build-and-upload         # Build and push ALL service images to ECR
make build-and-upload/api     # Build and push a single package (api, orchestrator, etc.)
make build/api                # Local build only (no push)

# Tests
make test                     # Run tests across all Go packages

# Database
make migrate                  # Run PostgreSQL migrations (delegates to packages/shared)

# Sync E2B public builds (Firecracker kernels, envd) from GCS → S3
make copy-public-builds
```

Individual packages have their own Makefiles under `packages/<name>/` with `build`, `test`, `upload-aws`, and `build-and-upload` targets.

## Architecture

### Infrastructure Layers

1. **CloudFormation** (`e2b-setup-env.yml` / `e2b-setup-env-existing-vpc.yml`) — provisions VPC, Aurora PostgreSQL 16, S3 buckets, ACM certs, security groups, and a bastion EC2 instance
2. **Packer** (`infra-iac/packer/`) — builds base AMI with Consul + Nomad agents
3. **Terraform** (`infra-iac/terraform/main.tf`) — deploys EC2 Auto Scaling Groups (server, client, API, build nodes), S3 buckets, IAM roles, Secrets Manager entries
4. **Nomad** (`nomad/origin/*.hcl`) — schedules services: api, orchestrator, template-manager, redis, loki, otel-collector, docker-reverse-proxy, edge

### Core Services (all Go, under `packages/`)

| Service | Transport | Purpose |
|---|---|---|
| **api** | Gin REST (oapi-codegen) | External API gateway, 8GB memory allocation |
| **orchestrator** | gRPC | Sandbox lifecycle (create/destroy Firecracker VMs) |
| **template-manager** | gRPC | Template build lifecycle; shares go.mod with orchestrator |
| **envd** | gRPC (protobuf in `spec/`) | In-VM environment daemon |
| **client-proxy** | Gin | Client-facing proxy |
| **docker-reverse-proxy** | Go | Docker daemon proxy for template builds |
| **shared** | library | Common packages: models, db, grpc, logger, telemetry, storage, proxy |

### Data Flow

```
Client → API (Gin) → gRPC → Orchestrator → Nomad → Firecracker VM (envd)
                    → gRPC → Template Manager → Docker builds
```

All services receive `POSTGRES_CONNECTION_STRING` (Aurora) and connect to Redis, S3, Consul via Nomad environment variables injected from `config.properties`.

### Code Generation

- **OpenAPI**: `oapi-codegen` generates Gin server/client stubs (packages/api, shared/pkg/http/edge)
- **gRPC**: `protoc` with Go plugins (packages/envd/spec, shared/pkg/grpc)
- **SQL**: `sqlc` generates type-safe Go from queries (packages/db/queries → packages/db/client)

### Database

PostgreSQL (Aurora PostgreSQL 16 via CloudFormation). Connection string format: `postgresql://<user>:<pass>@<host>/<db>`. Migrations live in `packages/db/migrations/` (39 files, tern-based). The schema covers: users, teams, API keys, templates, builds, sandboxes, snapshots, tiers. Row-Level Security (RLS) is enforced. A local dev database can be spun up via `packages/db/migrations/docker-compose.yml` (Postgres 15).

### Key S3 Buckets

- `<prefix>fc-kernels` — Firecracker kernel binaries
- `<prefix>fc-versions` — Firecracker VM binaries
- `<prefix>fc-env-pipeline` — envd builds
- Plus: loki logs, docker contexts, template storage

### Environment Configuration

Environment variables are stored in `.env.<name>` files (not committed). Key vars: `AWS_REGION`, `AWS_ACCOUNT_ID`, `DOMAIN_NAME`, `PREFIX`, cluster sizes, machine types. The active env is tracked in `.last_used_env`.

## Supported Architectures

Both x86_64 and ARM64 (AWS Graviton) are supported. Architecture selection is made at CloudFormation stack creation time and propagates through AMI builds, instance types, and Docker image builds.
