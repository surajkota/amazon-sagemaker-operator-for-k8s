#!/usr/bin/env bash

# Helper script to generate an IAM Role needed to install operator using role-based authentication.
# https://sagemaker.readthedocs.io/en/stable/amazon_sagemaker_operators_for_kubernetes.html#create-an-iam-role
#
# Run as:
# $ ./generate_iam_role.sh ${cluster_arn/cluster_name} ${operator_namespace} ${role_name} ${cluster_region}
#

CLUSTER_ARN="${1}"
OPERATOR_NAMESPACE="${2}"
ROLE_NAME="${3}"
CLUSTER_REGION="${4:-us-east-1}"
aws_account=$(aws sts get-caller-identity --query Account --output text)
trustfile="trust.json"

# if using an existing cluster, use the cluster arn to get the region and cluster name
# example, cluster_arn=arn:aws:eks:us-east-1:12345678910:cluster/test
cluster_name=$(echo ${CLUSTER_ARN} | cut -d'/' -f2)

# A function to get the OIDC_ID associated with an EKS cluster
function get_oidc_id {
    # TODO: Ideally this should be based on version compatibility instead of command failure
    eksctl utils associate-iam-oidc-provider --cluster ${cluster_name} --region ${CLUSTER_REGION} --approve
    if [[ $? -ge 1 ]]; then
        eksctl utils associate-iam-oidc-provider --name ${cluster_name} --region ${CLUSTER_REGION} --approve
    fi
    
    local oidc=$(aws eks describe-cluster --name ${cluster_name} --region ${CLUSTER_REGION} --query cluster.identity.oidc.issuer --output text)
    oidc_id=$(echo ${oidc} | rev | cut -d'/' -f1 | rev)
}

# A function that generates an IAM role for the given account, cluster, namespace, region
# Parameter:
#    $1: Name of the trust file to generate.
function create_namespaced_iam_role {
    local trustfile="${1}"
    # Check if role already exists
    aws iam get-role --role-name ${ROLE_NAME}
    if [[ $? -eq 0 ]]; then
        echo "A role for this cluster and namespace already exists in this account, assuming sagemaker access and proceeding."
    else
        echo "IAM Role does not exist, creating a new Role for the cluster"
        aws iam create-role --role-name ${ROLE_NAME} --assume-role-policy-document file://${trustfile} --output=text
        aws iam attach-role-policy --role-name ${ROLE_NAME}  --policy-arn arn:aws:iam::aws:policy/AmazonSageMakerFullAccess
    fi
}

# Remove the generated trust file
# Parameter:
#    $1: Name of the trust file to delete.
function delete_generated_file {
    rm "${1}" 
}

echo "Get the OIDC ID for the cluster"
get_oidc_id
echo "Delete the trust json file if it already exists"
delete_generated_file "${trustfile}"
echo "Generate a trust json"
./generate_trust_policy.sh ${CLUSTER_REGION} ${aws_account} ${oidc_id} ${OPERATOR_NAMESPACE} > "${trustfile}"
echo "Create the IAM Role using these values"
create_namespaced_iam_role "${trustfile}"
echo "Cleanup for the next run!"
delete_generated_file "${trustfile}"

