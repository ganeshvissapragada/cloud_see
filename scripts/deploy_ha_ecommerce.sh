#!/bin/bash

# ======================================================================================
# AWS High-Availability Deployment Script
#
# Deploys a PHP/MySQL app using an Application Load Balancer (ALB),
# an Auto Scaling Group (ASG), and a scalable Aurora Serverless Database.
# ======================================================================================

set -e

# --- Configuration ---
AWS_REGION="us-east-1"
PROJECT_NAME="fashiony-ha"
# The name of your application's folder inside the Git repo.
APP_FOLDER_NAME="php_app"
INSTANCE_TYPE="t2.micro"
AMI_ID="ami-0c55b159cbfafe1f0" # Ubuntu 22.04 LTS for us-east-1
KEY_NAME="ecommerce-ha-key"
AURORA_ENGINE_VERSION="8.0.mysql_aurora.3.02.0"

# --- Terminal Colors ---
C_BLUE='\033[0;34m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[0;33m'
C_NC='\033[0m'

echo -e "${C_BLUE}### Starting High-Availability AWS Deployment ###${C_NC}"

# --- User Input ---
read -p "Enter your public GitHub repository URL (e.g., https://github.com/user/repo.git): " GIT_REPO_URL
read -s -p "Enter the password for the Aurora database master user 'admin': " DB_MASTER_PASS
echo
if [ -z "$GIT_REPO_URL" ] || [ -z "$DB_MASTER_PASS" ]; then
    echo "Git URL and DB password cannot be empty."
    exit 1
fi

# === 1. Network Setup (VPC, Subnets, IGW, NAT, Routes) ===
# (This section remains unchanged)
echo -e "${C_BLUE}--- Setting up Secure Network ---${C_NC}"
VPC_ID=$(aws ec2 create-vpc --cidr-block 10.0.0.0/16 --query Vpc.VpcId --output text --region $AWS_REGION)
aws ec2 create-tags --resources "$VPC_ID" --tags Key=Name,Value="${PROJECT_NAME}-vpc" --region $AWS_REGION
IGW_ID=$(aws ec2 create-internet-gateway --query InternetGateway.InternetGatewayId --output text --region $AWS_REGION)
aws ec2 attach-internet-gateway --vpc-id "$VPC_ID" --internet-gateway-id "$IGW_ID" --region $AWS_REGION
PUBLIC_SUBNET_1=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block 10.0.1.0/24 --availability-zone "${AWS_REGION}a" --query Subnet.SubnetId --output text --region $AWS_REGION)
PUBLIC_SUBNET_2=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block 10.0.2.0/24 --availability-zone "${AWS_REGION}b" --query Subnet.SubnetId --output text --region $AWS_REGION)
PRIVATE_SUBNET_1=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block 10.0.3.0/24 --availability-zone "${AWS_REGION}a" --query Subnet.SubnetId --output text --region $AWS_REGION)
PRIVATE_SUBNET_2=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block 10.0.4.0/24 --availability-zone "${AWS_REGION}b" --query Subnet.SubnetId --output text --region $AWS_REGION)
aws ec2 create-tags --resources "$PUBLIC_SUBNET_1" "$PUBLIC_SUBNET_2" "$PRIVATE_SUBNET_1" "$PRIVATE_SUBNET_2" --tags Key=Name,Value="${PROJECT_NAME}-subnet" --region $AWS_REGION
PUBLIC_RT_ID=$(aws ec2 create-route-table --vpc-id "$VPC_ID" --query RouteTable.RouteTableId --output text --region $AWS_REGION)
aws ec2 create-route --route-table-id "$PUBLIC_RT_ID" --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW_ID" --region $AWS_REGION > /dev/null
aws ec2 associate-route-table --subnet-id "$PUBLIC_SUBNET_1" --route-table-id "$PUBLIC_RT_ID" --region $AWS_REGION > /dev/null
aws ec2 associate-route-table --subnet-id "$PUBLIC_SUBNET_2" --route-table-id "$PUBLIC_RT_ID" --region $AWS_REGION > /dev/null
EIP_ALLOC_ID=$(aws ec2 allocate-address --domain vpc --query AllocationId --output text --region $AWS_REGION)
NAT_GW_ID=$(aws ec2 create-nat-gateway --subnet-id "$PUBLIC_SUBNET_1" --allocation-id "$EIP_ALLOC_ID" --query NatGateway.NatGatewayId --output text --region $AWS_REGION)
echo "Waiting for NAT Gateway to become available..."
aws ec2 wait nat-gateway-available --nat-gateway-ids "$NAT_GW_ID" --region $AWS_REGION
PRIVATE_RT_ID=$(aws ec2 create-route-table --vpc-id "$VPC_ID" --query RouteTable.RouteTableId --output text --region $AWS_REGION)
aws ec2 create-route --route-table-id "$PRIVATE_RT_ID" --destination-cidr-block 0.0.0.0/0 --nat-gateway-id "$NAT_GW_ID" --region $AWS_REGION > /dev/null
aws ec2 associate-route-table --subnet-id "$PRIVATE_SUBNET_1" --route-table-id "$PRIVATE_RT_ID" --region $AWS_REGION > /dev/null
aws ec2 associate-route-table --subnet-id "$PRIVATE_SUBNET_2" --route-table-id "$PRIVATE_RT_ID" --region $AWS_REGION > /dev/null

# === 2. Security Groups & IAM ===
# (This section remains unchanged)
echo -e "${C_BLUE}--- Setting up Security Groups and IAM Role ---${C_NC}"
ALB_SG_ID=$(aws ec2 create-security-group --group-name "${PROJECT_NAME}-alb-sg" --description "SG for ALB" --vpc-id "$VPC_ID" --query GroupId --output text --region $AWS_REGION)
aws ec2 authorize-security-group-ingress --group-id "$ALB_SG_ID" --protocol tcp --port 80 --cidr 0.0.0.0/0 --region $AWS_REGION > /dev/null
EC2_SG_ID=$(aws ec2 create-security-group --group-name "${PROJECT_NAME}-ec2-sg" --description "SG for EC2 instances" --vpc-id "$VPC_ID" --query GroupId --output text --region $AWS_REGION)
aws ec2 authorize-security-group-ingress --group-id "$EC2_SG_ID" --protocol tcp --port 80 --source-group "$ALB_SG_ID" --region $AWS_REGION > /dev/null
DB_SG_ID=$(aws ec2 create-security-group --group-name "${PROJECT_NAME}-db-sg" --description "SG for Aurora DB" --vpc-id "$VPC_ID" --query GroupId --output text --region $AWS_REGION)
aws ec2 authorize-security-group-ingress --group-id "$DB_SG_ID" --protocol tcp --port 3306 --source-group "$EC2_SG_ID" --region $AWS_REGION > /dev/null
SECRET_NAME="${PROJECT_NAME}/rds-credentials"
aws secretsmanager create-secret --name "$SECRET_NAME" --secret-string "$DB_MASTER_PASS" --region $AWS_REGION > /dev/null
IAM_ROLE_NAME="${PROJECT_NAME}-ec2-role"
TRUST_POLICY='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
aws iam create-role --role-name "$IAM_ROLE_NAME" --assume-role-policy-document "$TRUST_POLICY" --region $AWS_REGION > /dev/null
aws iam attach-role-policy --role-name "$IAM_ROLE_NAME" --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess --region $AWS_REGION
aws iam attach-role-policy --role-name "$IAM_ROLE_NAME" --policy-arn arn:aws:iam::aws:policy/SecretsManagerReadWrite --region $AWS_REGION
IAM_INSTANCE_PROFILE_NAME="${PROJECT_NAME}-instance-profile"
aws iam create-instance-profile --instance-profile-name "$IAM_INSTANCE_PROFILE_NAME" --region $AWS_REGION > /dev/null
aws iam add-role-to-instance-profile --instance-profile-name "$IAM_INSTANCE_PROFILE_NAME" --role-name "$IAM_ROLE_NAME" --region $AWS_REGION
echo "Waiting for IAM role to propagate..."
sleep 15

# === 3. Database Setup (Aurora Serverless) ===
# (This section remains unchanged)
echo -e "${C_BLUE}--- Provisioning Aurora Serverless DB Cluster ---${C_NC}"
DB_SUBNET_GROUP_NAME="${PROJECT_NAME}-db-subnet-group"
aws rds create-db-subnet-group --db-subnet-group-name "$DB_SUBNET_GROUP_NAME" --db-subnet-group-description "Subnet group for Aurora" --subnet-ids "$PRIVATE_SUBNET_1" "$PRIVATE_SUBNET_2" --region $AWS_REGION > /dev/null
CLUSTER_ID="${PROJECT_NAME}-db-cluster"
aws rds create-db-cluster --db-cluster-identifier "$CLUSTER_ID" --engine aurora-mysql --engine-version "$AURORA_ENGINE_VERSION" --master-username admin --master-user-password "$DB_MASTER_PASS" --database-name ecommercedb --vpc-security-group-ids "$DB_SG_ID" --db-subnet-group-name "$DB_SUBNET_GROUP_NAME" --serverless-v2-scaling-configuration "MinCapacity=0.5,MaxCapacity=2" --region $AWS_REGION > /dev/null
echo "Waiting for Aurora cluster to become available... (This may take 10-15 minutes)"
aws rds wait db-cluster-available --db-cluster-identifier "$CLUSTER_ID" --region $AWS_REGION
AURORA_ENDPOINT=$(aws rds describe-db-clusters --db-cluster-identifier "$CLUSTER_ID" --query "DBClusters[0].Endpoint" --output text --region $AWS_REGION)

# === 4. Application Setup (Launch Template & Auto Scaling Group) ===
echo -e "${C_BLUE}--- Creating Launch Template and Auto Scaling Group ---${C_NC}"
if [ ! -f "${KEY_NAME}.pem" ]; then
    aws ec2 create-key-pair --key-name "$KEY_NAME" --query "KeyMaterial" --output text --region $AWS_REGION > "${KEY_NAME}.pem"
    chmod 400 "${KEY_NAME}.pem"
fi
S3_BUCKET_NAME="ecommerce-static-assets-$RANDOM$RANDOM"
aws s3api create-bucket --bucket "$S3_BUCKET_NAME" --region "$AWS_REGION" --create-bucket-configuration LocationConstraint="$AWS_REGION" > /dev/null
POLICY="{\"Version\":\"2012-10-17\",\"Statement\":[{\"Sid\":\"PublicReadAssets\",\"Effect\":\"Allow\",\"Principal\":\"*\",\"Action\":\"s3:GetObject\",\"Resource\":\"arn:aws:s3:::$S3_BUCKET_NAME/*\"}]}"
aws s3api put-bucket-policy --bucket "$S3_BUCKET_NAME" --policy "$POLICY" --region $AWS_REGION > /dev/null

# This script runs on each EC2 instance at boot (UserData)
USER_DATA=$(cat <<EOF
#!/bin/bash
set -e
apt-get update
apt-get install -y apache2 php libapache2-mod-php php-mysql git mysql-client-core-8.0
apt-get install -y unzip
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "/tmp/awscliv2.zip"
unzip /tmp/awscliv2.zip -d /tmp
/tmp/aws/install

cd /var/www/html
rm -f index.html
git clone ${GIT_REPO_URL} .

if ! aws s3 ls s3://${S3_BUCKET_NAME}/assets --region ${AWS_REGION}; then
    aws s3 cp /var/www/html/${APP_FOLDER_NAME}/assets s3://${S3_BUCKET_NAME}/assets --recursive --region ${AWS_REGION}
fi

DB_PASS=\$(aws secretsmanager get-secret-value --secret-id ${SECRET_NAME} --query SecretString --output text --region ${AWS_REGION})

CONFIG_FILE="/var/www/html/${APP_FOLDER_NAME}/admin/inc/config.php"
sed -i "s|\\\$dbhost = '.*';|\\\$dbhost = '${AURORA_ENDPOINT}';|" \$CONFIG_FILE
sed -i "s|\\\$dbname = '.*';|\\\$dbname = 'ecommercedb';|" \$CONFIG_FILE
sed -i "s|\\\$dbuser = '.*';|\\\$dbuser = 'admin';|" \$CONFIG_FILE
sed -i "s|\\\$dbpass = '.*';|\\\$dbpass = '\$DB_PASS';|" \$CONFIG_FILE

S3_ASSET_URL="https://${S3_BUCKET_NAME}.s3.${AWS_REGION}.amazonaws.com/assets/"
find /var/www/html/${APP_FOLDER_NAME}/ -type f -name "*.php" -exec sed -i "s|../assets/|\${S3_ASSET_URL}|g" {} +
find /var/www/html/${APP_FOLDER_NAME}/ -type f -name "*.php" -exec sed -i "s|assets/|\${S3_ASSET_URL}|g" {} +

(
  flock -n 200 || exit 1
  TABLE_COUNT=\$(mysql -h "${AURORA_ENDPOINT}" -u "admin" -p"\$DB_PASS" -D "ecommercedb" -s -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='ecommercedb';")
  if [ \$TABLE_COUNT -eq 0 ]; then
      mysql -h "${AURORA_ENDPOINT}" -u "admin" -p"\$DB_PASS" "ecommercedb" < /var/www/html/database/fashiony_ogs.sql
      mysql -h "${AURORA_ENDPOINT}" -u "admin" -p"\$DB_PASS" "ecommercedb" -e "UPDATE settings SET footer_text = '' WHERE footer_text LIKE '%Virtual University%';"
  fi
) 200>/var/lock/db_import.lock

chown -R www-data:www-data /var/www/html
systemctl restart apache2
EOF
)

LT_ID=$(aws ec2 create-launch-template \
    --launch-template-name "${PROJECT_NAME}-lt" \
    --version-description "Initial version" \
    --launch-template-data "{\"ImageId\":\"$AMI_ID\",\"InstanceType\":\"$INSTANCE_TYPE\",\"KeyName\":\"$KEY_NAME\",\"SecurityGroupIds\":[\"$EC2_SG_ID\"],\"IamInstanceProfile\":{\"Name\":\"$IAM_INSTANCE_PROFILE_NAME\"},\"UserData\":\"$(echo "$USER_DATA" | base64 -w 0)\"}" \
    --query "LaunchTemplate.LaunchTemplateId" --output text --region $AWS_REGION)

ASG_NAME="${PROJECT_NAME}-asg"
aws autoscaling create-auto-scaling-group \
    --auto-scaling-group-name "$ASG_NAME" \
    --launch-template "LaunchTemplateId=$LT_ID" \
    --min-size 1 \
    --max-size 3 \
    --desired-capacity 2 \
    --vpc-zone-identifier "$PRIVATE_SUBNET_1,$PRIVATE_SUBNET_2" \
    --region $AWS_REGION

# === 5. Load Balancer Setup ===
echo -e "${C_BLUE}--- Creating Application Load Balancer ---${C_NC}"
ALB_ARN=$(aws elbv2 create-load-balancer --name "${PROJECT_NAME}-alb" --subnets "$PUBLIC_SUBNET_1" "$PUBLIC_SUBNET_2" --security-groups "$ALB_SG_ID" --query "LoadBalancers[0].LoadBalancerArn" --output text --region $AWS_REGION)
TG_ARN=$(aws elbv2 create-target-group --name "${PROJECT_NAME}-tg" --protocol HTTP --port 80 --vpc-id "$VPC_ID" --health-check-path "/${APP_FOLDER_NAME}/index.php" --query "TargetGroups[0].TargetGroupArn" --output text --region $AWS_REGION)

aws autoscaling attach-load-balancer-target-groups --auto-scaling-group-name "$ASG_NAME" --target-group-arns "$TG_ARN" --region $AWS_REGION

aws elbv2 create-listener --load-balancer-arn "$ALB_ARN" --protocol HTTP --port 80 --default-actions "Type=forward,TargetGroupArn=$TG_ARN" --region $AWS_REGION > /dev/null

# === 6. Deployment Complete ===
ALB_DNS=$(aws elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" --query "LoadBalancers[0].DNSName" --output text --region $AWS_REGION)
echo -e "\n${C_GREEN}### ✅ DEPLOYMENT COMPLETE! ###${C_NC}"
echo -e "Access your highly-available website at: ${C_YELLOW}http://${ALB_DNS}/${APP_FOLDER_NAME}/${C_NC}"
echo -e "It may take a few minutes for the instances to register with the load balancer and pass health checks."