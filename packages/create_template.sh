#!/bin/bash
set -euo pipefail

# Defaults
DOCKERFILE="FROM e2bdev/code-interpreter:latest"
DOCKER_IMAGE="e2bdev/code-interpreter:latest"
CREATE_TYPE="default"
ECR_IMAGE=""
START_COMMAND="/root/.jupyter/start-up.sh"
READY_COMMAND=""
ALIAS="template-$(date +%s)"
MEMORY_MB=4096
CPU_COUNT=4

# Parse command line arguments
while [ $# -gt 0 ]; do
    case "$1" in
        --docker-file)
            if [ -f "$2" ]; then
                START_COMMAND=""
                DOCKERFILE=$(cat "$2")
                CREATE_TYPE="dockerfile"
                echo "Using Dockerfile: $2"
                shift 2
            else
                echo "Error: Dockerfile $2 not found"
                exit 1
            fi
            ;;
        --ecr-image)
            START_COMMAND=""
            ECR_IMAGE="$2"
            DOCKERFILE="FROM $2"
            CREATE_TYPE="ecr_image"
            echo "Using ECR image: $ECR_IMAGE"
            shift 2
            ;;
        --alias)
            ALIAS="$2"
            shift 2
            ;;
        --memory)
            MEMORY_MB="$2"
            shift 2
            ;;
        --cpus)
            CPU_COUNT="$2"
            shift 2
            ;;
        --start-cmd)
            START_COMMAND="$2"
            shift 2
            ;;
        --ready-cmd)
            READY_COMMAND="$2"
            shift 2
            ;;
        *)
            echo "Usage: $0 [OPTIONS]"
            echo "  --docker-file <path>    Build from a Dockerfile"
            echo "  --ecr-image <uri>       Use an existing ECR image"
            echo "  --alias <name>          Template alias (default: template-<timestamp>)"
            echo "  --memory <MB>           Memory in MB (default: 4096)"
            echo "  --cpus <count>          CPU count (default: 4)"
            echo "  --start-cmd <cmd>       Start command"
            echo "  --ready-cmd <cmd>       Ready command"
            exit 1
            ;;
    esac
done

# Require jq
if ! command -v jq &> /dev/null; then
    echo "Error: jq is required. Install with: apt-get install -y jq"
    exit 1
fi

# Change to the directory of the script
cd "$(dirname "$0")"

# Read config
if [ ! -f /opt/config.properties ]; then
    echo "Error: /opt/config.properties not found"
    exit 1
fi
AWSREGION=$(grep -E "^AWSREGION=" /opt/config.properties | cut -d'=' -f2)
CFNDOMAIN=$(grep -E "^CFNDOMAIN=" /opt/config.properties | cut -d'=' -f2)
echo "Region: $AWSREGION, Domain: $CFNDOMAIN"

CONFIG_FILE="./../infra-iac/db/config.json"
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: $CONFIG_FILE not found"
    exit 1
fi
ACCESS_TOKEN=$(jq -r '.accessToken' "$CONFIG_FILE")

# Build JSON payload with proper escaping
JSON_PAYLOAD=$(jq -n \
    --arg dockerfile "$DOCKERFILE" \
    --arg startCmd "$START_COMMAND" \
    --arg readyCmd "$READY_COMMAND" \
    --arg alias "$ALIAS" \
    --argjson memoryMB "$MEMORY_MB" \
    --argjson cpuCount "$CPU_COUNT" \
    '{
        dockerfile: $dockerfile,
        startCmd: $startCmd,
        readyCmd: $readyCmd,
        alias: $alias,
        memoryMB: $memoryMB,
        cpuCount: $cpuCount
    }')

echo "Creating template..."
RESPONSE=$(curl -s -X POST \
    "https://api.$CFNDOMAIN/templates" \
    -H "Authorization: $ACCESS_TOKEN" \
    -H 'Content-Type: application/json' \
    -d "$JSON_PAYLOAD")

BUILD_ID=$(echo "$RESPONSE" | jq -r '.buildID')
TEMPLATE_ID=$(echo "$RESPONSE" | jq -r '.templateID')

if [ "$BUILD_ID" = "null" ] || [ "$TEMPLATE_ID" = "null" ]; then
    echo "Error: Failed to create template. Response:"
    echo "$RESPONSE" | jq .
    exit 1
fi

echo "Template ID: $TEMPLATE_ID"
echo "Build ID:    $BUILD_ID"

# ECR setup
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_DOMAIN="$AWS_ACCOUNT_ID.dkr.ecr.$AWSREGION.amazonaws.com"

echo "Logging in to ECR..."
aws ecr get-login-password --region "$AWSREGION" | docker login --username AWS --password-stdin "$ECR_DOMAIN"

echo "Creating ECR repository..."
aws ecr create-repository --repository-name "e2bdev/base/$TEMPLATE_ID" --region "$AWSREGION" 2>/dev/null || true

# Build/pull Docker image
case "$CREATE_TYPE" in
    "dockerfile")
        TEMP_DIR=$(mktemp -d)
        echo "$DOCKERFILE" > "$TEMP_DIR/Dockerfile"
        echo "Building Docker image from Dockerfile..."
        docker build -t "template-build-$TEMPLATE_ID" "$TEMP_DIR"
        rm -rf "$TEMP_DIR"
        BASE_IMAGE="template-build-$TEMPLATE_ID"
        ;;
    "ecr_image")
        echo "Pulling ECR image $ECR_IMAGE..."
        docker pull "$ECR_IMAGE"
        BASE_IMAGE="$ECR_IMAGE"
        ;;
    "default")
        echo "Pulling default image $DOCKER_IMAGE..."
        docker pull "$DOCKER_IMAGE"
        BASE_IMAGE="$DOCKER_IMAGE"
        ;;
esac

# Tag and push
BASE_ECR_REPOSITORY="$ECR_DOMAIN/e2bdev/base/$TEMPLATE_ID:$BUILD_ID"
echo "Pushing to $BASE_ECR_REPOSITORY..."
docker tag "$BASE_IMAGE" "$BASE_ECR_REPOSITORY"
docker push "$BASE_ECR_REPOSITORY"

# Notify API
echo "Notifying API that build is ready..."
curl -s -X POST \
    "https://api.$CFNDOMAIN/templates/$TEMPLATE_ID/builds/$BUILD_ID" \
    -H "Authorization: $ACCESS_TOKEN" \
    -H 'Content-Type: application/json' | jq .

# Poll build status
echo "Polling build status..."
while true; do
    STATUS=$(curl -s \
        "https://api.$CFNDOMAIN/templates/$TEMPLATE_ID/builds/$BUILD_ID/status" \
        -H "Authorization: $ACCESS_TOKEN" | jq -r '.status')

    echo "Status: $STATUS"

    if [ "$STATUS" != "building" ] && [ "$STATUS" != "waiting" ]; then
        break
    fi
    sleep 10
done

if [ "$STATUS" = "error" ] || [ "$STATUS" = "failed" ]; then
    echo "Build failed with status: $STATUS"
    exit 1
elif [ "$STATUS" = "ready" ] || [ "$STATUS" = "success" ]; then
    echo "Build completed successfully!"
    echo "Template ID: $TEMPLATE_ID"
else
    echo "Build finished with unexpected status: $STATUS"
    exit 1
fi
