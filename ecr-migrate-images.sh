# Purpose: Migrate images from one ECR repo to another, specifically useful
# when dealing with multi-arch images.

set -e

################################# UPDATE THESE #################################

SRC_AWS_REGION="aws-region"
SRC_AWS_PROFILE="aws-profile"
SRC_BASE_PATH="aws-account-id.dkr.ecr.$SRC_AWS_REGION.amazonaws.com"
OLD_REPO="old-repo-name"
NEW_REPO="new-repo-name"

#################################################################################

URI=($(aws ecr describe-repositories --profile $SRC_AWS_PROFILE --query 'repositories[].repositoryUri' --output text --region $SRC_AWS_REGION))
NAME=($(aws ecr describe-repositories  --profile $SRC_AWS_PROFILE --query 'repositories[].repositoryName' --output text --region $SRC_AWS_REGION))
IMAGE_COUNT=0

echo "Start copying repos: `date`"

# Login to skopeo
aws ecr get-login-password --profile ${SRC_AWS_PROFILE} --region ${SRC_AWS_REGION} | skopeo login --username AWS --password-stdin ${SRC_BASE_PATH}

# Get tagged images
JSON=$(aws ecr describe-images --repository-name ${OLD_REPO} \
  --filter tagStatus=TAGGED --output json \
  --region $SRC_AWS_REGION \
  --profile $SRC_AWS_PROFILE);

# Loop through tagged images
for image in $(echo "$JSON" | jq -c '.imageDetails[]'); do
    IMAGE_COUNT=$((IMAGE_COUNT+1));
    IMAGE_TAGS=$(echo "$image" | jq -c '.imageTags')
    IMAGE_TAG=$(echo "$image" | jq -c '.imageTags[0]' | tr -d '"')

    # Determine if image exists in new repo
    IMAGE_META="$( aws ecr describe-images \
      --repository-name=${NEW_REPO} \
      --image-ids=imageTag=$IMAGE_TAG \
      --profile $SRC_AWS_PROFILE \
      --region $SRC_AWS_REGION 2> /dev/null || :)"

    echo "\n\nprocessing image ${IMAGE_COUNT}: ${SRC_BASE_PATH}/${OLD_REPO}:$IMAGE_TAG"

    if [[ $IMAGE_META ]]; then
      echo "Skip ${SRC_BASE_PATH}/${OLD_REPO}:$IMAGE_TAG, already exists"
    else
      IMAGES_TO_TAG=""

      # Store a list of images to be tagged to be used in the buildx below
      for imageTag in $(echo "$image" | jq -c '.imageTags[]' | tr -d '"'); do
          IMAGES_TO_TAG+=" -t ${SRC_BASE_PATH}/${NEW_REPO}:${imageTag}"
      done

      # Copy all to a new repo
      echo "Copying ${SRC_BASE_PATH}/${OLD_REPO}:$IMAGE_TAG to new repo"
      skopeo copy --all docker://${SRC_BASE_PATH}/${OLD_REPO}:$IMAGE_TAG docker://${SRC_BASE_PATH}/${NEW_REPO}:$IMAGE_TAG

      # Update the manifest with all the appropriate tags
      echo "Retagging new image ${SRC_BASE_PATH}/${NEW_REPO}:$IMAGE_TAG with $IMAGE_TAGS"
      docker buildx imagetools create ${IMAGES_TO_TAG} ${SRC_BASE_PATH}/${NEW_REPO}:$IMAGE_TAG
    fi
done