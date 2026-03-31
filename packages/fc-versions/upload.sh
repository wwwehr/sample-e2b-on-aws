#!/bin/bash

set -euo pipefail

BUCKET_FC_VERSIONS=$(grep BUCKET_FC_VERSIONS /opt/config.properties | cut -d'=' -f2)
echo "Uploading firecracker versions to s3://${BUCKET_FC_VERSIONS}"

aws s3 cp --recursive builds/ "s3://${BUCKET_FC_VERSIONS}/"

rm -rf builds/*
