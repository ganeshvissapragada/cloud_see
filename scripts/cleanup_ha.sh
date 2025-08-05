#!/bin/bash
# CLEANUP SCRIPT FOR THE AUTO SCALING DEMO (MUMBAI REGION)

PROJECT_NAME="fashiony-autoscaling-demo"
# UPDATED for Mumbai Region
AWS_REGION="ap-south-1"

echo "This script will delete ALL resources for project: $PROJECT_NAME in region $AWS_REGION"
read -p "Are you absolutely sure you want to continue? (y/n): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    exit 1
fi

set -x

# 1. Delete Auto Scaling Group and Load Balancer
ASG_NAME="${PROJECT_NAME}-asg"
aws autoscaling update-auto-scaling-group --auto-scaling-group-name "$ASG_NAME" --min-size 0 --max-size 0 --desired-capacity 0 --region $AWS_REGION
echo "Waiting for instances to terminate..."
sleep 60
ALB_NAME="${PROJECT_NAME}-alb"
ALB_ARN=$(aws elbv2 describe-load-balancers --names "$ALB_NAME" --query "LoadBalancers[0].LoadBalancerArn" --output text --region $AWS_REGION 2>/dev/null)
if [ ! -z "$ALB_ARN" ]; then
    LISTENER_ARN=$(aws elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" --query "Listeners[0].ListenerArn" --output text --region $AWS_REGION)
    aws elbv2 delete-listener --listener-arn "$LISTENER_ARN" --region $AWS_REGION
    TG_ARN=$(aws elbv2 describe-target-groups --names "${PROJECT_NAME}-tg" --query "TargetGroups[0].TargetGroupArn" --output text --region $AWS_REGION)
    aws elbv2 delete-target-group --target-group-arn "$TG_ARN" --region $AWS_REGION
    aws elbv2 delete-load-balancer --load-balancer-arn "$ALB_ARN" --region $AWS_REGION
fi
aws autoscaling delete-auto-scaling-group --auto-scaling-group-name "$ASG_NAME" --force-delete --region $AWS_REGION
aws ec2 delete-launch-template --launch-template-name "${PROJECT_NAME}-lt" --region $AWS_REGION

# 2. Delete CloudFront Distribution and S3 Bucket
CF_DIST_ID=$(aws cloudfront list-distributions --query "DistributionList.Items[?Comment=='CDN for ${PROJECT_NAME}'].Id" --output text)
if [ ! -z "$CF_DIST_ID" ]; then
    echo "Disabling CloudFront distribution: $CF_DIST_ID"
    DIST_ETAG=$(aws cloudfront get-distribution-config --id "$CF_DIST_ID" --query "ETag" --output text)
    DIST_CONFIG=$(aws cloudfront get-distribution-config --id "$CF_DIST_ID" --query "DistributionConfig")
    NEW_CONFIG=$(echo "$DIST_CONFIG" | jq '.Enabled=false')
    aws cloudfront update-distribution --id "$CF_DIST_ID" --distribution-config "$NEW_CONFIG" --if-match "$DIST_ETAG" > /dev/null
    echo "Waiting for distribution to be disabled..."
    aws cloudfront wait distribution-deployed --id "$CF_DIST_ID"
    echo "Deleting CloudFront distribution..."
    DIST_ETAG=$(aws cloudfront get-distribution-config --id "$CF_DIST_ID" --query "ETag" --output text)
    aws cloudfront delete-distribution --id "$CF_DIST_ID" --if-match "$DIST_ETAG"
fi
OAC_ID=$(aws cloudfront list-origin-access-controls --query "OriginAccessControlList.Items[?Name=='${PROJECT_NAME}-oac'].Id" --output text)
if [ ! -z "$OAC_ID" ]; then
    OAC_ETAG=$(aws cloudfront get-origin-access-control-config --id "$OAC_ID" --query "ETag" --output text)
    aws cloudfront delete-origin-access-control --id "$OAC_ID" --if-match "$OAC_ETAG"
fi
S3_BUCKET_NAME=$(aws s3 ls | grep "ecommerce-static-assets-" | awk '{print $3}' | head -n 1)
if [ ! -z "$S3_BUCKET_NAME" ]; then
    aws s3 rb "s3://${S3_BUCKET_NAME}" --force
fi

# 3. Delete RDS Database
RDS_DB_ID="${PROJECT_NAME}-db"
aws rds delete-db-instance --db-instance-identifier "$RDS_DB_ID" --skip-final-snapshot --delete-automated-backups --region $AWS_REGION > /dev/null
echo "Waiting for DB instance to be deleted..."
aws rds wait db-instance-deleted --db-instance-identifier "$RDS_DB_ID" --region $AWS_REGION
aws rds delete-db-subnet-group --db-subnet-group-name "${PROJECT_NAME}-db-subnet-group" --region $AWS_REGION

# 4. Delete Networking and IAM
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=${PROJECT_NAME}-vpc" --query "Vpcs[0].VpcId" --output text --region $AWS_REGION)
if [ ! -z "$VPC_ID" ] && [ "$VPC_ID" != "None" ]; then
    IGW_ID=$(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC_ID" --query "InternetGateways[0].InternetGatewayId" --output text --region $AWS_REGION)
    aws ec2 detach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID" --region $AWS_REGION
    aws ec2 delete-internet-gateway --internet-gateway-id "$IGW_ID" --region $AWS_REGION
    for SUBNET_ID in $(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --query "Subnets[].SubnetId" --output text --region $AWS_REGION); do aws ec2 delete-subnet --subnet-id "$SUBNET_ID" --region $AWS_REGION; done
    for RT_ID in $(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" --query "RouteTables[].RouteTableId" --output text --region $AWS_REGION); do aws ec2 delete-route-table --route-table-id "$RT_ID" --region $AWS_REGION; done
    sleep 30
    for SG_ID in $(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" --query "SecurityGroups[?GroupName!='default'].GroupId" --output text --region $AWS_REGION); do aws ec2 delete-security-group --group-id "$SG_ID" --region $AWS_REGION; done
    aws ec2 delete-vpc --vpc-id "$VPC_ID" --region $AWS_REGION
fi

# 5. Delete IAM Role and Profile
IAM_ROLE_NAME="${PROJECT_NAME}-ec2-role"
IAM_INSTANCE_PROFILE_NAME="${PROJECT_NAME}-instance-profile"
aws iam remove-role-from-instance-profile --instance-profile-name "$IAM_INSTANCE_PROFILE_NAME" --role-name "$IAM_ROLE_NAME"
aws iam delete-instance-profile --instance-profile-name "$IAM_INSTANCE_PROFILE_NAME"
aws iam detach-role-policy --role-name "$IAM_ROLE_NAME" --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess
aws iam delete-role --role-name "$IAM_ROLE_NAME"

# 6. Delete local key file
aws ec2 delete-key-pair --key-name "$KEY_NAME" --region $AWS_REGION
rm -f "${KEY_NAME}.pem"

set +x
echo "--- Auto Scaling Demo Cleanup Complete ---"