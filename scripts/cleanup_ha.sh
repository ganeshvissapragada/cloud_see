#!/bin/bash
# ROBUST CLEANUP SCRIPT v2 (Handles Dependencies)

PROJECT_NAME="fashiony-autoscaling-demo"
AWS_REGION="ap-south-1"

echo "This script will delete ALL resources for project: $PROJECT_NAME in region $AWS_REGION"
read -p "Are you absolutely sure you want to continue? (y/n): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    exit 1
fi

echo "--- Starting Robust Cleanup ---"
set -x # Echo commands to the terminal for debugging

# 1. Delete Auto Scaling Group (this also terminates instances)
ASG_NAME="${PROJECT_NAME}-asg"
echo "Setting ASG desired capacity to 0..."
aws autoscaling update-auto-scaling-group --auto-scaling-group-name "$ASG_NAME" --min-size 0 --max-size 0 --desired-capacity 0 --region $AWS_REGION || echo "ASG not found or already at 0."
echo "Waiting for all instances in ASG to terminate... (This can take a few minutes)"
# We find instances tagged by the ASG and wait for them to be terminated.
INSTANCE_IDS=$(aws ec2 describe-instances --filters "Name=tag:aws:autoscaling:groupName,Values=$ASG_NAME" "Name=instance-state-name,Values=pending,running,shutting-down,stopping,stopped" --query "Reservations[].Instances[].InstanceId" --output text --region $AWS_REGION)
if [ -n "$INSTANCE_IDS" ]; then
    aws ec2 wait instance-terminated --instance-ids $INSTANCE_IDS --region $AWS_REGION
fi
echo "All instances terminated."

# 2. Delete Load Balancer
ALB_NAME="${PROJECT_NAME}-alb"
ALB_ARN=$(aws elbv2 describe-load-balancers --names "$ALB_NAME" --query "LoadBalancers[0].LoadBalancerArn" --output text --region $AWS_REGION 2>/dev/null)
if [ -n "$ALB_ARN" ]; then
    echo "Deleting Load Balancer..."
    aws elbv2 delete-load-balancer --load-balancer-arn "$ALB_ARN" --region $AWS_REGION
    aws elbv2 wait load-balancers-deleted --load-balancer-arns "$ALB_ARN" --region $AWS_REGION
    echo "Load Balancer Deleted."
fi

# 3. Delete Target Group
TG_ARN=$(aws elbv2 describe-target-groups --names "${PROJECT_NAME}-tg" --query "TargetGroups[0].TargetGroupArn" --output text --region $AWS_REGION 2>/dev/null)
if [ -n "$TG_ARN" ]; then
    echo "Deleting Target Group..."
    aws elbv2 delete-target-group --target-group-arn "$TG_ARN" --region $AWS_REGION
fi

# 4. Delete the Auto Scaling Group itself
echo "Deleting Auto Scaling Group..."
aws autoscaling delete-auto-scaling-group --auto-scaling-group-name "$ASG_NAME" --force-delete --region $AWS_REGION || echo "ASG not found."

# 5. Delete Launch Template
echo "Deleting Launch Template..."
aws ec2 delete-launch-template --launch-template-name "${PROJECT_NAME}-lt" --region $AWS_REGION || echo "Launch Template not found."

# 6. Delete CloudFront and S3
CF_DIST_ID=$(aws cloudfront list-distributions --query "DistributionList.Items[?Comment=='CDN for ${PROJECT_NAME}'].Id" --output text)
if [ -n "$CF_DIST_ID" ]; then
    echo "Disabling and Deleting CloudFront distribution..."
    DIST_ETAG=$(aws cloudfront get-distribution-config --id "$CF_DIST_ID" --query "ETag" --output text)
    DIST_CONFIG=$(aws cloudfront get-distribution-config --id "$CF_DIST_ID" --query "DistributionConfig")
    NEW_CONFIG=$(echo "$DIST_CONFIG" | jq '.Enabled=false')
    aws cloudfront update-distribution --id "$CF_DIST_ID" --distribution-config "$NEW_CONFIG" --if-match "$DIST_ETAG" > /dev/null
    aws cloudfront wait distribution-deployed --id "$CF_DIST_ID"
    DIST_ETAG=$(aws cloudfront get-distribution-config --id "$CF_DIST_ID" --query "ETag" --output text)
    aws cloudfront delete-distribution --id "$CF_DIST_ID" --if-match "$DIST_ETAG"
fi

OAC_ID=$(aws cloudfront list-origin-access-controls --query "OriginAccessControlList.Items[?Name=='${PROJECT_NAME}-oac'].Id" --output text)
if [ -n "$OAC_ID" ]; then
    OAC_ETAG=$(aws cloudfront get-origin-access-control-config --id "$OAC_ID" --query "ETag" --output text)
    aws cloudfront delete-origin-access-control --id "$OAC_ID" --if-match "$OAC_ETAG"
fi

# Find the bucket name dynamically
S3_BUCKET_NAME=$(aws s3api list-buckets --query "Buckets[?starts_with(Name, 'ecommerce-static-assets-')].Name" --output text)
if [ -n "$S3_BUCKET_NAME" ]; then
    echo "Emptying and Deleting S3 Bucket..."
    aws s3 rb "s3://${S3_BUCKET_NAME}" --force
fi

# 7. Delete RDS Database
RDS_DB_ID="${PROJECT_NAME}-db"
echo "Deleting RDS Database (this can take several minutes)..."
aws rds delete-db-instance --db-instance-identifier "$RDS_DB_ID" --skip-final-snapshot --delete-automated-backups --region $AWS_REGION > /dev/null || echo "RDS DB not found."
aws rds wait db-instance-deleted --db-instance-identifier "$RDS_DB_ID" --region $AWS_REGION
aws rds delete-db-subnet-group --db-subnet-group-name "${PROJECT_NAME}-db-subnet-group" --region $AWS_REGION || echo "DB Subnet Group not found."

# 8. Delete Network Interfaces, Security Groups, and VPC
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=${PROJECT_NAME}-vpc" --query "Vpcs[0].VpcId" --output text --region $AWS_REGION)
if [ -n "$VPC_ID" ] && [ "$VPC_ID" != "None" ]; then
    echo "Starting network cleanup for VPC: $VPC_ID"
    # Find and delete Network Interfaces
    ENI_IDS=$(aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$VPC_ID" --query "NetworkInterfaces[].NetworkInterfaceId" --output text --region $AWS_REGION)
    if [ -n "$ENI_IDS" ]; then
        for eni in $ENI_IDS; do
            echo "Deleting Network Interface: $eni"
            aws ec2 delete-network-interface --network-interface-id $eni --region $AWS_REGION || echo "Failed to delete ENI $eni, might be in use or already gone."
        done
        # Give some time for ENIs to detach/delete
        sleep 30
    fi

    # Detach and delete Internet Gateway
    IGW_ID=$(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC_ID" --query "InternetGateways[0].InternetGatewayId" --output text --region $AWS_REGION)
    if [ -n "$IGW_ID" ] && [ "$IGW_ID" != "None" ]; then
        echo "Detaching and deleting Internet Gateway..."
        aws ec2 detach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID" --region $AWS_REGION
        aws ec2 delete-internet-gateway --internet-gateway-id "$IGW_ID" --region $AWS_REGION
    fi

    # Delete Security Groups
    SG_IDS=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" --query "SecurityGroups[?GroupName!='default'].GroupId" --output text --region $AWS_REGION)
    if [ -n "$SG_IDS" ]; then
        for sg in $SG_IDS; do
            echo "Deleting Security Group: $sg"
            aws ec2 delete-security-group --group-id $sg --region $AWS_REGION
        done
    fi
    
    # Delete Subnets
    SUBNET_IDS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --query "Subnets[].SubnetId" --output text --region $AWS_REGION)
    if [ -n "$SUBNET_IDS" ]; then
        for subnet in $SUBNET_IDS; do
            echo "Deleting Subnet: $subnet"
            aws ec2 delete-subnet --subnet-id $subnet --region $AWS_REGION
        done
    fi

    # Delete Route Tables
    RT_IDS=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" --query "RouteTables[?Associations[?Main!=true]].RouteTableId" --output text --region $AWS_REGION)
    if [ -n "$RT_IDS" ]; then
        for rt in $RT_IDS; do
            echo "Deleting Route Table: $rt"
            aws ec2 delete-route-table --route-table-id $rt --region $AWS_REGION
        done
    fi

    # Finally, delete the VPC
    echo "Deleting VPC..."
    aws ec2 delete-vpc --vpc-id "$VPC_ID" --region $AWS_REGION
fi

# 9. Delete IAM Role and Profile
IAM_ROLE_NAME="${PROJECT_NAME}-ec2-role"
echo "Detaching policies and deleting IAM Role..."
aws iam detach-role-policy --role-name "$IAM_ROLE_NAME" --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess --region $AWS_REGION || echo "Policy already detached or role not found."
aws iam remove-role-from-instance-profile --instance-profile-name "${PROJECT_NAME}-instance-profile" --role-name "$IAM_ROLE_NAME" || echo "Role already removed from profile."
aws iam delete-role --role-name "$IAM_ROLE_NAME" --region $AWS_REGION || echo "Role not found."
aws iam delete-instance-profile --instance-profile-name "${PROJECT_NAME}-instance-profile" --region $AWS_REGION || echo "Instance Profile not found."

# 10. Delete local key file
KEY_NAME="ecommerce-asg-freetier-key"
echo "Deleting local key pair file..."
rm -f "${KEY_NAME}.pem"
echo "Deleting key pair from AWS..."
aws ec2 delete-key-pair --key-name "$KEY_NAME" --region $AWS_REGION || echo "Key Pair not found in AWS."

set +x
echo "--- Robust Cleanup Complete ---"