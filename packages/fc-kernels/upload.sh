#!/bin/bash

set -euo pipefail

BUCKET_FC_KERNELS=$(grep BUCKET_FC_KERNELS /opt/config.properties | cut -d'=' -f2)
echo "Uploading kernels to s3://${BUCKET_FC_KERNELS}"

# Check if the file exists
if [ -f "kernel_versions.txt" ]; then
  # Read kernel versions from the file
  while IFS= read -r version || [ -n "$version" ]; do
    echo "Uploading vmlinux-${version}..."
    echo "aws s3 cp --recursive \"builds/vmlinux-${version}\" \"s3://${BUCKET_FC_KERNELS}/vmlinux-${version}/\""
    aws s3 cp --recursive "builds/vmlinux-${version}" "s3://${BUCKET_FC_KERNELS}/vmlinux-${version}/"
  done <"kernel_versions.txt"

  echo "All kernels uploaded to S3 successfully."
else
  echo "Error: kernel_versions.txt not found."
fi
