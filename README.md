# PHP eCommerce AWS Deployment Guide

This repository contains a fully-automated deployment script to host a PHP-based eCommerce application on AWS using a scalable, highly-available, and cost-effective architecture.

## 🏗️ Architecture Overview

- **Application Load Balancer (ALB)** – Distributes incoming HTTP traffic.
- **Auto Scaling Group (ASG)** – Manages EC2 instances for high availability and scaling.
- **EC2 Instances** – Runs the PHP eCommerce application.
- **Amazon RDS (MySQL)** – Managed, Free Tier-eligible MySQL database.
- **Amazon S3** – Stores static assets like images, CSS, JS.
- **Amazon CloudFront** – Speeds up delivery of static content via CDN.

---

## 🚀 Deployment Instructions

### ✅ Recommended: Deploy using AWS CloudShell

1. **Login to the AWS Console** and switch to the `ap-south-1` (Mumbai) region.
2. Launch **CloudShell** by clicking the `>_` icon on the top navigation bar.
3. Clone your repository:
   
   git clone https://github.com/ganeshvissapragada/cloud_see.git
   cd cloud_see
   
4 .Make the deployment script executable:
    
  chmod +x scripts/deploy_ha_ecommerce.sh

5.Run the deployment script:

  ./scripts/deploy_ha_ecommerce.sh

6.Follow the on-screen prompts:

Enter your GitHub repository URL.

https://github.com/ganeshvissapragada/cloud_see.git

Enter a secure password for the MySQL database.

⏳ The deployment process takes 20–25 minutes. Do not close CloudShell during this time.

7.Cleanup (Important!)
AWS services like RDS and EC2 may incur charges if not removed. Run the cleanup script after you're done.

Make the cleanup script executable:
chmod +x scripts/cleanup_ha.sh
Run the cleanup script:
./scripts/cleanup_ha.sh







