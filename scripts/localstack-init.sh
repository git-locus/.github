#!/bin/sh
# Eseguito da LocalStack all'avvio (ready.d hook).
# Crea i bucket S3 necessari al backend.

awslocal s3api create-bucket \
  --bucket locus-general \
  --create-bucket-configuration LocationConstraint=eu-north-1

awslocal s3api create-bucket \
  --bucket locus-thumbnails \
  --create-bucket-configuration LocationConstraint=eu-north-1

echo "LocalStack S3 buckets created."
