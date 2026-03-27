# E2B on AWS — Architecture & Resource Inventory

This document catalogs every resource created by the E2B stack across all three infrastructure layers: CloudFormation, Terraform, and Nomad. Use it to understand what exists, where it lives, and what depends on what.

---

## Table of Contents

- [High-Level Architecture](#high-level-architecture)
- [Network Topology](#network-topology)
- [Request Flow](#request-flow)
- [Layer 1: CloudFormation](#layer-1-cloudformation)
- [Layer 2: Packer AMI](#layer-2-packer-ami)
- [Layer 3: Terraform](#layer-3-terraform)
- [Layer 4: Nomad Services](#layer-4-nomad-services)
- [Observability Stack](#observability-stack)
- [Security Model](#security-model)
- [Resource Dependency Graph](#resource-dependency-graph)
- [Complete Resource Index](#complete-resource-index)

---

## High-Level Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              AWS Account                                    │
│                                                                             │
│  ┌─── CloudFormation ────────────────────────────────────────────────────┐  │
│  │  VPC, Subnets, NAT, IGW, Aurora PostgreSQL, ElastiCache Redis,       │  │
│  │  ACM Certificate, S3 Buckets (terraform-state, software),            │  │
│  │  Bastion Host, IAM Role, Security Groups (bastion, db, redis)        │  │
│  └──────────────────────────────────────────────────────────────────────-┘  │
│                                    │                                        │
│                          CFN Exports (21 values)                            │
│                                    ▼                                        │
│  ┌─── Terraform ─────────────────────────────────────────────────────────┐  │
│  │  4 ASGs (server, client, api, build), ALB + listeners,               │  │
│  │  5 Security Groups, 4 Launch Templates, 8 S3 Buckets,               │  │
│  │  4 Secrets Manager secrets, IAM Role + Instance Profile,             │  │
│  │  CloudWatch Log Group                                                │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
│                                    │                                        │
│                        Nomad + Consul Cluster                               │
│                                    ▼                                        │
│  ┌─── Nomad Jobs ────────────────────────────────────────────────────────┐  │
│  │  API, Orchestrator, Template Manager, Client Proxy, Redis,           │  │
│  │  Docker Reverse Proxy, Loki, OTEL Collector, Logs Collector          │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
│                                    │                                        │
│                                    ▼                                        │
│                        Firecracker microVMs (envd)                          │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Network Topology

```
                        Internet
                            │
                     ┌──────┴──────┐
                     │ Internet GW │
                     └──────┬──────┘
                            │
              ┌─────────────┴─────────────┐
              │        VPC (10.0.0.0/16)  │
              │                           │
              │  ┌─ Public Subnets ─────┐ │
              │  │ 10.0.0.0/20  (AZ-1) │ │     ┌──────────┐
              │  │ 10.0.16.0/20 (AZ-2) │◄├─────│ ALB      │ :443
              │  │                      │ │     │ (public  │
              │  │ ┌──────────┐         │ │     │  or      │
              │  │ │ Bastion  │ :22     │ │     │  private)│
              │  │ └──────────┘         │ │     └──────────┘
              │  │ ┌──────────┐         │ │
              │  │ │ NAT GW   │         │ │
              │  │ └────┬─────┘         │ │
              │  └──────┼───────────────┘ │
              │         │                 │
              │  ┌──────▼───────────────┐ │
              │  │ Private Subnets      │ │
              │  │ 10.0.32.0/20 (AZ-1) │ │
              │  │ 10.0.48.0/20 (AZ-2) │ │
              │  │                      │ │
              │  │ ┌────────┐ x3        │ │
              │  │ │ Server │ Nomad+    │ │
              │  │ │ Nodes  │ Consul    │ │
              │  │ └────────┘ leaders   │ │
              │  │                      │ │
              │  │ ┌────────┐ 1-5       │ │
              │  │ │ Client │ Firecrackr│ │
              │  │ │ Nodes  │ microVMs  │ │
              │  │ └────────┘ (.metal)  │ │
              │  │                      │ │
              │  │ ┌────────┐ x1        │ │
              │  │ │ API    │ API+proxy │ │
              │  │ │ Node   │ +redis    │ │
              │  │ └────────┘           │ │
              │  │                      │ │
              │  │ ┌────────┐ 0         │ │
              │  │ │ Build  │ Template  │ │
              │  │ │ Nodes  │ builds    │ │
              │  │ └────────┘           │ │
              │  │                      │ │
              │  │ ┌────────────────┐   │ │
              │  │ │Aurora PG 16   │   │ │
              │  │ │(Serverless v2)│   │ │
              │  │ └────────────────┘   │ │
              │  │ ┌────────────────┐   │ │
              │  │ │ElastiCache     │   │ │
              │  │ │Redis Serverless│   │ │
              │  │ └────────────────┘   │ │
              │  └──────────────────────┘ │
              │                           │
              │  ┌─ S3 VPC Endpoint ────┐ │
              │  │ Gateway (no NAT cost)│ │
              │  └──────────────────────┘ │
              └───────────────────────────┘
```

---

## Request Flow

### Sandbox Lifecycle

```
Client ──HTTPS──▶ ALB (:443)
                    │
        ┌───────────┼──────────────────┐
        │           │                  │
   api.domain   *.domain        docker.domain
        │           │                  │
        ▼           ▼                  ▼
   ┌────────┐  ┌──────────┐   ┌──────────────┐
   │  API   │  │ Client   │   │ Docker       │
   │ :50001 │  │ Proxy    │   │ Reverse Proxy│
   │ (Gin)  │  │ :3002    │   │ :5000        │
   └───┬────┘  └──────────┘   └──────────────┘
       │
       │ gRPC
       ▼
   ┌──────────────┐     ┌───────────────────┐
   │ Orchestrator │     │ Template Manager  │
   │ :5008        │     │ :5009             │
   └──────┬───────┘     └───────────────────┘
          │
          │ Nomad API
          ▼
   ┌──────────────┐
   │ Firecracker  │
   │ microVM      │
   │  ┌────────┐  │
   │  │ envd   │  │
   │  │ (gRPC) │  │
   │  └────────┘  │
   └──────────────┘
```

### Service Discovery

```
┌─────────────────────────────────────────┐
│             Consul DNS (:8600)          │
│                                         │
│  api.service.consul          → :50001   │
│  orchestrator.service.consul → :5008    │
│  template-manager.service.consul → :5009│
│  redis.service.consul        → :6379    │
│  loki.service.consul         → :3100    │
│  otel-collector.service.consul → :4317  │
│  proxy.service.consul        → :3002    │
│  edge-api.service.consul     → :3001    │
│  docker-reverse-proxy.service.consul    │
│                              → :5000    │
│  logs-collector.service.consul → :30006 │
└─────────────────────────────────────────┘
```

---

## Layer 1: CloudFormation

Provisioned by `e2b-setup-env.yml` (new VPC) or `e2b-setup-env-existing-vpc.yml` (existing VPC).

### VPC & Networking (18 resources)

| Resource | Type | Details |
|---|---|---|
| VPC | `AWS::EC2::VPC` | 10.0.0.0/16, DNS enabled |
| InternetGateway | `AWS::EC2::InternetGateway` | — |
| VPCGatewayAttachment | `AWS::EC2::VPCGatewayAttachment` | Attaches IGW to VPC |
| PublicSubnet1 | `AWS::EC2::Subnet` | 10.0.0.0/20, AZ-1, auto-assign public IP |
| PublicSubnet2 | `AWS::EC2::Subnet` | 10.0.16.0/20, AZ-2, auto-assign public IP |
| PrivateSubnet1 | `AWS::EC2::Subnet` | 10.0.32.0/20, AZ-1 |
| PrivateSubnet2 | `AWS::EC2::Subnet` | 10.0.48.0/20, AZ-2 |
| PublicRouteTable | `AWS::EC2::RouteTable` | — |
| PrivateRouteTable | `AWS::EC2::RouteTable` | — |
| PublicRoute | `AWS::EC2::Route` | 0.0.0.0/0 → IGW |
| PrivateRoute | `AWS::EC2::Route` | 0.0.0.0/0 → NAT GW |
| NatGatewayEIP | `AWS::EC2::EIP` | Static public IP for NAT |
| NatGateway | `AWS::EC2::NatGateway` | In PublicSubnet1 |
| PublicSubnet1RouteTableAssociation | `AWS::EC2::SubnetRouteTableAssociation` | — |
| PublicSubnet2RouteTableAssociation | `AWS::EC2::SubnetRouteTableAssociation` | — |
| PrivateSubnet1RouteTableAssociation | `AWS::EC2::SubnetRouteTableAssociation` | — |
| PrivateSubnet2RouteTableAssociation | `AWS::EC2::SubnetRouteTableAssociation` | — |
| S3VPCEndpoint | `AWS::EC2::VPCEndpoint` | Gateway endpoint for S3 (avoids NAT costs) |

### Security Groups (3 resources)

| Resource | Inbound | Source |
|---|---|---|
| BastionSecurityGroup | TCP 22 | AllowRemoteSSHIPs (default: 10.0.0.0/8) |
| DBSecurityGroup | TCP 5432 | VPC CIDR |
| RedisSecurityGroup | TCP 6379 | VPC CIDR |

All three allow unrestricted egress.

### Database (3 resources)

| Resource | Type | Details |
|---|---|---|
| DBSubnetGroup | `AWS::RDS::DBSubnetGroup` | PrivateSubnet1, PrivateSubnet2 |
| AuroraCluster | `AWS::RDS::DBCluster` | Aurora PostgreSQL 16.8, Serverless v2 (0.5–4 ACU), encrypted, deletion protection (prod) |
| AuroraInstance | `AWS::RDS::DBInstance` | db.serverless class |

### Cache (2 resources)

| Resource | Type | Details |
|---|---|---|
| RedisSubnetGroup | `AWS::ElastiCache::SubnetGroup` | PrivateSubnet1, PrivateSubnet2 |
| RedisServerless | `AWS::ElastiCache::ServerlessCache` | Redis engine, `{StackName}-redis` |

### S3 Buckets (2 resources)

| Resource | Naming Pattern | Purpose |
|---|---|---|
| TerraformS3Bucket | `terraform-{stack}-{region}-{account}` | Terraform state backend |
| SoftwareS3Bucket | `software-{stack}-{region}-{account}` | Orchestrator/template-manager binaries |

Both: versioning suspended, AES256 encryption, all public access blocked.

### IAM (2 resources)

| Resource | Details |
|---|---|
| EC2ServiceRole | Bastion role — S3, Secrets Manager, EC2/Packer, ASG, ELB, ECR, IAM (scoped to e2b*), CloudWatch, SSM, CloudFormation read |
| EC2InstanceProfile | Wraps EC2ServiceRole |

### Other (3 resources)

| Resource | Type | Details |
|---|---|---|
| WildcardCertificate | `AWS::CertificateManager::Certificate` | `*.{BaseDomain}`, DNS validation |
| DBPasswordParameter | `AWS::SSM::Parameter` | `e2b-{stack}-db-password` |
| BastionInstance | `AWS::EC2::Instance` | c6i.xlarge (x86) / c7g.xlarge (arm64), Ubuntu 22.04, 40GB gp3, runs full deployment on boot |

### CloudFormation Exports (21 values)

These are consumed by Terraform via variable substitution in `prepare.sh`:

| Export Name | Value |
|---|---|
| CFNSTACKNAME / AWSSTACKNAME | Stack name |
| CFNVPCID | VPC ID |
| CFNVPCCIDR | VPC CIDR block |
| CFNPUBLICACCESS | Public or Private |
| CFNPRIVATESUBNET1, CFNPRIVATESUBNET2 | Private subnet IDs |
| CFNPUBLICSUBNET1, CFNPUBLICSUBNET2 | Public subnet IDs |
| CFNTERRAFORMBUCKET | Terraform S3 bucket name |
| CFNSOFTWAREBUCKET | Software S3 bucket name |
| CFNSSHKEY | EC2 key pair name |
| CFNDBURL | Full PostgreSQL connection string |
| CFNDOMAIN | Base domain |
| CFNCERTARN | ACM certificate ARN |
| CFNREDISNAME | Redis cache name |
| CFNREDISURL | Redis endpoint address |
| CFNENVIRONMENT | prod or dev |
| CFNARCHITECTURE | x86_64 or arm64 |
| CFNCLIENTINSTANCETYPE | Client instance type |
| AWSREGION | Deployment region |

---

## Layer 2: Packer AMI

Built by `infra-iac/packer/main.pkr.hcl`. Produces the base AMI (`e2b-ubuntu-ami-*`) used by all Terraform launch templates.

### Base Image
- Ubuntu 22.04 (Jammy), HVM SSD
- x86_64: built on t3.xlarge
- ARM64: built on t4g.xlarge

### Installed Software

| Software | Version | Purpose |
|---|---|---|
| Docker | latest (official script) | Container runtime |
| Go | latest (snap) | Build toolchain |
| AWS CLI v2 | latest | AWS API access |
| Consul | 1.16.2 | Service discovery |
| Nomad | 1.6.2 | Workload orchestration |
| CloudWatch Agent | latest | Monitoring |
| s3fs-fuse | latest | S3 filesystem mount |
| bash-commons | 0.1.3 (gruntwork) | Shared shell utilities |
| Build tools | make, gcc, etc. | Compilation support |

### System Tuning
- `nf_conntrack_max = 2,097,152` (connection tracking)
- Increased open file limits
- Auto-update services disabled
- IMDSv2 enforced
- 10 GB gp3 encrypted root volume

---

## Layer 3: Terraform

Provisioned by `infra-iac/terraform/main.tf`. Uses S3 backend (TerraformS3Bucket from CFN).

### Auto Scaling Groups (4)

| ASG | Instance Type (prod x86 / prod arm) | Capacity (desired/min/max) | Subnets | EBS |
|---|---|---|---|---|
| server | m5.xlarge / m7g.xlarge | 3/3/3 | Private | 100 GB gp3 |
| client | var (c5.metal / c7g.metal) | 1/0/5 | Private | 300 GB + 500 GB gp3 |
| api | m6i.xlarge / m7g.xlarge | 1/1/1 | Private | 100 GB gp3 |
| build | var (c5.metal / c7g.metal) | 0/0/0 | Private | 100 GB gp3 |

Non-prod uses smaller instances: t3.xlarge (x86) / t4g.xlarge (arm64) for server and api.

### Application Load Balancer

| Resource | Details |
|---|---|
| ALB | `{prefix}-alb`, internal (private) or internet-facing (public), deletion protection in prod |
| HTTPS Listener | :443, TLS 1.3 policy, uses CFN wildcard cert |

**Routing Rules:**

| Priority | Host Header | Target Group | Port |
|---|---|---|---|
| default | `*` | client-proxy | 3002 |
| 10 | `api.{domain}` | e2b-api | 50001 |
| 20 | `docker.{domain}` | docker-proxy | 5000 |
| 30 | `nomad.{domain}` | nomad-server | 4646 |

### Security Groups (5)

| SG | Key Ingress | Purpose |
|---|---|---|
| server-sg | 8300-8302/tcp (VPC), 4646/tcp (0.0.0.0/0), all (VPC) | Consul + Nomad servers |
| client-sg | 8300-8302/tcp (VPC), 4646/tcp (VPC), all (VPC) | Firecracker client nodes |
| api-sg | 8300-8302/tcp (VPC), 4646/tcp (0.0.0.0/0), 50001/tcp (0.0.0.0/0), 3001-3002/tcp (VPC), all (VPC) | API + proxy nodes |
| alb-sg | 80/tcp (0.0.0.0/0), 443/tcp (0.0.0.0/0) | Load balancer |
| build-sg | 8300-8302/tcp (VPC), 4646/tcp (VPC), 5000/tcp (VPC), all (VPC) | Template build nodes |

### S3 Buckets (8)

| Bucket | Naming Pattern | Purpose | Force Destroy |
|---|---|---|---|
| loki_storage | `{prefix}-loki-storage-{account}` | Loki log archives | non-prod only |
| envs_docker_context | `{prefix}-envs-docker-context-{account}` | Environment Docker contexts | non-prod only |
| setup_bucket | `{prefix}-cluster-setup-{account}` | Consul/Nomad startup scripts | non-prod only |
| fc_kernels | `{prefix}-fc-kernels-{account}` | Firecracker kernel binaries | non-prod only |
| fc_versions | `{prefix}-fc-versions-{account}` | Firecracker VM binaries | non-prod only |
| fc_env_pipeline | `{prefix}-fc-env-pipeline-{account}` | envd builds | non-prod only |
| fc_template | `{prefix}-fc-template-{account}` | Firecracker VM templates | always |
| docker_contexts | `{prefix}-docker-contexts-{account}` | Docker build contexts | always |

### Secrets Manager (4)

| Secret | Naming Pattern | Purpose |
|---|---|---|
| consul_acl_token | `{prefix}-consul-secret-id` | Consul ACL bootstrap token |
| nomad_acl_token | `{prefix}-nomad-secret-id` | Nomad ACL bootstrap token |
| consul_gossip_encryption_key | `{prefix}-consul-gossip-key` | Consul gossip protocol encryption |
| consul_dns_request_token | `{prefix}-consul-dns-request-token` | Consul DNS query token |

### IAM (3)

| Resource | Details |
|---|---|
| infra-instances-role | EC2 trust, attached: S3FullAccess, ECRFullAccess, SecretsManagerReadWrite, SSMManagedInstanceCore, custom monitoring policy |
| monitoring-policy | CloudWatch metrics + logs, EC2 describe |
| ec2-instance-profile | Wraps infra-instances-role, used by all 4 launch templates |

### Other

| Resource | Details |
|---|---|
| CloudWatch Log Group | `{prefix}-cluster-logs`, 7 day retention |
| S3 Objects | Startup scripts uploaded to setup_bucket (run-consul, run-nomad, run-api-nomad, run-build-cluster-nomad) |

---

## Layer 4: Nomad Services

Scheduled by Nomad HCL files in `nomad/origin/`. Consul provides service discovery.

### Service Jobs (run on specific node pools)

| Service | Port | Protocol | Node Pool | Driver | Image Source | Memory | CPU | Priority |
|---|---|---|---|---|---|---|---|---|
| API | 50001 | HTTP (Gin) | api | Docker | ECR `e2b-orchestration/api` | 8192 MB | 4000 | 90 |
| Client Proxy | 3002, 3001 | HTTP | api | Docker | ECR `e2b-orchestration/client-proxy` | 1024 MB | 1000 | 80 |
| Docker Reverse Proxy | 5000 | HTTP | api | Docker | ECR `docker-reverse-proxy` | 512 MB | 256 | 85 |
| Redis | 6379 | TCP | api | Docker | `redis:7.4.2-alpine` | 2048 MB | 1000 | 95 |
| Loki | 3100 | HTTP | api | Docker | `grafana/loki:2.9.8` | 1024 MB | 500 | 75 |
| Template Manager | 5009 | gRPC | default | raw_exec | S3 (software bucket) | 1024 MB | 256 | 70 |

### System Jobs (run on all eligible nodes)

| Service | Ports | Node Pool | Driver | Image Source | Memory | CPU | Priority |
|---|---|---|---|---|---|---|---|
| Orchestrator | 5008 (gRPC) | all (system) | raw_exec | S3 (software bucket) | — | — | 90 |
| OTEL Collector | 4317, 4318, 8888, 13133 | all | Docker | `otel/opentelemetry-collector-contrib:0.130.0` | 1024 MB | 256 | 95 |
| Logs Collector (Vector) | 30006, 44313 | all | Docker | `timberio/vector:0.34.X-alpine` | 512 MB | 500 | 85 |

### In-VM

| Service | Protocol | Details |
|---|---|---|
| envd | gRPC | Runs inside each Firecracker microVM, manages filesystem and processes |

---

## Observability Stack

```
┌─────────────┐     ┌──────────────┐     ┌─────────────────┐
│ Application │     │ OTEL         │     │ Grafana Cloud   │
│ Services    │────▶│ Collector    │────▶│ (metrics,traces,│
│ (traces,    │gRPC │ :4317        │OTLP │  logs)          │
│  metrics)   │     └──────────────┘     └─────────────────┘
└─────────────┘
                    ┌──────────────┐     ┌─────────────────┐
┌─────────────┐     │ Logs         │     │ Loki            │
│ Application │────▶│ Collector    │────▶│ :3100           │──▶ S3
│ Services    │HTTP │ (Vector)     │HTTP │ (7-day retention│     (loki-storage)
│ (logs)      │     │ :30006       │     │  TSDB+S3)       │
└─────────────┘     └──────────────┘     └─────────────────┘

┌─────────────┐
│ Nomad       │─────▶ OTEL Collector ──▶ Grafana Cloud
│ Metrics     │ Prometheus scrape
│ :4646       │
└─────────────┘
```

- **Metrics/Traces**: Services → OTEL Collector (gRPC :4317) → Grafana Cloud (OTLP/HTTP)
- **Application Logs**: Services → Vector (:30006 NDJSON) → Loki (:3100) → S3
- **Nomad Metrics**: Prometheus scrape of :4646 → OTEL Collector → Grafana Cloud
- **Retention**: Loki keeps 7 days (168h), compaction every 10 minutes

---

## Security Model

### Network Boundaries

```
Internet ──▶ ALB (443 only) ──▶ Private Subnets
                                     │
Internet ──▶ Bastion (22) ──────────┘ (SSH jump)
                                     │
Private Subnets ──▶ NAT GW ──▶ Internet (outbound only)
Private Subnets ──▶ S3 Endpoint ──▶ S3 (no internet transit)
```

### Encryption
- **At rest**: All EBS volumes encrypted, S3 AES256, Aurora storage encryption
- **In transit**: ALB terminates TLS 1.3, internal services use plaintext (VPC-only)
- **Secrets**: Consul/Nomad tokens in Secrets Manager, DB password in SSM Parameter Store

### IAM Roles

| Role | Scope | Used By |
|---|---|---|
| EC2ServiceRole (CFN) | Bastion — S3 (e2b*/terraform-*/software-*), Secrets Manager (*e2b*), EC2/Packer, ASG, ELB, ECR, IAM (e2b*), CloudWatch, SSM, CFN read | Bastion instance |
| infra-instances-role (TF) | S3 Full, ECR Full, Secrets Manager R/W, SSM, CloudWatch | All server/client/api/build nodes |

### Instance Hardening
- IMDSv2 required (hop limit 1) on all instances and AMI
- Auto-update services disabled (controlled patching)
- Security groups restrict lateral movement by node role

---

## Resource Dependency Graph

Shows what must be deleted in what order for clean teardown:

```
                    ┌──────────────────┐
                    │  Nomad Jobs      │ ◄── Delete first
                    │  (9 services)    │
                    └────────┬─────────┘
                             │
                    ┌────────▼─────────┐
                    │  Terraform       │ ◄── terraform destroy
                    │  ASGs (4)        │     (deletes ASGs, ALB,
                    │  ALB + listeners │      SGs, secrets, S3,
                    │  SGs (5)         │      IAM, launch templates)
                    │  Secrets (4)     │
                    │  S3 Buckets (8)  │
                    │  IAM role/profile│
                    │  Launch Temps (4)│
                    │  CloudWatch      │
                    └────────┬─────────┘
                             │
                    ┌────────▼─────────┐
                    │  CloudFormation   │ ◄── delete-stack
                    │  VPC + Subnets   │     (must empty S3 first,
                    │  Aurora PG       │      disable deletion
                    │  ElastiCache     │      protection on Aurora)
                    │  S3 Buckets (2)  │
                    │  ACM Cert        │
                    │  Bastion         │
                    │  NAT GW + EIP    │
                    │  IAM role        │
                    └──────────────────┘
```

### Key Deletion Blockers
1. **Terraform ASGs** keep respawning instances — must destroy Terraform first
2. **ALB** holds references to ACM cert, subnets, and security groups
3. **Aurora deletion protection** is enabled in prod
4. **S3 buckets** must be emptied before CFN can delete them
5. **CFN exports** — if another stack imports them, delete is refused
6. **NAT Gateway** takes 5+ minutes to delete, blocks subnet deletion

---

## Complete Resource Index

Total resources by layer:

| Layer | Count | Lifecycle |
|---|---|---|
| CloudFormation | ~30 | `aws cloudformation delete-stack` |
| Terraform | ~45 | `terraform destroy` |
| Nomad | 9 jobs | `nomad job stop` |
| Packer | 1 AMI | `aws ec2 deregister-image` |
| **Total** | **~85+** | — |

### All S3 Buckets (10 total)

| Bucket | Created By | Purpose |
|---|---|---|
| `terraform-{stack}-{region}-{account}` | CFN | Terraform state |
| `software-{stack}-{region}-{account}` | CFN | Service binaries (orchestrator, template-manager) |
| `{prefix}-loki-storage-{account}` | TF | Loki log storage |
| `{prefix}-envs-docker-context-{account}` | TF | Environment Docker contexts |
| `{prefix}-cluster-setup-{account}` | TF | Consul/Nomad startup scripts |
| `{prefix}-fc-kernels-{account}` | TF | Firecracker kernels |
| `{prefix}-fc-versions-{account}` | TF | Firecracker VM binaries |
| `{prefix}-fc-env-pipeline-{account}` | TF | envd pipeline artifacts |
| `{prefix}-fc-template-{account}` | TF | Firecracker VM templates |
| `{prefix}-docker-contexts-{account}` | TF | Docker build contexts |

### All Security Groups (8 total)

| SG | Created By | Purpose |
|---|---|---|
| BastionSecurityGroup | CFN | SSH access to bastion |
| DBSecurityGroup | CFN | PostgreSQL access (5432) |
| RedisSecurityGroup | CFN | Redis access (6379) |
| server-sg | TF | Consul + Nomad server cluster |
| client-sg | TF | Firecracker client nodes |
| api-sg | TF | API, proxy, Nomad agent |
| alb-sg | TF | ALB ingress (80, 443) |
| build-sg | TF | Template build cluster |

### All IAM Roles (2 total)

| Role | Created By | Used By |
|---|---|---|
| EC2ServiceRole | CFN | Bastion |
| infra-instances-role | TF | All compute nodes (server, client, api, build) |

### All Secrets (5 total)

| Secret | Created By | Store |
|---|---|---|
| DB password | CFN | SSM Parameter (`e2b-{stack}-db-password`) |
| Consul ACL token | TF | Secrets Manager (`{prefix}-consul-secret-id`) |
| Nomad ACL token | TF | Secrets Manager (`{prefix}-nomad-secret-id`) |
| Consul gossip key | TF | Secrets Manager (`{prefix}-consul-gossip-key`) |
| Consul DNS token | TF | Secrets Manager (`{prefix}-consul-dns-request-token`) |

### All Ports

| Port | Service | Protocol | Exposed To |
|---|---|---|---|
| 22 | Bastion SSH | TCP | AllowRemoteSSHIPs |
| 80 | ALB HTTP | TCP | Internet (redirects) |
| 443 | ALB HTTPS | TCP | Internet |
| 3001 | Edge API (health) | HTTP | VPC |
| 3002 | Client Proxy | HTTP | ALB |
| 3100 | Loki | HTTP | VPC |
| 4317 | OTEL gRPC | gRPC | VPC |
| 4318 | OTEL HTTP | HTTP | VPC |
| 4646 | Nomad | HTTP | VPC (server SG: 0.0.0.0/0) |
| 5000 | Docker Reverse Proxy | HTTP | ALB |
| 5008 | Orchestrator | gRPC | VPC |
| 5009 | Template Manager | gRPC | VPC |
| 5432 | Aurora PostgreSQL | TCP | VPC |
| 6379 | Redis | TCP | VPC |
| 8300-8302 | Consul | TCP | VPC |
| 8600 | Consul DNS | UDP/TCP | localhost |
| 8888 | OTEL metrics | HTTP | VPC |
| 13133 | OTEL health | HTTP | VPC |
| 30006 | Vector logs ingestion | HTTP | VPC |
| 44313 | Vector health | HTTP | VPC |
| 50001 | API | HTTP | ALB |
