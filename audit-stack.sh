#!/bin/bash

# ==============================================================================
# CloudFormation Stack Deletion Blocker Audit
# ==============================================================================
# Identifies external dependencies preventing clean stack deletion.
# Run this BEFORE attempting stack delete to find and remove blockers.
# ==============================================================================

set -uo pipefail

# Trap for cleaner error reporting
trap 'echo -e "\n${RED}Script error on line $LINENO. Last command exited with status $?.${NC}"' ERR

STACK_NAME="${1:-e2b-2}"
REGION="${2:-us-west-2}"

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

BLOCKERS_FOUND=0

header() { echo -e "\n${BOLD}${CYAN}=== $1 ===${NC}"; }
warn()   { echo -e "  ${YELLOW}⚠  $1${NC}"; BLOCKERS_FOUND=$((BLOCKERS_FOUND + 1)); }
ok()     { echo -e "  ${GREEN}✓  $1${NC}"; }
info()   { echo -e "  ${CYAN}ℹ  $1${NC}"; }
blocker(){ echo -e "  ${RED}✖  BLOCKER: $1${NC}"; BLOCKERS_FOUND=$((BLOCKERS_FOUND + 1)); }

echo -e "${BOLD}CloudFormation Stack Deletion Audit${NC}"
echo -e "Stack: ${CYAN}${STACK_NAME}${NC}  Region: ${CYAN}${REGION}${NC}"
echo "======================================"

# ------------------------------------------------------------------
# 0. Stack status & previously failed resources
# ------------------------------------------------------------------
header "Stack Status"

STACK_STATUS=$(aws cloudformation describe-stacks \
  --region "$REGION" \
  --stack-name "$STACK_NAME" \
  --query 'Stacks[0].StackStatus' \
  --output text 2>/dev/null || echo "NOT_FOUND")

echo -e "  Status: ${BOLD}${STACK_STATUS}${NC}"

if [[ "$STACK_STATUS" == "DELETE_IN_PROGRESS" ]]; then
  warn "Stack deletion is already in progress — results may be incomplete"
  echo -e "    ${YELLOW}Wait for deletion to complete or fail before running this audit.${NC}"
  echo -e "    ${CYAN}aws cloudformation wait stack-delete-complete --region $REGION --stack-name $STACK_NAME${NC}"
fi

if [[ "$STACK_STATUS" == "NOT_FOUND" ]]; then
  echo -e "  ${GREEN}Stack not found — it may already be deleted.${NC}"
  exit 0
fi

if [[ "$STACK_STATUS" == *"FAILED"* || "$STACK_STATUS" == *"ROLLBACK"* ]]; then
  echo ""
  info "Resources in failed state:"
  aws cloudformation describe-stack-events \
    --region "$REGION" \
    --stack-name "$STACK_NAME" \
    --query "StackEvents[?ResourceStatus=='DELETE_FAILED'].[LogicalResourceId,ResourceType,ResourceStatusReason]" \
    --output table 2>/dev/null || true
fi

# Show already-deleted vs still-alive resources when in DELETE_FAILED state
if [[ "$STACK_STATUS" == "DELETE_FAILED" ]]; then
  echo ""
  info "Resource cleanup status (DELETE_FAILED stack):"
  DELETED_RESOURCES=$(aws cloudformation list-stack-resources \
    --region "$REGION" \
    --stack-name "$STACK_NAME" \
    --query "StackResourceSummaries[?ResourceStatus=='DELETE_COMPLETE'].[LogicalResourceId,ResourceType]" \
    --output text 2>/dev/null || echo "")
  ALIVE_RESOURCES=$(aws cloudformation list-stack-resources \
    --region "$REGION" \
    --stack-name "$STACK_NAME" \
    --query "StackResourceSummaries[?ResourceStatus!='DELETE_COMPLETE'].[LogicalResourceId,ResourceType,ResourceStatus]" \
    --output text 2>/dev/null || echo "")

  if [[ -n "$DELETED_RESOURCES" ]]; then
    ok "Already cleaned up:"
    while IFS=$'\t' read -r res_id res_type; do
      [[ -z "$res_id" ]] && continue
      echo -e "         ${GREEN}✓${NC} ${res_id} (${res_type})"
    done <<< "$DELETED_RESOURCES"
  fi
  if [[ -n "$ALIVE_RESOURCES" ]]; then
    echo ""
    warn "Still present (need attention):"
    while IFS=$'\t' read -r res_id res_type res_status; do
      [[ -z "$res_id" ]] && continue
      echo -e "         ${RED}●${NC} ${res_id} (${res_type}) — ${res_status}"
    done <<< "$ALIVE_RESOURCES"
  fi
fi

# Helper: get physical resource ID from logical ID
get_physical_id() {
  aws cloudformation describe-stack-resource \
    --region "$REGION" \
    --stack-name "$STACK_NAME" \
    --logical-resource-id "$1" \
    --query 'StackResourceDetail.PhysicalResourceId' \
    --output text 2>/dev/null || echo ""
}

# ------------------------------------------------------------------
# 1. CloudFormation Export Dependencies
# ------------------------------------------------------------------
header "CloudFormation Export Dependencies"

CFN_EXPORTS=(
  CFNSTACKNAME CFNVPCID CFNVPCCIDR CFNPUBLICACCESS
  CFNPRIVATESUBNET1 CFNPRIVATESUBNET2 CFNPUBLICSUBNET1 CFNPUBLICSUBNET2
  CFNTERRAFORMBUCKET CFNSOFTWAREBUCKET CFNSSHKEY CFNDBURL
  CFNDOMAIN CFNCERTARN CFNREDISNAME CFNREDISURL
  CFNENVIRONMENT CFNARCHITECTURE CFNCLIENTINSTANCETYPE
  AWSREGION AWSSTACKNAME
)

EXPORT_BLOCKERS=0
for EXPORT_NAME in "${CFN_EXPORTS[@]}"; do
  IMPORTERS=$(aws cloudformation list-imports \
    --region "$REGION" \
    --export-name "$EXPORT_NAME" \
    --query 'Imports' \
    --output text 2>/dev/null || echo "")
  if [[ -n "$IMPORTERS" && "$IMPORTERS" != "None" ]]; then
    blocker "Export '${EXPORT_NAME}' is imported by: ${IMPORTERS}"
    EXPORT_BLOCKERS=$((EXPORT_BLOCKERS + 1))
  fi
done

if [[ "$EXPORT_BLOCKERS" -eq 0 ]]; then
  ok "No other stacks importing this stack's exports"
else
  echo -e "    ${YELLOW}FIX: Delete or update the importing stacks before deleting this stack${NC}"
fi

# ------------------------------------------------------------------
# 2. ACM Certificates — check what's using them
# ------------------------------------------------------------------
header "ACM Certificates"

CERT_ARN=$(get_physical_id "WildcardCertificate")
if [[ -n "$CERT_ARN" && "$CERT_ARN" != "None" ]]; then
  info "Certificate: $CERT_ARN"
  IN_USE_BY=$(aws acm describe-certificate \
    --region "$REGION" \
    --certificate-arn "$CERT_ARN" \
    --query 'Certificate.InUseBy' \
    --output json 2>/dev/null || echo "[]")

  if [[ "$IN_USE_BY" != "[]" ]]; then
    blocker "Certificate is in use by:"
    echo "$IN_USE_BY" | python3 -c "import sys,json; [print(f'         → {r}') for r in json.load(sys.stdin)]" 2>/dev/null || echo "         $IN_USE_BY"
    echo -e "    ${YELLOW}FIX: Detach from the above resources, or use --retain-resources WildcardCertificate${NC}"
  else
    ok "Certificate not in use — safe to delete"
  fi
else
  ok "No certificate found in stack"
fi

# ------------------------------------------------------------------
# 3. Security Groups — check for external ENIs attached
# ------------------------------------------------------------------
header "Security Groups"

for SG_LOGICAL in BastionSecurityGroup DBSecurityGroup RedisSecurityGroup; do
  SG_ID=$(get_physical_id "$SG_LOGICAL")
  if [[ -z "$SG_ID" || "$SG_ID" == "None" ]]; then
    continue
  fi

  info "Checking $SG_LOGICAL ($SG_ID)"

  # Find ENIs using this SG that are NOT managed by CloudFormation
  ENIS=$(aws ec2 describe-network-interfaces \
    --region "$REGION" \
    --filters "Name=group-id,Values=$SG_ID" \
    --query 'NetworkInterfaces[*].[NetworkInterfaceId,InterfaceType,Description,Attachment.InstanceId]' \
    --output text 2>/dev/null || echo "")

  if [[ -n "$ENIS" ]]; then
    blocker "$SG_LOGICAL ($SG_ID) has attached ENIs:"
    while IFS=$'\t' read -r eni_id eni_type eni_desc eni_instance; do
      echo -e "         → ${eni_id}  type=${eni_type}  instance=${eni_instance:-none}"
      echo -e "           desc: ${eni_desc}"
    done <<< "$ENIS"
    echo -e "    ${YELLOW}FIX: Delete/detach the above ENIs or their parent resources first${NC}"
  else
    ok "$SG_LOGICAL — no external ENIs"
  fi

  # Check for ingress/egress rules referencing other SGs outside the stack
  REFERENCED_SGS=$(aws ec2 describe-security-groups \
    --region "$REGION" \
    --group-ids "$SG_ID" \
    --query 'SecurityGroups[0].IpPermissions[*].UserIdGroupPairs[*].GroupId' \
    --output text 2>/dev/null || echo "")

  for REF_SG in $REFERENCED_SGS; do
    if [[ "$REF_SG" != "$SG_ID" ]]; then
      # Check if this referenced SG is also in our stack
      IN_STACK=$(aws cloudformation describe-stack-resources \
        --region "$REGION" \
        --stack-name "$STACK_NAME" \
        --query "StackResources[?PhysicalResourceId=='${REF_SG}'].LogicalResourceId" \
        --output text 2>/dev/null || echo "")
      if [[ -z "$IN_STACK" ]]; then
        warn "$SG_LOGICAL references external SG: $REF_SG (not in stack)"
      fi
    fi
  done
done

# ------------------------------------------------------------------
# 4. VPC — check for resources created outside the stack
# ------------------------------------------------------------------
header "VPC External Resources"

VPC_ID=$(get_physical_id "VPC")
if [[ -n "$VPC_ID" && "$VPC_ID" != "None" ]]; then
  info "VPC: $VPC_ID"

  # ELBv2 (ALBs/NLBs) in the VPC
  ELBS=$(aws elbv2 describe-load-balancers \
    --region "$REGION" \
    --query "LoadBalancers[?VpcId=='${VPC_ID}'].[LoadBalancerArn,LoadBalancerName,Type]" \
    --output text 2>/dev/null || echo "")
  if [[ -n "$ELBS" ]]; then
    blocker "Load balancers (v2) found in VPC (likely holding SGs/subnets/certs):"
    while IFS=$'\t' read -r lb_arn lb_name lb_type; do
      echo -e "         → ${lb_name} (${lb_type})"
      echo -e "           ${lb_arn}"
      # Check if this LB uses our certificate
      LISTENERS=$(aws elbv2 describe-listeners \
        --region "$REGION" \
        --load-balancer-arn "$lb_arn" \
        --query 'Listeners[*].Certificates[*].CertificateArn' \
        --output text 2>/dev/null || echo "")
      if [[ -n "$LISTENERS" && "$LISTENERS" == *"$CERT_ARN"* ]]; then
        echo -e "           ${RED}↳ Uses stack certificate!${NC}"
      fi
    done <<< "$ELBS"
    echo -e "    ${YELLOW}FIX: Delete these load balancers before stack deletion${NC}"
  else
    ok "No v2 load balancers in VPC"
  fi

  # Classic ELBs in the VPC
  CLASSIC_ELBS=$(aws elb describe-load-balancers \
    --region "$REGION" \
    --query "LoadBalancerDescriptions[?VPCId=='${VPC_ID}'].[LoadBalancerName,DNSName]" \
    --output text 2>/dev/null || echo "")
  if [[ -n "$CLASSIC_ELBS" ]]; then
    blocker "Classic load balancers found in VPC:"
    while IFS=$'\t' read -r clb_name clb_dns; do
      echo -e "         → ${clb_name} (${clb_dns})"
    done <<< "$CLASSIC_ELBS"
    echo -e "    ${YELLOW}FIX: Delete these classic load balancers before stack deletion${NC}"
  else
    ok "No classic load balancers in VPC"
  fi

  # NAT Gateway state check
  NAT_GWS=$(aws ec2 describe-nat-gateways \
    --region "$REGION" \
    --filter "Name=vpc-id,Values=$VPC_ID" \
    --query 'NatGateways[*].[NatGatewayId,State,SubnetId]' \
    --output text 2>/dev/null || echo "")
  if [[ -n "$NAT_GWS" ]]; then
    while IFS=$'\t' read -r nat_id nat_state nat_subnet; do
      [[ -z "$nat_id" ]] && continue
      if [[ "$nat_state" == "deleting" ]]; then
        warn "NAT Gateway $nat_id is still deleting (blocks subnet $nat_subnet deletion) — wait for completion"
      elif [[ "$nat_state" == "pending" ]]; then
        warn "NAT Gateway $nat_id is pending — wait for it to become available before deleting"
      elif [[ "$nat_state" == "available" ]]; then
        info "NAT Gateway $nat_id is available (state: $nat_state)"
      elif [[ "$nat_state" == "deleted" ]]; then
        ok "NAT Gateway $nat_id already deleted"
      fi
    done <<< "$NAT_GWS"
  fi

  # EC2 instances (non-bastion) in the VPC
  BASTION_ID=$(get_physical_id "BastionInstance")
  INSTANCES=$(aws ec2 describe-instances \
    --region "$REGION" \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=instance-state-name,Values=running,stopped" \
    --query 'Reservations[*].Instances[*].[InstanceId,InstanceType,Tags[?Key==`Name`].Value | [0]]' \
    --output text 2>/dev/null || echo "")
  NON_STACK_INSTANCES=""
  while IFS=$'\t' read -r inst_id inst_type inst_name; do
    if [[ -n "$inst_id" && "$inst_id" != "$BASTION_ID" ]]; then
      NON_STACK_INSTANCES+="         → ${inst_id}  ${inst_type}  ${inst_name:-unnamed}\n"
    fi
  done <<< "$INSTANCES"
  if [[ -n "$NON_STACK_INSTANCES" ]]; then
    blocker "Non-stack EC2 instances in VPC:"
    echo -e "$NON_STACK_INSTANCES"
    echo -e "    ${YELLOW}FIX: These are likely managed by Auto Scaling Groups — see ASG check below${NC}"
  else
    ok "No non-stack EC2 instances in VPC"
  fi

  # Auto Scaling Groups — the #1 reason instances keep respawning
  SUBNET_IDS=$(aws ec2 describe-subnets \
    --region "$REGION" \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --query 'Subnets[*].SubnetId' \
    --output text 2>/dev/null || echo "")

  ALL_ASGS=$(aws autoscaling describe-auto-scaling-groups \
    --region "$REGION" \
    --query 'AutoScalingGroups[*].[AutoScalingGroupName,MinSize,DesiredCapacity,MaxSize,length(Instances),LaunchTemplate.LaunchTemplateId,VPCZoneIdentifier]' \
    --output text 2>/dev/null || echo "")

  VPC_ASGS=""
  while IFS=$'\t' read -r asg_name asg_min asg_desired asg_max asg_count asg_lt asg_subnets; do
    [[ -z "$asg_name" ]] && continue
    # Check if any of the ASG's subnets are in our VPC
    for subnet in $SUBNET_IDS; do
      if [[ "$asg_subnets" == *"$subnet"* ]]; then
        VPC_ASGS+="${asg_name}\t${asg_min}\t${asg_desired}\t${asg_max}\t${asg_count}\t${asg_lt}\n"
        break
      fi
    done
  done <<< "$ALL_ASGS"

  if [[ -n "$VPC_ASGS" ]]; then
    blocker "Auto Scaling Groups in VPC (these respawn terminated instances!):"
    echo -e "         ${BOLD}Name                                     Min  Desired  Max  Running  LaunchTemplate${NC}"
    while IFS=$'\t' read -r asg_name asg_min asg_desired asg_max asg_count asg_lt; do
      [[ -z "$asg_name" ]] && continue
      echo -e "         → ${asg_name}  ${asg_min}  ${asg_desired}  ${asg_max}  ${asg_count}  ${asg_lt}"
    done <<< "$(echo -e "$VPC_ASGS")"
    echo ""
    echo -e "    ${YELLOW}FIX (option A — scale to zero then delete):${NC}"
    while IFS=$'\t' read -r asg_name asg_min asg_desired asg_max asg_count asg_lt; do
      [[ -z "$asg_name" ]] && continue
      echo -e "    ${CYAN}aws autoscaling delete-auto-scaling-group --region $REGION --auto-scaling-group-name \"${asg_name}\" --force-delete${NC}"
    done <<< "$(echo -e "$VPC_ASGS")"
    echo ""
    echo -e "    ${YELLOW}FIX (option B — if Terraform-managed, destroy from Terraform first):${NC}"
    echo -e "    ${CYAN}cd infra-iac/terraform && terraform destroy -auto-approve${NC}"
  else
    ok "No Auto Scaling Groups in VPC"
  fi

  # Launch Templates — orphaned templates can reference VPC security groups
  LT_IDS=""
  while IFS=$'\t' read -r asg_name asg_min asg_desired asg_max asg_count asg_lt; do
    [[ -z "$asg_lt" || "$asg_lt" == "None" ]] && continue
    LT_IDS+="$asg_lt "
  done <<< "$(echo -e "$VPC_ASGS")"

  if [[ -n "$LT_IDS" ]]; then
    info "Launch Templates used by VPC ASGs:"
    for lt_id in $LT_IDS; do
      LT_NAME=$(aws ec2 describe-launch-templates \
        --region "$REGION" \
        --launch-template-ids "$lt_id" \
        --query 'LaunchTemplates[0].[LaunchTemplateName,DefaultVersionNumber]' \
        --output text 2>/dev/null || echo "unknown")
      echo -e "         → ${lt_id}  ${LT_NAME}"
    done
    echo -e "    ${YELLOW}FIX: After deleting ASGs, clean up launch templates:${NC}"
    for lt_id in $LT_IDS; do
      echo -e "    ${CYAN}aws ec2 delete-launch-template --region $REGION --launch-template-id ${lt_id}${NC}"
    done
  fi

  # Terraform state check — warn if Terraform resources exist
  TF_BUCKET=$(get_physical_id "TerraformS3Bucket")
  if [[ -n "$TF_BUCKET" && "$TF_BUCKET" != "None" ]]; then
    TF_STATE_EXISTS=$(aws s3api list-objects-v2 \
      --region "$REGION" \
      --bucket "$TF_BUCKET" \
      --prefix "terraform" \
      --max-items 1 \
      --query 'KeyCount' \
      --output text 2>/dev/null || echo "0")
    if [[ "$TF_STATE_EXISTS" -gt 0 ]]; then
      warn "Terraform state found in $TF_BUCKET — Terraform-managed resources likely exist"
      echo -e "    ${YELLOW}FIX: Run 'terraform destroy' before deleting the CFN stack to cleanly remove ASGs, instances, etc.${NC}"
    fi
  fi

  # Lambda ENIs in the VPC
  LAMBDA_ENIS=$(aws ec2 describe-network-interfaces \
    --region "$REGION" \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=interface-type,Values=lambda" \
    --query 'NetworkInterfaces[*].[NetworkInterfaceId,Description]' \
    --output text 2>/dev/null || echo "")
  if [[ -n "$LAMBDA_ENIS" ]]; then
    warn "Lambda ENIs in VPC (these can block subnet deletion):"
    while IFS=$'\t' read -r eni_id eni_desc; do
      echo -e "         → ${eni_id}: ${eni_desc}"
    done <<< "$LAMBDA_ENIS"
    echo -e "    ${YELLOW}FIX: Delete the Lambda functions using this VPC, then wait ~20min for ENI cleanup${NC}"
  else
    ok "No Lambda ENIs in VPC"
  fi

  # Any other ENIs in the VPC not managed by the stack
  ALL_ENIS=$(aws ec2 describe-network-interfaces \
    --region "$REGION" \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --query 'NetworkInterfaces[*].[NetworkInterfaceId,InterfaceType,Description,Status]' \
    --output text 2>/dev/null || echo "")
  ENI_COUNT=$(echo "$ALL_ENIS" | grep -c '[a-z]' || true)
  if [[ "$ENI_COUNT" -gt 0 ]]; then
    info "Total ENIs in VPC: $ENI_COUNT"
    while IFS=$'\t' read -r eni_id eni_type eni_desc eni_status; do
      if [[ "$eni_status" == "in-use" ]]; then
        echo -e "         → ${eni_id}  type=${eni_type}  status=${eni_status}"
        echo -e "           ${eni_desc}"
      fi
    done <<< "$ALL_ENIS"
  fi

  # VPC Peering connections
  PEERINGS=$(aws ec2 describe-vpc-peering-connections \
    --region "$REGION" \
    --filters "Name=requester-vpc-info.vpc-id,Values=$VPC_ID" \
    --query 'VpcPeeringConnections[*].[VpcPeeringConnectionId,Status.Code]' \
    --output text 2>/dev/null || echo "")
  if [[ -n "$PEERINGS" ]]; then
    warn "VPC peering connections found:"
    echo "         $PEERINGS"
  fi

else
  ok "No VPC found in stack"
fi

# ------------------------------------------------------------------
# 5. Terraform-Created Resources (outside CFN)
# ------------------------------------------------------------------
header "Terraform-Created Resources"

if [[ -n "${VPC_ID:-}" && "$VPC_ID" != "None" ]]; then
  # Get the stack name prefix for resource naming patterns
  PREFIX="$STACK_NAME"

  # Terraform-created S3 buckets (by common prefix patterns)
  info "Checking for Terraform-managed S3 buckets..."
  TF_BUCKETS=$(aws s3api list-buckets \
    --query "Buckets[?starts_with(Name, '${PREFIX}')].Name" \
    --output text 2>/dev/null || echo "")
  if [[ -n "$TF_BUCKETS" ]]; then
    for bucket in $TF_BUCKETS; do
      # Skip CFN-managed buckets
      CFN_BUCKET=$(aws cloudformation describe-stack-resources \
        --region "$REGION" \
        --stack-name "$STACK_NAME" \
        --query "StackResources[?PhysicalResourceId=='${bucket}'].LogicalResourceId" \
        --output text 2>/dev/null || echo "")
      if [[ -z "$CFN_BUCKET" ]]; then
        BUCKET_OBJECTS=$(aws s3api list-objects-v2 \
          --region "$REGION" \
          --bucket "$bucket" \
          --max-items 1 \
          --query 'KeyCount' \
          --output text 2>/dev/null || echo "0")
        if [[ "$BUCKET_OBJECTS" -gt 0 ]]; then
          warn "Terraform S3 bucket '${bucket}' exists and is non-empty"
        else
          info "Terraform S3 bucket '${bucket}' exists (empty)"
        fi
      fi
    done
  else
    ok "No Terraform-managed S3 buckets found with prefix '${PREFIX}'"
  fi

  # Secrets Manager secrets created by Terraform
  info "Checking for Terraform-managed secrets..."
  TF_SECRETS=$(aws secretsmanager list-secrets \
    --region "$REGION" \
    --filters "Key=name,Values=${PREFIX}" \
    --query 'SecretList[*].[Name,ARN]' \
    --output text 2>/dev/null || echo "")
  if [[ -n "$TF_SECRETS" ]]; then
    warn "Secrets Manager secrets found with stack prefix:"
    while IFS=$'\t' read -r secret_name secret_arn; do
      [[ -z "$secret_name" ]] && continue
      echo -e "         → ${secret_name}"
    done <<< "$TF_SECRETS"
    echo -e "    ${YELLOW}FIX: Run 'terraform destroy' or manually delete these secrets${NC}"
  else
    ok "No Terraform-managed secrets found"
  fi

  # Non-stack security groups in the VPC (created by Terraform/Nomad)
  info "Checking for non-stack security groups in VPC..."
  ALL_VPC_SGS=$(aws ec2 describe-security-groups \
    --region "$REGION" \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --query 'SecurityGroups[*].[GroupId,GroupName,Description]' \
    --output text 2>/dev/null || echo "")
  NON_STACK_SGS=""
  while IFS=$'\t' read -r sg_id sg_name sg_desc; do
    [[ -z "$sg_id" ]] && continue
    # Check if this SG is managed by CloudFormation
    IN_STACK=$(aws cloudformation describe-stack-resources \
      --region "$REGION" \
      --stack-name "$STACK_NAME" \
      --query "StackResources[?PhysicalResourceId=='${sg_id}'].LogicalResourceId" \
      --output text 2>/dev/null || echo "")
    if [[ -z "$IN_STACK" && "$sg_name" != "default" ]]; then
      NON_STACK_SGS+="         → ${sg_id}  ${sg_name}: ${sg_desc}\n"
    fi
  done <<< "$ALL_VPC_SGS"
  if [[ -n "$NON_STACK_SGS" ]]; then
    warn "Non-stack security groups in VPC (likely Terraform-created):"
    echo -e "$NON_STACK_SGS"
    echo -e "    ${YELLOW}FIX: Run 'terraform destroy' or manually delete these SGs${NC}"
  else
    ok "No non-stack security groups in VPC"
  fi

  # ECR repositories
  info "Checking for ECR repositories..."
  ECR_REPOS=$(aws ecr describe-repositories \
    --region "$REGION" \
    --query "repositories[?starts_with(repositoryName, '${PREFIX}')].[repositoryName,repositoryUri]" \
    --output text 2>/dev/null || echo "")
  if [[ -n "$ECR_REPOS" ]]; then
    warn "ECR repositories found with stack prefix:"
    while IFS=$'\t' read -r repo_name repo_uri; do
      [[ -z "$repo_name" ]] && continue
      IMAGE_COUNT=$(aws ecr list-images \
        --region "$REGION" \
        --repository-name "$repo_name" \
        --query 'length(imageIds)' \
        --output text 2>/dev/null || echo "0")
      echo -e "         → ${repo_name} (${IMAGE_COUNT} images)"
    done <<< "$ECR_REPOS"
    echo -e "    ${YELLOW}FIX: Delete ECR repos: aws ecr delete-repository --region $REGION --repository-name <name> --force${NC}"
  else
    ok "No ECR repositories found with prefix '${PREFIX}'"
  fi
else
  info "Skipped (no VPC found)"
fi

# ------------------------------------------------------------------
# 6. S3 Buckets — must be empty to delete
# ------------------------------------------------------------------
header "S3 Buckets (CFN-managed)"

for BUCKET_LOGICAL in SoftwareS3Bucket TerraformS3Bucket; do
  BUCKET_NAME=$(get_physical_id "$BUCKET_LOGICAL")
  if [[ -z "$BUCKET_NAME" || "$BUCKET_NAME" == "None" ]]; then
    continue
  fi

  info "Checking $BUCKET_LOGICAL ($BUCKET_NAME)"

  OBJECT_COUNT=$(aws s3api list-objects-v2 \
    --region "$REGION" \
    --bucket "$BUCKET_NAME" \
    --max-items 1 \
    --query 'KeyCount' \
    --output text 2>/dev/null || echo "error")

  if [[ "$OBJECT_COUNT" == "error" ]]; then
    warn "Could not access bucket $BUCKET_NAME (may already be deleted)"
  elif [[ "$OBJECT_COUNT" -gt 0 ]]; then
    blocker "Bucket $BUCKET_NAME is NOT empty"

    TOTAL=$(aws s3api list-objects-v2 \
      --region "$REGION" \
      --bucket "$BUCKET_NAME" \
      --query 'length(Contents)' \
      --output text 2>/dev/null || echo "unknown")
    echo -e "         Objects: ~${TOTAL}"

    # Check for versioning
    VERSIONING=$(aws s3api get-bucket-versioning \
      --region "$REGION" \
      --bucket "$BUCKET_NAME" \
      --query 'Status' \
      --output text 2>/dev/null || echo "")
    if [[ "$VERSIONING" == "Enabled" ]]; then
      echo -e "         ${YELLOW}Versioning is ENABLED — must delete all versions too${NC}"
      echo -e "    ${YELLOW}FIX (recommended): aws s3 rb s3://${BUCKET_NAME} --force${NC}"
      echo -e "    ${YELLOW}If that fails (>1000 versions), use a paginated approach:${NC}"
      echo -e "    ${CYAN}aws s3api list-object-versions --bucket ${BUCKET_NAME} --output json | \\${NC}"
      echo -e "    ${CYAN}  python3 -c \"import sys,json; d=json.load(sys.stdin); \\${NC}"
      echo -e "    ${CYAN}  [print(v['Key'],v['VersionId']) for v in d.get('Versions',[])+d.get('DeleteMarkers',[])]\" | \\${NC}"
      echo -e "    ${CYAN}  while read key vid; do aws s3api delete-object --bucket ${BUCKET_NAME} --key \\\"\\\$key\\\" --version-id \\\"\\\$vid\\\"; done${NC}"
    else
      echo -e "    ${YELLOW}FIX: aws s3 rm s3://${BUCKET_NAME} --recursive${NC}"
    fi
  else
    ok "$BUCKET_LOGICAL is empty — safe to delete"
  fi
done

# ------------------------------------------------------------------
# 7. RDS / Aurora — check for deletion protection & snapshots
# ------------------------------------------------------------------
header "RDS / Aurora Database"

CLUSTER_ID=$(get_physical_id "AuroraCluster")
if [[ -n "$CLUSTER_ID" && "$CLUSTER_ID" != "None" ]]; then
  info "Cluster: $CLUSTER_ID"

  DEL_PROTECTION=$(aws rds describe-db-clusters \
    --region "$REGION" \
    --db-cluster-identifier "$CLUSTER_ID" \
    --query 'DBClusters[0].DeletionProtection' \
    --output text 2>/dev/null || echo "unknown")

  if [[ "$DEL_PROTECTION" == "True" ]]; then
    blocker "Aurora cluster has deletion protection ENABLED"
    echo -e "    ${YELLOW}FIX: aws rds modify-db-cluster --db-cluster-identifier ${CLUSTER_ID} --no-deletion-protection --apply-immediately --region ${REGION}${NC}"
  else
    ok "Deletion protection is off"
  fi

  # Check for DB instances
  DB_INSTANCES=$(aws rds describe-db-instances \
    --region "$REGION" \
    --filters "Name=db-cluster-id,Values=$CLUSTER_ID" \
    --query 'DBInstances[*].[DBInstanceIdentifier,DBInstanceStatus,DeletionProtection]' \
    --output text 2>/dev/null || echo "")
  if [[ -n "$DB_INSTANCES" ]]; then
    while IFS=$'\t' read -r db_id db_status db_del_prot; do
      if [[ "$db_del_prot" == "True" ]]; then
        blocker "DB instance $db_id has deletion protection enabled"
        echo -e "    ${YELLOW}FIX: aws rds modify-db-instance --db-instance-identifier ${db_id} --no-deletion-protection --apply-immediately --region ${REGION}${NC}"
      else
        info "DB instance $db_id — status: $db_status, deletion protection: off"
      fi
    done <<< "$DB_INSTANCES"
  fi
else
  ok "No Aurora cluster found in stack"
fi

# ------------------------------------------------------------------
# 8. ElastiCache — check serverless cache
# ------------------------------------------------------------------
header "ElastiCache"

CACHE_ID=$(get_physical_id "RedisServerless")
if [[ -n "$CACHE_ID" && "$CACHE_ID" != "None" ]]; then
  info "Serverless cache: $CACHE_ID"
  CACHE_STATUS=$(aws elasticache describe-serverless-caches \
    --region "$REGION" \
    --serverless-cache-name "$CACHE_ID" \
    --query 'ServerlessCaches[0].Status' \
    --output text 2>/dev/null || echo "not-found")
  if [[ "$CACHE_STATUS" != "not-found" ]]; then
    info "Status: $CACHE_STATUS"
    if [[ "$CACHE_STATUS" == "deleting" ]]; then
      warn "Cache is still deleting — wait for completion before retrying stack delete"
    fi
  fi
else
  ok "No ElastiCache found in stack"
fi

# ------------------------------------------------------------------
# 9. IAM Role — check for extra policies or instance profiles
# ------------------------------------------------------------------
header "IAM Resources"

ROLE_NAME=$(get_physical_id "BastionRole")
if [[ -n "$ROLE_NAME" && "$ROLE_NAME" != "None" ]]; then
  info "Role: $ROLE_NAME"

  # Check for attached policies not in the template
  ATTACHED_POLICIES=$(aws iam list-attached-role-policies \
    --role-name "$ROLE_NAME" \
    --query 'AttachedPolicies[*].PolicyArn' \
    --output text 2>/dev/null || echo "")
  if [[ -n "$ATTACHED_POLICIES" ]]; then
    info "Attached managed policies:"
    for pol in $ATTACHED_POLICIES; do
      echo -e "         → $pol"
    done
  fi

  # Check for inline policies not in the template
  INLINE_POLICIES=$(aws iam list-role-policies \
    --role-name "$ROLE_NAME" \
    --query 'PolicyNames' \
    --output text 2>/dev/null || echo "")
  if [[ -n "$INLINE_POLICIES" ]]; then
    info "Inline policies: $INLINE_POLICIES"
  fi
else
  ok "No IAM role found in stack"
fi

# ------------------------------------------------------------------
# 10. EIP — check if associated outside the stack
# ------------------------------------------------------------------
header "Elastic IPs"

EIP_ALLOC=$(get_physical_id "NatGatewayEIP")
if [[ -n "$EIP_ALLOC" && "$EIP_ALLOC" != "None" ]]; then
  info "EIP allocation: $EIP_ALLOC"
  EIP_ASSOC=$(aws ec2 describe-addresses \
    --region "$REGION" \
    --allocation-ids "$EIP_ALLOC" \
    --query 'Addresses[0].[AssociationId,InstanceId,NetworkInterfaceId]' \
    --output text 2>/dev/null || echo "")
  if [[ -n "$EIP_ASSOC" && "$EIP_ASSOC" != "None	None	None" ]]; then
    info "EIP association: $EIP_ASSOC"
  else
    ok "EIP is not associated with external resources"
  fi
else
  ok "No EIP found in stack"
fi

# ------------------------------------------------------------------
# 11. Full resource status dump
# ------------------------------------------------------------------
header "All Stack Resources Status"

aws cloudformation list-stack-resources \
  --region "$REGION" \
  --stack-name "$STACK_NAME" \
  --query 'StackResourceSummaries[*].[ResourceStatus,LogicalResourceId,ResourceType,PhysicalResourceId]' \
  --output table 2>/dev/null || echo "Could not list stack resources"

# ------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------
echo ""
echo "======================================"
if [[ "$BLOCKERS_FOUND" -gt 0 ]]; then
  echo -e "${RED}${BOLD}Found $BLOCKERS_FOUND potential blocker(s) / warning(s).${NC}"
  echo -e "Fix the items marked with ${RED}✖${NC} and ${YELLOW}⚠${NC} above, then retry:"
  echo -e "  ${CYAN}aws cloudformation delete-stack --region $REGION --stack-name $STACK_NAME${NC}"
  echo ""
  echo "If a resource still won't delete, skip it:"
  echo -e "  ${CYAN}aws cloudformation delete-stack --region $REGION --stack-name $STACK_NAME --retain-resources <LogicalId1> <LogicalId2>${NC}"
else
  echo -e "${GREEN}${BOLD}No blockers found — stack should delete cleanly.${NC}"
fi
