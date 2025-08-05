#!/bin/bash
# CLEANUP SCRIPT UPDATED FOR CLOUDFRONT

PROJECT_NAME="fashiony-ha-cdn"
AWS_REGION="us-east-1"

echo "This script will delete ALL resources for project: $PROJECT_NAME in region $AWS_REGION"
read -p "Are you absolutely sure you want to continue? (y/n): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    exit 1
fi

set -x

# 1. Delete ASG and ALB (same as before)
ASG_NAME="${PROJECT_NAME}-asg"
aws autoscaling update-auto-scaling-group --auto-scaling-group-name "$ASG_NAME" --min-size 0 --max-size 0 --desired-capacity 0 --region $AWS_REGION
echo "Waiting for instances to terminate..."
sleep 90
ALB_NAME="${PROJECT_NAME}-alb"
ALB_ARN=$(aws elbv2 describe-load-balancers --names "$ALB_NAME" --query "LoadBalancers[0].LoadBalancerArn" --output text --region $AWS_REGION)
LISTENER_ARN=$(aws elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" --query "Listeners[0].ListenerArn" --output text --region $AWS_REGION)
TG_ARN=$(aws elbv2 describe-target-groups --names "${PROJECT_NAME}-tg" --query "TargetGroups[0].TargetGroupArn" --output text --region $AWS_REGION)
aws elbv2 delete-listener --listener-arn "$LISTENER_ARN" --region $AWS_REGION
aws elbv2 delete-target-group --target-group-arn "$TG_ARN" --region $AWS_REGION
aws elbv2 delete-load-balancer --load-balancer-arn "$ALB_ARN" --region $AWS_REGION
aws autoscaling delete-auto-scaling-group --auto-scaling-group-name "$ASG_NAME" --force-delete --region $AWS_REGION
aws ec2 delete-launch-template --launch-template-name "${PROJECT_NAME}-lt" --region $AWS_REGION

# 2. Delete CloudFront Distribution
CF_DIST_ID=$(aws cloudfront list-distributions --query "DistributionList.Items[?Comment=='CDN for ${PROJECT_NAME}'].Id" --output text)
if [ ! -z "$CF_DIST_ID" ]; then
    echo "Disabling CloudFront distribution: $CF_DIST_ID"
    DIST_ETAG=$(aws cloudfront get-distribution-config --id "$CF_DIST_ID" --query "ETag" --output text)
    DIST_CONFIG=$(aws cloudfront get-distribution-config --id "$CF_DIST_ID" --query "DistributionConfig")
    # Set Enabled to false
    NEW_CONFIG=$(echo "$DIST_CONFIG" | jq '.Enabled=false')
    aws cloudfront update-distribution --id "$CF_DIST_ID" --distribution-config "$NEW_CONFIG" --if-match "$DIST_ETAG" > /dev/null
    echo "Waiting for distribution to be disabled..."
    aws cloudfront wait distribution-deployed --id "$CF_DIST_ID"
    echo "Deleting CloudFront distribution..."
    DIST_ETAG=$(aws cloudfront get-distribution-config --id "$CF_DIST_ID" --query "ETag" --output text)
    aws cloudfront delete-distribution --id "$CF_DIST_ID" --if-match "$DIST_ETAG"
fi

# 3. Delete Origin Access Control
OAC_ID=$(aws cloudfront list-origin-access-controls --query "OriginAccessControlList.Items[?Name=='${PROJECT_NAME}-oac'].Id" --output text)
if [ ! -z "$OAC_ID" ]; then
    OAC_ETAG=$(aws cloudfront get-origin-access-control-config --id "$OAC_ID" --query "ETag" --output text)
    aws cloudfront delete-origin-access-control --id "$OAC_ID" --if-match "$OAC_ETAG"
fi

# 4. Empty and Delete S3 Bucket
S3_BUCKET_NAME=$(aws s3 ls | grep "ecommerce-static-assets-" | awk '{print $3}')
if [ ! -z "$S3_BUCKET_NAME" ]; then
    aws s3 rb "s3://${S3_BUCKET_NAME}" --force
fi

# 5. Delete Database (same as before)
CLUSTER_ID="${PROJECT_NAME}-db-cluster"
aws rds delete-db-cluster --db-cluster-identifier "$CLUSTER_ID" --skip-final-snapshot --region $AWS_REGION

# ... The rest of the network and IAM cleanup remains the same ...
# (Add the rest of your previous cleanup script here starting from VPC cleanup)

echo "--- Cleanup initiated. It may take several minutes for all resources to be deleted. ---"