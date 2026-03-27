#!/bin/bash

# ==============================================================================
# E2B CloudFormation Deployment Script
# ==============================================================================

# 1. Core Stack Configuration
STACK_NAME="e2b-4"
TEMPLATE_FILE="e2b-setup-env.yml"
REGION="us-west-2" # Change to your preferred AWS region

# 2. Required Parameters (YOU MUST CHANGE THESE)
# Must be an existing EC2 Key Pair in your AWS Region for Bastion SSH access
KEY_NAME="niko@sys" 

# Must be a valid domain structure (e.g., e2b.yourdomain.com)
BASE_DOMAIN="e2b.bluenexus.ai" 

# 3. Architecture & Environment
ENVIRONMENT="dev"         # Allowed: dev | prod
ARCHITECTURE="x86_64"     # Allowed: x86_64 | arm64
CLIENT_INSTANCE_TYPE=""   # Leave empty to default to c5.metal (x86) or c7g.metal (arm)

# 4. Security & Access
# The template defaults to 10.0.0.0/8, but 0.0.0.0/0 allows you to SSH from anywhere. 
# For production, lock this down to your specific IP (e.g., "203.0.113.50/32")
ALLOW_SSH_IPS="98.97.34.226/32"

# 5. Database Credentials 
DB_USER="e2badmin"
# Password constraint: 8-30 chars, must contain letters and numbers
DB_PASSWORD="dc83fd44b8c30c5c271d2c67cd67cb"

# ==============================================================================
# Execution (Do not modify below unless adding VPC parameters)
# ==============================================================================

echo "Deploying CloudFormation stack: $STACK_NAME in $REGION..."

aws cloudformation deploy \
  --region "$REGION" \
  --stack-name "$STACK_NAME" \
  --template-file "$TEMPLATE_FILE" \
  --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM \
  --parameter-overrides \
    Environment="$ENVIRONMENT" \
    Architecture="$ARCHITECTURE" \
    ClientInstanceType="$CLIENT_INSTANCE_TYPE" \
    BaseDomain="$BASE_DOMAIN" \
    KeyName="$KEY_NAME" \
    AllowRemoteSSHIPs="$ALLOW_SSH_IPS" \
    DBUsername="$DB_USER" \
    DBPassword="$DB_PASSWORD"

# Fetch and display the outputs upon success
if [ $? -eq 0 ]; then
  echo ""
  echo "✅ Stack deployment successful! Here are your outputs:"
  echo "------------------------------------------------------"
  aws cloudformation describe-stacks \
    --region "$REGION" \
    --stack-name "$STACK_NAME" \
    --query "Stacks[0].Outputs[*].[OutputKey,OutputValue]" \
    --output table
else
  echo "❌ Stack deployment failed. Check the AWS CLI output or CloudFormation console for details."
fi
