#!/bin/bash -e

export CDK_PARAM_SYSTEM_ADMIN_EMAIL="$1"

if [[ -z "$CDK_PARAM_SYSTEM_ADMIN_EMAIL" ]]; then
  echo "Please provide system admin email"
  exit 1
fi

REGION=$(aws ec2 describe-availability-zones --output text --query 'AvailabilityZones[0].[RegionName]')  # Region setting
export CDK_PARAM_S3_BUCKET_NAME="saas-reference-architecture-ecs-$REGION"

# Create S3 Bucket for provision source.

if aws s3api head-bucket --bucket $CDK_PARAM_S3_BUCKET_NAME 2>/dev/null; then
    echo "Bucket $CDK_PARAM_S3_BUCKET_NAME already exists."
else
    echo "Bucket $CDK_PARAM_S3_BUCKET_NAME does not exist. Creating a new bucket in $REGION region"

    if [ "$REGION" == "us-east-1" ]; then
      aws s3api create-bucket --bucket $CDK_PARAM_S3_BUCKET_NAME
    else
      aws s3api create-bucket \
        --bucket $CDK_PARAM_S3_BUCKET_NAME \
        --region "$REGION" \
        --create-bucket-configuration LocationConstraint="$REGION" 
    fi

    aws s3api put-bucket-versioning \
        --bucket $CDK_PARAM_S3_BUCKET_NAME \
        --versioning-configuration Status=Enabled

    aws s3api put-public-access-block \
        --bucket $CDK_PARAM_S3_BUCKET_NAME \
        --public-access-block-configuration \
        BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true    

    if [ $? -eq 0 ]; then
        echo "Bucket $CDK_PARAM_S3_BUCKET_NAME created with versioning enabled."
    else
        echo "Error creating bucket $CDK_PARAM_S3_BUCKET_NAME with versioning enabled."
        exit 1
    fi
fi

echo "Bucket exists2: $CDK_PARAM_S3_BUCKET_NAME"

cd ../
zip -r source.zip . -x ".git/*" -x "**/node_modules/*" -x "**/cdk.out/*" -x "**/.aws-sam/*"
export CDK_PARAM_COMMIT_ID=$(aws s3api put-object --bucket "${CDK_PARAM_S3_BUCKET_NAME}" --key "source.zip" --body "./source.zip"  --output text)

rm source.zip
echo "Source code uploaded to S3"

# Create ECS service linked role.
aws iam create-service-linked-role --aws-service-name ecs.amazonaws.com 2>/dev/null || echo "ECS Service linked role exists"

# Preprovision basic infrastructure
cd ./server

export ECR_REGION=$(aws ec2 describe-availability-zones --output text --query 'AvailabilityZones[0].[RegionName]')
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
sed "s/<REGION>/$ECR_REGION/g; s/<ACCOUNT_ID>/$ACCOUNT_ID/g" ./service-info.txt > ./lib/service-info.json

npm install

# npx cdk bootstrap
export CDK_PARAM_ONBOARDING_DETAIL_TYPE='Onboarding'
export CDK_PARAM_PROVISIONING_DETAIL_TYPE=$CDK_PARAM_ONBOARDING_DETAIL_TYPE
export CDK_PARAM_OFFBOARDING_DETAIL_TYPE='Offboarding'
export CDK_PARAM_DEPROVISIONING_DETAIL_TYPE=$CDK_PARAM_OFFBOARDING_DETAIL_TYPE
export CDK_PARAM_TIER='basic'

npx cdk bootstrap
npx cdk deploy --all --require-approval never #--concurrency 10 --asset-parallelism true 

# Get SaaS application url
ADMIN_SITE_URL=$(aws cloudformation describe-stacks --stack-name controlplane-stack --query "Stacks[0].Outputs[?OutputKey=='adminSiteUrl'].OutputValue" --output text)
APP_SITE_URL=$(aws cloudformation describe-stacks --stack-name core-appplane-stack --query "Stacks[0].Outputs[?OutputKey=='appSiteUrl'].OutputValue" --output text)
echo "Admin site url: $ADMIN_SITE_URL"
echo "Application site url: $APP_SITE_URL"