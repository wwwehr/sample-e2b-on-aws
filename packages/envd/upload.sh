#!/bin/bash

set -euo pipefail

BUCKET_FC_ENV_PIPELINE=$(grep BUCKET_FC_ENV_PIPELINE /opt/config.properties | cut -d'=' -f2)
echo "Uploading envd to s3://${BUCKET_FC_ENV_PIPELINE}"

chmod +x bin/envd
aws s3 cp bin/envd "s3://${BUCKET_FC_ENV_PIPELINE}/envd"
