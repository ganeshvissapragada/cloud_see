#!/bin/bash

# ======================================================================================
# AWS Auto Scaling on a Free Tier Budget (MUMBAI REGION - FINAL FIX v5)
#
# This script uses db.t3.micro and the specific MySQL 5.7.44 version
# confirmed to be available in your account for the ap-south-1 region.
# ======================================================================================

set -e

# --- Configuration ---
AWS_REGION="ap-south-1"
PROJECT_NAME="fashiony-autoscaling-demo"
APP_FOLDER_NAME="php_app"
INSTANCE_TYPE="t2.micro"
# ** FIX APPLIED: Use the newer db.t3.micro instance class **
RDS_INSTANCE_CLASS="db.t3.micro"
# ** And the confirmed compatible MySQL engine version **
RDS_ENGINE_VERSION="5.7.44"
AMI_ID="ami-0f5ee92e2d63afc18" # Official Ubuntu 22.04 AMI for ap-south-1
KEY_NAME="ecommerce-asg-freetier-key"

# --- Terminal Colors ---
C_BLUE='\033[0;34m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[0;33m'
C_NC='\033[0m'

echo -e "${C_BLUE}### Starting AWS Auto Scaling (Mumbai Region) Deployment ###${C_NC}"

# --- User Input ---
read -p "Enter your public GitHub repository URL: " GIT_REPO_URL
read -s -p "Enter the password for the RDS database master user 'admin': " DB_MASTER_PASS
echo
if [ -z "$GIT_REPO_URL" ] || [ -z "$DB_MASTER_PASS" ]; then
    echo "Git URL and DB password cannot be empty."
    exit 1
fi

# === 1. Network Setup (Public Subnets Only) ===
echo -e "\n${C_BLUE}--- Setting up Network ---${C_NC}"
echo "Creating VPC..."
VPC_ID=$(aws ec2 create-vpc --cidr-block 10.0.0.0/16 --query Vpc.VpcId --output text --region $AWS_REGION)
aws ec2 create-tags --resources "$VPC_ID" --tags Key=Name,Value="${PROJECT_NAME}-vpc" --region $AWS_REGION
echo "VPC Created: ${VPC_ID}"

echo "Enabling DNS Hostnames for VPC..."
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames "{\"Value\":true}" --region $AWS_REGION
echo "Enabling DNS Support for VPC..."
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-support "{\"Value\":true}" --region $AWS_REGION

echo "Creating Public Subnet 1 in ${AWS_REGION}a..."
PUBLIC_SUBNET_1=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block 10.0.1.0/24 --availability-zone "${AWS_REGION}a" --query Subnet.SubnetId --output text --region $AWS_REGION)
aws ec2 create-tags --resources "$PUBLIC_SUBNET_1" --tags Key=Name,Value="${PROJECT_NAME}-public-subnet-1" --region $AWS_REGION
echo "Subnet 1 Created: ${PUBLIC_SUBNET_1}"

echo "Creating Public Subnet 2 in ${AWS_REGION}b..."
PUBLIC_SUBNET_2=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block 10.0.2.0/24 --availability-zone "${AWS_REGION}b" --query Subnet.SubnetId --output text --region $AWS_REGION)
aws ec2 create-tags --resources "$PUBLIC_SUBNET_2" --tags Key=Name,Value="${PROJECT_NAME}-public-subnet-2" --region $AWS_REGION
echo "Subnet 2 Created: ${PUBLIC_SUBNET_2}"

echo "Creating Internet Gateway..."
IGW_ID=$(aws ec2 create-internet-gateway --query InternetGateway.InternetGatewayId --output text --region $AWS_REGION)
aws ec2 create-tags --resources "$IGW_ID" --tags Key=Name,Value="${PROJECT_NAME}-igw" --region $AWS_REGION
echo "Attaching Internet Gateway to VPC..."
aws ec2 attach-internet-gateway --vpc-id "$VPC_ID" --internet-gateway-id "$IGW_ID" --region $AWS_REGION
echo "Internet Gateway Attached."

echo "Creating Route Table..."
RT_ID=$(aws ec2 create-route-table --vpc-id "$VPC_ID" --query RouteTable.RouteTableId --output text --region $AWS_REGION)
aws ec2 create-tags --resources "$RT_ID" --tags Key=Name,Value="${PROJECT_NAME}-rt" --region $AWS_REGION
echo "Creating route to the Internet..."
aws ec2 create-route --route-table-id "$RT_ID" --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW_ID" --region $AWS_REGION > /dev/null
echo "Associating Route Table with Subnets..."
aws ec2 associate-route-table --subnet-id "$PUBLIC_SUBNET_1" --route-table-id "$RT_ID" --region $AWS_REGION > /dev/null
aws ec2 associate-route-table --subnet-id "$PUBLIC_SUBNET_2" --route-table-id "$RT_ID" --region $AWS_REGION > /dev/null
echo "Network setup complete."

# === 2. Security Groups & IAM ===
echo -e "\n${C_BLUE}--- Setting up Security Groups and IAM Role ---${C_NC}"
echo "Creating Security Group for Load Balancer..."
ALB_SG_ID=$(aws ec2 create-security-group --group-name "${PROJECT_NAME}-alb-sg" --description "SG for ALB" --vpc-id "$VPC_ID" --query GroupId --output text --region $AWS_REGION)
aws ec2 authorize-security-group-ingress --group-id "$ALB_SG_ID" --protocol tcp --port 8D --cidr 0.0.0.0/0 --region $AWS_REGION > /dev/null
echo "Load Balancer SG Created: ${ALB_SG_ID}"

echo "Creating Security Group for EC2 Instances..."
EC2_SG_ID=$(aws ec2 create-security-group --group-name "${PROJECT_NAME}-ec2-sg" --description "SG for EC2 instances" --vpc-id "$VPC_ID" --query GroupId --output text --region $AWS_REGION)
aws ec2 authorize-security-group-ingress --group-id "$EC2_SG_ID" --protocol tcp --port 80 --source-group "$ALB_SG_ID" --region $AWS_REGION > /dev/null
aws ec2 authorize-security-group-ingress --group-id "$EC2_SG_ID" --protocol tcp --port 22 --cidr 0.0.0.0/0 --region $AWS_REGION > /dev/null
echo "EC2 Instance SG Created: ${EC2_SG_ID}"

echo "Creating Security Group for Database..."
DB_SG_ID=$(aws ec2 create-security-group --group-name "${PROJECT_NAME}-db-sg" --description "SG for RDS DB" --vpc-id "$VPC_ID" --query GroupId --output text --region $AWS_REGION)
aws ec2 authorize-security-group-ingress --group-id "$DB_SG_ID" --protocol tcp --port 3306 --source-group "$EC2_SG_ID" --region $AWS_REGION > /dev/null
echo "Database SG Created: ${DB_SG_ID}"

echo "Creating IAM Role for EC2 Instances..."
IAM_ROLE_NAME="${PROJECT_NAME}-ec2-role"
TRUST_POLICY='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
aws iam create-role --role-name "$IAM_ROLE_NAME" --assume-role-policy-document "$TRUST_POLICY" --region $AWS_REGION > /dev/null
echo "Attaching S3 Full Access policy to IAM Role..."
aws iam attach-role-policy --role-name "$IAM_ROLE_NAME" --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess --region $AWS_REGION
echo "Creating IAM Instance Profile..."
IAM_INSTANCE_PROFILE_NAME="${PROJECT_NAME}-instance-profile"
aws iam create-instance-profile --instance-profile-name "$IAM_INSTANCE_PROFILE_NAME" --region $AWS_REGION > /dev/null
aws iam add-role-to-instance-profile --instance-profile-name "$IAM_INSTANCE_PROFILE_NAME" --role-name "$IAM_ROLE_NAME" --region $AWS_REGION
echo "Waiting for IAM role to propagate..."
sleep 15
echo "IAM setup complete."

# === 3. S3 Bucket and CloudFront CDN Setup ===
echo -e "\n${C_BLUE}--- Creating S3 Bucket & CloudFront CDN ---${C_NC}"
S3_BUCKET_NAME="ecommerce-static-assets-$RANDOM$RANDOM"
echo "Creating S3 Bucket: ${S3_BUCKET_NAME}..."
aws s3api create-bucket --bucket "$S3_BUCKET_NAME" --region "$AWS_REGION" --create-bucket-configuration LocationConstraint="$AWS_REGION" > /dev/null
echo "Creating CloudFront Origin Access Control (OAC)..."
OAC_ID=$(aws cloudfront create-origin-access-control --origin-access-control-config "Name=${PROJECT_NAME}-oac,OriginAccessControlOriginType=s3,SigningBehavior=always,SigningProtocol=sigv4" --query "OriginAccessControl.Id" --output text)
echo "Creating CloudFront Distribution..."
CF_DIST_DATA=$(aws cloudfront create-distribution --distribution-config "{\"Comment\":\"CDN for ${PROJECT_NAME}\",\"Enabled\":true,\"Origins\":{\"Quantity\":1,\"Items\":[{\"Id\":\"S3-${S3_BUCKET_NAME}\",\"DomainName\":\"${S3_BUCKET_NAME}.s3.${AWS_REGION}.amazonaws.com\",\"S3OriginConfig\":{\"OriginAccessIdentity\":\"\"},\"OriginAccessControlId\":\"${OAC_ID}\"}]},\"DefaultCacheBehavior\":{\"TargetOriginId\":\"S3-${S3_BUCKET_NAME}\",\"ViewerProtocolPolicy\":\"redirect-to-https\",\"AllowedMethods\":{\"Quantity\":2,\"Items\":[\"GET\",\"HEAD\"],\"CachedMethods\":{\"Quantity\":2,\"Items\":[\"GET\",\"HEAD\"]}},\"CachePolicyId\":\"658327ea-f89d-4fab-a63d-7e88639e58f6\"},\"CallerReference\":\"$(date +%s)\"}")
CF_DIST_ID=$(echo "$CF_DIST_DATA" | jq -r '.Distribution.Id')
CF_DOMAIN_NAME=$(echo "$CF_DIST_DATA" | jq -r '.Distribution.DomainName')
echo "CloudFront Distribution created: ${CF_DIST_ID}"
echo "Updating S3 Bucket Policy to restrict access to CloudFront..."
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
S3_POLICY="{\"Version\":\"2012-10-17\",\"Statement\":{\"Sid\":\"AllowCloudFrontServicePrincipal\",\"Effect\":\"Allow\",\"Principal\":{\"Service\":\"cloudfront.amazonaws.com\"},\"Action\":\"s3:GetObject\",\"Resource\":\"arn:aws:s3:::${S3_BUCKET_NAME}/*\",\"Condition\":{\"StringEquals\":{\"AWS:SourceArn\":\"arn:aws:cloudfront::${ACCOUNT_ID}:distribution/${CF_DIST_ID}\"}}}}"
aws s3api put-bucket-policy --bucket "$S3_BUCKET_NAME" --policy "$S3_POLICY" > /dev/null
echo "S3 and CDN setup complete."

# === 4. RDS MySQL Database (Free Tier) ===
echo -e "\n${C_BLUE}--- Provisioning Free Tier RDS MySQL Database ---${C_NC}"
DB_SUBNET_GROUP_NAME="${PROJECT_NAME}-db-subnet-group"
echo "Creating RDS DB Subnet Group..."
aws rds create-db-subnet-group --db-subnet-group-name "$DB_SUBNET_GROUP_NAME" --db-subnet-group-description "Subnet group for RDS" --subnet-ids "$PUBLIC_SUBNET_1" "$PUBLIC_SUBNET_2" --region $AWS_REGION > /dev/null
RDS_DB_ID="${PROJECT_NAME}-db"
echo "Creating RDS DB Instance (${RDS_INSTANCE_CLASS}) with MySQL version ${RDS_ENGINE_VERSION}. This may take 5-10 minutes..."
aws rds create-db-instance \
    --db-instance-identifier "$RDS_DB_ID" \
    --db-instance-class "$RDS_INSTANCE_CLASS" \
    --engine mysql \
    --engine-version "$RDS_ENGINE_VERSION" \
    --allocated-storage 20 \
    --db-name ecommercedb \
    --master-username admin \
    --master-user-password "$DB_MASTER_PASS" \
    --vpc-security-group-ids "$DB_SG_ID" \
    --db-subnet-group-name "$DB_SUBNET_GROUP_NAME" \
    --no-multi-az \
    --publicly-accessible \
    --region $AWS_REGION > /dev/null
echo "Waiting for RDS instance to become available..."
aws rds wait db-instance-available --db-instance-identifier "$RDS_DB_ID" --region $AWS_REGION
RDS_ENDPOINT=$(aws rds describe-db-instances --db-instance-identifier "$RDS_DB_ID" --query "DBInstances[0].Endpoint.Address" --output text --region $AWS_REGION)
echo "RDS Database is available at: ${RDS_ENDPOINT}"

# === 5. Application Setup (Launch Template & Auto Scaling Group) ===
echo -e "\n${C_BLUE}--- Creating Launch Template and Auto Scaling Group ---${C_NC}"
echo "Creating EC2 Key Pair..."
if [ ! -f "${KEY_NAME}.pem" ]; then
    aws ec2 create-key-pair --key-name "$KEY_NAME" --query "KeyMaterial" --output text --region $AWS_REGION > "${KEY_NAME}.pem"; chmod 400 "${KEY_NAME}.pem"
    echo "Key Pair '${KEY_NAME}.pem' created."
else
    echo "Key Pair '${KEY_NAME}.pem' already exists."
fi

echo "Creating EC2 Launch Template..."
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

(
  flock -n 200 || exit 1
  aws s3 cp /var/www/html/${APP_FOLDER_NAME}/assets s3://${S3_BUCKET_NAME}/assets --recursive --region ${AWS_REGION}
) 200>/var/lock/s3_upload.lock

CONFIG_FILE="/var/www/html/${APP_FOLDER_NAME}/admin/inc/config.php"
sed -i "s|\\\$dbhost = '.*';|\\\$dbhost = '${RDS_ENDPOINT}';|" \$CONFIG_FILE
sed -i "s|\\\$dbname = '.*';|\\\$dbname = 'ecommercedb';|" \$CONFIG_FILE
sed -i "s|\\\$dbuser = '.*';|\\\$dbuser = 'admin';|" \$CONFIG_FILE
sed -i "s|\\\$dbpass = '.*';|\\\$dbpass = '${DB_MASTER_PASS}';|" \$CONFIG_FILE

CLOUDFRONT_ASSET_URL="https://${CF_DOMAIN_NAME}/assets/"
find /var/www/html/${APP_FOLDER_NAME}/ -type f -name "*.php" -exec sed -i "s|../assets/|\${CLOUDFRONT_ASSET_URL}|g" {} +
find /var/www/html/${APP_FOLDER_NAME}/ -type f -name "*.php" -exec sed -i "s|assets/|\${CLOUDFRONT_ASSET_URL}|g" {} +

(
  flock -n 201 || exit 1
  mysql -h "${RDS_ENDPOINT}" -u "admin" -p"${DB_MASTER_PASS}" "ecommercedb" < /var/www/html/database/fashiony_ogs.sql
  mysql -h "${RDS_ENDPOINT}" -u "admin" -p"${DB_MASTER_PASS}" "ecommercedb" -e "UPDATE settings SET footer_text = '' WHERE footer_text LIKE '%Virtual University%';"
) 201>/var/lock/db_import.lock

chown -R www-data:www-data /var/www/html
systemctl restart apache2
EOF
)
LT_ID=$(aws ec2 create-launch-template \
    --launch-template-name "${PROJECT_NAME}-lt" \
    --version-description "Initial version" \
    --launch-template-data "{\"ImageId\":\"$AMI_ID\",\"InstanceType\":\"$INSTANCE_TYPE\",\"KeyName\":\"$KEY_NAME\",\"SecurityGroupIds\":[\"$EC2_SG_ID\"],\"IamInstanceProfile\":{\"Name\":\"$IAM_INSTANCE_PROFILE_NAME\"},\"UserData\":\"$(echo "$USER_DATA" | base64 -w 0)\",\"NetworkInterfaces\":[{\"AssociatePublicIpAddress\":true,\"DeviceIndex\":0,\"Groups\":[\"$EC2_SG_ID\"]}]}" \
    --query "LaunchTemplate.LaunchTemplateId" --output text --region $AWS_REGION)
echo "Launch Template Created: ${LT_ID}"

echo "Creating Auto Scaling Group..."
ASG_NAME="${PROJECT_NAME}-asg"
aws autoscaling create-auto-scaling-group \
    --auto-scaling-group-name "$ASG_NAME" \
    --launch-template "LaunchTemplateId=$LT_ID" \
    --min-size 1 \
    --max-size 3 \
    --desired-capacity 2 \
    --vpc-zone-identifier "$PUBLIC_SUBNET_1,$PUBLIC_SUBNET_2" \
    --region $AWS_REGION
echo "Auto Scaling Group Created."

# === 6. Load Balancer Setup ===
echo -e "\n${C_BLUE}--- Creating Application Load Balancer ---${C_NC}"
echo "Creating Load Balancer..."
ALB_ARN=$(aws elbv2 create-load-balancer --name "${PROJECT_NAME}-alb" --subnets "$PUBLIC_SUBNET_1" "$PUBLIC_SUBNET_2" --security-groups "$ALB_SG_ID" --query "LoadBalancers[0].LoadBalancerArn" --output text --region $AWS_REGION)
echo "Creating Target Group..."
TG_ARN=$(aws elbv2 create-target-group --name "${PROJECT_NAME}-tg" --protocol HTTP --port 8D --vpc-id "$VPC_ID" --health-check-path "/${APP_FOLDER_NAME}/index.php" --query "TargetGroups[0].TargetGroupArn" --output text --region $AWS_REGION)
echo "Attaching Target Group to Auto Scaling Group..."
aws autoscaling attach-load-balancer-target-groups --auto-scaling-group-name "$ASG_NAME" --target-group-arns "$TG_ARN" --region $AWS_REGION
echo "Creating Load Balancer Listener..."
aws elbv2 create-listener --load-balancer-arn "$ALB_ARN" --protocol HTTP --port 80 --default-actions "Type=forward,TargetGroupArn=$TG_ARN" --region $AWS_REGION > /dev/null
echo "Load Balancer setup complete."

# === 7. Finalization ===
echo -e "\n${C_BLUE}--- Finalizing Deployment ---${C_NC}"
echo "Waiting for CloudFront distribution to deploy... (This may take 5-15 minutes)"
aws cloudfront wait distribution-deployed --id "$CF_DIST_ID"
echo "CloudFront deployed."

ALB_DNS=$(aws elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" --query "LoadBalancers[0].DNSName" --output text --region $AWS_REGION)
echo -e "\n${C_GREEN}### ✅ AUTO SCALING DEMO DEPLOYMENT COMPLETE! ###${C_NC}"
echo -e "Access your load-balanced application at: ${C_YELLOW}http://${ALB_DNS}/${APP_FOLDER_NAME}/${C_NC}"
echo -e "\nTo demonstrate Auto Scaling:"
echo -e "1. Go to the AWS Console -> EC2 -> Auto Scaling Groups."
echo -e "2. Select '${ASG_NAME}' and go to the 'Instance management' tab."
echo -e "3. Select one of the running instances and choose 'Actions' -> 'Terminate instance'."
echo -e "4. Refresh the list after a minute. You will see the ASG automatically launching a new instance to replace it!"
echo -e "\n${C_YELLOW}IMPORTANT: Remember to run the cleanup script to delete all resources and avoid charges.${C_NC}"