#!/bin/bash
INITIAL_WORKING_DIRECTORY=$(pwd)
KUBECTL=kubectl
# This line changes to current working directory to where run.sh is
cd "$(dirname "$0")"

function usage()
{
    echo "sets up addon applications in kubernetes using helm"
    echo ""
    echo "./run.sh"
    echo "\t-e | --environment=dev-private"
    echo "\t-c | --aws-k8s-cluster=uip"
    echo "\t-r | --aws-region=us-west-2"
    echo "\t-au | --artifactory-user=xyz"
    echo "\t-ap | --artifactory-password=pass"
    echo "\t-u | --update-route53 (optional)"
    echo ""
    exit 1
}

while [ "$1" != "" ]; do
    PARAM=`echo $1 | awk -F= '{print $1}'`
    VALUE=`echo $1 | awk -F= '{print $2}'`
    case $PARAM in
        -h | --help)
            usage
            exit
            ;;
        -e | --environment)
            ENVIRONMENT=$VALUE
            ;;
        -r | --aws-region)
            AWS_REGION=$VALUE
            ;;
        -c | --aws-k8s-cluster)
            AWS_K8S_CLUSTER=$VALUE
            ;;
        -u | --update-route53)
            UPDATE_ROUTE53=true
            ;;
        -au | --artifactory-user)
            ARTIFACTORY_USER=$VALUE
            ;;
        -ap | --artifactory-password)
            ARTIFACTORY_PASSWORD=$VALUE
            ;;
        *)
            echo "ERROR: unknown parameter \"$PARAM\""
            usage
            exit 1
            ;;
    esac
    shift
done


if [ -z $ENVIRONMENT ] || [ -z $AWS_K8S_CLUSTER ] || [ -z $AWS_REGION ] || [ -z $ARTIFACTORY_USER ] || [ -z $ARTIFACTORY_PASSWORD ]; then
    usage
fi

ARTIFACTORY_URL=gdartifactory1.jfrog.io

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
if [ $? -ne 0 ]; then
  echo "fail to fetch the aws account id"
  exit 255
fi

verifyExitCode() {
    if [ $1 -ne 0 ]; then
        exit $1
    fi
}

helm_add_repos() {
    helm repo add incubator https://charts.helm.sh/incubator
    helm repo add stable https://charts.helm.sh/stable
    helm repo add bitnami https://charts.bitnami.com/bitnami
    helm repo add eks https://aws.github.io/eks-charts
    helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
    helm repo add aws-ebs-csi-driver https://kubernetes-sigs.github.io/aws-ebs-csi-driver
    helm repo add sonarqube https://SonarSource.github.io/helm-chart-sonarqube
    helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/
    helm repo add elastic https://helm.elastic.co
    helm repo update
}

setup_kubectl_context() {
    retry=0
    until [ "$retry" -ge 10 ]
    do
        aws --region ${AWS_REGION} eks update-kubeconfig --name ${AWS_K8S_CLUSTER} --alias ${AWS_K8S_CLUSTER} && \
        break
       retry=$((retry+1))
       echo "sleeping for 60 seconds before next retry..."
       sleep 60
    done

    # fail if max retries reached
    if [ "$retry" -ge 10 ]; then
        exit 1
    fi
}

deploy_alb_ingress_controller() {
    AWS_LOAD_BALANCER_VERSION=v2.5.1

    if [ "${ENVIRONMENT}" == "prod" ]; then
        helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller --debug \
        -n kube-system \
        --set enableWaf=false \
        --set enableWafv2=true \
        --set enableShield=false \
        --set image.tag=${AWS_LOAD_BALANCER_VERSION} \
        --set replicaCount=2 \
        --set clusterName=${AWS_K8S_CLUSTER} \
        --set serviceAccount.create=false \
        --set serviceAccount.name=${AWS_K8S_CLUSTER}-alb-${AWS_REGION} \
        --set podDisruptionBudget.maxUnavailable=1 \
        --set enableServiceMutatorWebhook=false
    else
    helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller --debug \
        -n kube-system \
        --set enableWaf=false \
        --set enableWafv2=true \
        --set enableShield=false \
        --set image.tag=${AWS_LOAD_BALANCER_VERSION} \
        --set replicaCount=1 \
        --set clusterName=${AWS_K8S_CLUSTER} \
        --set serviceAccount.create=false \
        --set serviceAccount.name=${AWS_K8S_CLUSTER}-alb-${AWS_REGION} \
        --set enableServiceMutatorWebhook=false
    fi

    verifyExitCode $?
}

deploy_ingress_rules() {
    # label uip namespace for readiness gate. Pods will not be registered by Load Balancer(ALB) unless ready.
    $KUBECTL label namespace uip elbv2.k8s.aws/pod-readiness-gate-inject=enabled --overwrite

    WAFV2_ACL_ARN=$(aws ssm get-parameters --names "/Team/WAFv2/Regional/UIP/WebACLArn" --query "Parameters[0].Value" --region=${AWS_REGION})
    WAFV2_ACL_UIP_PUBLIC_ARN=$(aws ssm get-parameters --names "/Team/WAFv2/Regional/UIP-public/WebACLArn" --query "Parameters[0].Value" --region=${AWS_REGION})
    WAFV2_ACL_ASP_PUBLIC_ARN=$(aws ssm get-parameters --names "/Team/WAFv2/Regional/ASP-public/WebACLArn" --query "Parameters[0].Value" --region=${AWS_REGION})
    DxAppSubnets=$(aws ssm get-parameters --names "/AdminParams/VPC/DxAppSubnets" --query "Parameters[0].Value" --region=${AWS_REGION})

    if [ "${ENVIRONMENT}" == "dev-private" ] && [ "${AWS_REGION}" == "us-west-2" ]; then
          DxAppSubnets=subnet-0f7c7bc429352c455,subnet-0574fca27158b3a4e
    fi
    PublicSubnets=$(aws ssm get-parameters --names "/AdminParams/VPC/PublicSubnets" --query "Parameters[0].Value" --region=${AWS_REGION})

    echo "now deploying ingress resource for environment=${ENVIRONMENT} and applying DX App subnets -> ${DxAppSubnets}, wafV2 arn -> ${WAFV2_ACL_ARN}"
    echo "Public subnets -> ${PublicSubnets}, public uip wafV2 arn -> ${WAFV2_ACL_UIP_PUBLIC_ARN}, public asp wafV2 arn -> ${WAFV2_ACL_ASP_PUBLIC_ARN}"


    DNS_RECORD_ENVIRONMENT="${ENVIRONMENT}"
    if [ "${ENVIRONMENT}" == "dev-private" ]; then
        DNS_RECORD_ENVIRONMENT="dp"
    fi
    helm --debug upgrade --install --atomic --namespace uip \
        --set subnets=${DxAppSubnets//,/\\,} \
        --set environment=${ENVIRONMENT} \
        --set dns_environment=${DNS_RECORD_ENVIRONMENT} \
        --set wafv2ACLArn=${WAFV2_ACL_ARN} \
        --set aws.region=${AWS_REGION} \
        --set cluster_name=${AWS_K8S_CLUSTER} \
        --set access_logs.s3bucket=gd-userinsigh-${ENVIRONMENT}-uip-alb-access-logs-v2-${AWS_REGION} \
        ingress-rules ingress
    verifyExitCode $?

    # uip ingress rules for internet-facing load balancer
    if [ "${ENVIRONMENT}" == "prod" ]; then
        helm --debug upgrade --install --atomic --namespace uip \
            --set subnets=${PublicSubnets//,/\\,} \
            --set environment=${ENVIRONMENT} \
            --set dns_environment=${DNS_RECORD_ENVIRONMENT} \
            --set wafv2ACLArn=${WAFV2_ACL_UIP_PUBLIC_ARN} \
            --set aws.region=${AWS_REGION} \
            --set cluster_name=${AWS_K8S_CLUSTER} \
            --set access_logs.s3bucket=gd-userinsigh-${ENVIRONMENT}-uip-alb-access-logs-v2-${AWS_REGION} \
            ingress-rules-public ingress-public
        verifyExitCode $?
    fi

    helm --debug upgrade --install --atomic --namespace uip \
        --set subnets=${DxAppSubnets//,/\\,} \
        --set environment=${ENVIRONMENT} \
        --set dns_environment=${DNS_RECORD_ENVIRONMENT} \
        --set wafv2ACLArn=${WAFV2_ACL_ARN} \
        --set aws.region=${AWS_REGION} \
        --set cluster_name=${AWS_K8S_CLUSTER} \
        --set access_logs.s3bucket=gd-userinsigh-${ENVIRONMENT}-uip-alb-access-logs-v2-${AWS_REGION} \
        keychain-ingress-rules keychain-ingress
    verifyExitCode $?

    if [ "${AWS_REGION}" == "us-west-2" ]; then
        helm --debug upgrade --install --atomic --namespace uip \
            --set subnets=${DxAppSubnets//,/\\,} \
            --set environment=${ENVIRONMENT} \
            --set dns_environment=${DNS_RECORD_ENVIRONMENT} \
            --set wafv2ACLArn=${WAFV2_ACL_ARN} \
            --set aws.region=${AWS_REGION} \
            --set cluster_name=${AWS_K8S_CLUSTER} \
            --set regional_endpoint.suffix="-us-west-2" \
            --set access_logs.s3bucket=gd-userinsigh-${ENVIRONMENT}-uip-alb-access-logs-v2-${AWS_REGION} \
            keychain-uswest2-ingress-rules keychain-ingress
        verifyExitCode $?
    fi

    if [ "${AWS_REGION}" == "us-east-1" ]; then
        helm --debug upgrade --install --atomic --namespace uip \
            --set subnets=${DxAppSubnets//,/\\,} \
            --set environment=${ENVIRONMENT} \
            --set dns_environment=${DNS_RECORD_ENVIRONMENT} \
            --set wafv2ACLArn=${WAFV2_ACL_ARN} \
            --set aws.region=${AWS_REGION} \
            --set cluster_name=${AWS_K8S_CLUSTER} \
            --set regional_endpoint.suffix="-us-east-1" \
            --set access_logs.s3bucket=gd-userinsigh-${ENVIRONMENT}-uip-alb-access-logs-v2-${AWS_REGION} \
            keychain-useast1-ingress-rules keychain-ingress
        verifyExitCode $?
    fi

    # below 3 ingress rules are for asp-data-access-impl service (internal)
    helm --debug upgrade --install --atomic --namespace uip \
        --set subnets=${DxAppSubnets//,/\\,} \
        --set environment=${ENVIRONMENT} \
        --set dns_environment=${DNS_RECORD_ENVIRONMENT} \
        --set wafv2ACLArn=${WAFV2_ACL_ARN} \
        --set aws.region=${AWS_REGION} \
        --set cluster_name=${AWS_K8S_CLUSTER} \
        --set access_logs.s3bucket=gd-userinsigh-${ENVIRONMENT}-uip-alb-access-logs-v2-${AWS_REGION} \
        asp-segments-ingress-rules asp-segments-ingress
    verifyExitCode $?

    if [ "${AWS_REGION}" == "us-west-2" ]; then
        helm --debug upgrade --install --atomic --namespace uip \
            --set subnets=${DxAppSubnets//,/\\,} \
            --set environment=${ENVIRONMENT} \
            --set dns_environment=${DNS_RECORD_ENVIRONMENT} \
            --set wafv2ACLArn=${WAFV2_ACL_ARN} \
            --set aws.region=${AWS_REGION} \
            --set cluster_name=${AWS_K8S_CLUSTER} \
            --set regional_endpoint.suffix="-us-west-2" \
            --set access_logs.s3bucket=gd-userinsigh-${ENVIRONMENT}-uip-alb-access-logs-v2-${AWS_REGION} \
            asp-segments-uswest2-ingress-rules asp-segments-ingress
        verifyExitCode $?
    fi

    if [ "${AWS_REGION}" == "us-east-1" ]; then
        helm --debug upgrade --install --atomic --namespace uip \
            --set subnets=${DxAppSubnets//,/\\,} \
            --set environment=${ENVIRONMENT} \
            --set dns_environment=${DNS_RECORD_ENVIRONMENT} \
            --set wafv2ACLArn=${WAFV2_ACL_ARN} \
            --set aws.region=${AWS_REGION} \
            --set cluster_name=${AWS_K8S_CLUSTER} \
            --set regional_endpoint.suffix="-us-east-1" \
            --set access_logs.s3bucket=gd-userinsigh-${ENVIRONMENT}-uip-alb-access-logs-v2-${AWS_REGION} \
            asp-segments-useast1-ingress-rules asp-segments-ingress
        verifyExitCode $?
    fi


    if [ "${AWS_REGION}" == "us-west-2" ]; then
            helm --debug upgrade --install --atomic --namespace uip \
                --set subnets=${DxAppSubnets//,/\\,} \
                --set environment=${ENVIRONMENT} \
                --set dns_environment=${DNS_RECORD_ENVIRONMENT} \
                --set wafv2ACLArn=${WAFV2_ACL_ARN} \
                --set aws.region=${AWS_REGION} \
                --set cluster_name=${AWS_K8S_CLUSTER} \
                --set regional_endpoint.suffix="-us-west-2" \
                --set access_logs.s3bucket=gd-userinsigh-${ENVIRONMENT}-uip-alb-access-logs-v2-${AWS_REGION} \
                uip-data-access-uswest2-ingress-rules uip-data-access-ingress
            verifyExitCode $?
        fi

        if [ "${AWS_REGION}" == "us-east-1" ]; then
            helm --debug upgrade --install --atomic --namespace uip \
                --set subnets=${DxAppSubnets//,/\\,} \
                --set environment=${ENVIRONMENT} \
                --set dns_environment=${DNS_RECORD_ENVIRONMENT} \
                --set wafv2ACLArn=${WAFV2_ACL_ARN} \
                --set aws.region=${AWS_REGION} \
                --set cluster_name=${AWS_K8S_CLUSTER} \
                --set regional_endpoint.suffix="-us-east-1" \
                --set access_logs.s3bucket=gd-userinsigh-${ENVIRONMENT}-uip-alb-access-logs-v2-${AWS_REGION} \
                uip-data-access-useast1-ingress-rules uip-data-access-ingress
            verifyExitCode $?
        fi

    # ingress rules for ASP client facing services (public)
    helm --debug upgrade --install --atomic --namespace uip \
        --set subnets=${PublicSubnets//,/\\,} \
        --set environment=${ENVIRONMENT} \
        --set dns_environment=${DNS_RECORD_ENVIRONMENT} \
        --set wafv2ACLArn=${WAFV2_ACL_ASP_PUBLIC_ARN} \
        --set aws.region=${AWS_REGION} \
        --set cluster_name=${AWS_K8S_CLUSTER} \
        --set access_logs.s3bucket=gd-userinsigh-${ENVIRONMENT}-uip-alb-access-logs-v2-${AWS_REGION} \
        asp-ingress-rules asp-ingress
    verifyExitCode $?


    helm --debug upgrade --install --atomic --namespace uip \
        --set subnets=${DxAppSubnets//,/\\,} \
        --set environment=${ENVIRONMENT} \
        --set dns_environment=${DNS_RECORD_ENVIRONMENT} \
        --set wafv2ACLArn=${WAFV2_ACL_ARN} \
        --set aws.region=${AWS_REGION} \
        --set cluster_name=${AWS_K8S_CLUSTER} \
        --set external_endpoint.prefix="ext." \
        --set access_logs.s3bucket=gd-userinsigh-${ENVIRONMENT}-uip-alb-access-logs-v2-${AWS_REGION} \
        ext-ingress-rules ingress
    verifyExitCode $?
}

deploy_namespace() {
    echo "creating namespace for uip"
    $KUBECTL apply -f namespace/uip-namespace.yaml
}

deploy_fluentbit() {
    helm --debug upgrade --install --atomic --namespace fluentbit \
        --set environment=${ENVIRONMENT} \
        --set aws_region=${AWS_REGION} \
        --set cluster_name=${AWS_K8S_CLUSTER} \
      uip-fluentbit fluentbit --timeout 5m
    verifyExitCode $?
}

deploy_cluster_autoscaler() {
    echo "installing cluster autoscaler"
    helm --debug upgrade --install --atomic --namespace kube-system \
        --set aws_region=${AWS_REGION} \
        --set cluster_name=${AWS_K8S_CLUSTER} \
      uip-cluster-autoscaler cluster-autoscaler --timeout 2m
    verifyExitCode $?
}

deploy_metricbeat() {
    echo "installing metricbeat"
    helm upgrade --install --atomic --set aws.region=${AWS_REGION} --namespace kube-system metricbeat metricbeat --timeout 10m
    verifyExitCode $?
}

deploy_ebs_csi_driver() {
    if [ "${ENVIRONMENT}" == "dev-private" ]; then
        echo "installing aws ebs csi driver"
        helm upgrade --install aws-ebs-csi-driver \
            --version=2.26.0 \
            --namespace kube-system \
            --set controller.serviceAccount.create=false \
            --set node.serviceAccount.create=false \
            --set enableVolumeScheduling=true \
            --set enableVolumeResizing=true \
            --set enableVolumeSnapshot=true \
            --set node.serviceAccount.name=ebs-csi-controller-${AWS_REGION} \
            --set controller.serviceAccount.name=ebs-csi-controller-${AWS_REGION} \
        aws-ebs-csi-driver/aws-ebs-csi-driver --timeout 2m
    else
        echo "skip installing ebs csi driver"
    fi
}

setup_essp_secrets() {
    $KUBECTL get secrets/apm-credentials --namespace kube-system
    if [ $? -ne 0 ]; then
        APM_SECRETS=$(aws secretsmanager get-secret-value --secret-id essp_apm_deployment --region us-west-2 | jq -r .SecretString)
        APM_SECRET_TOKEN=$(echo ${APM_SECRETS} | jq -r .apm_secret_token)
        APM_SERVER_URL=$(echo ${APM_SECRETS} | jq -r .apm_server_url)
        $KUBECTL create secret generic apm-credentials \
            --from-literal=apm_server_url=${APM_SERVER_URL} \
            --from-literal=apm_secret_token=${APM_SECRET_TOKEN} \
            --namespace kube-system
    fi

    $KUBECTL get secrets/essp-deployment-credentials --namespace kube-system
    if [ $? -ne 0 ]; then
        ESSP_DEPLOYMENT_SECRETS=$(aws secretsmanager get-secret-value --secret-id essp_deployment_credentials --region us-west-2 | jq -r .SecretString)
        DEPLOYMENT_ID=$(echo ${ESSP_DEPLOYMENT_SECRETS} | jq -r .deployment_id)
        INGESTION_USER=$(echo ${ESSP_DEPLOYMENT_SECRETS} | jq -r .ingestion_user)
        INGESTION_USER_PASSWORD=$(echo ${ESSP_DEPLOYMENT_SECRETS} | jq -r .ingestion_user_password)
        INGESTION_URL=$(echo ${ESSP_DEPLOYMENT_SECRETS} | jq -r .ingestion_url)
        $KUBECTL create secret generic essp-deployment-credentials \
            --from-literal=deployment_id=${DEPLOYMENT_ID} \
            --from-literal=ingestion_user=${INGESTION_USER} \
            --from-literal=ingestion_user_password=${INGESTION_USER_PASSWORD} \
            --from-literal=ingestion_url=${INGESTION_URL} \
            --namespace kube-system
    fi
}

deploy_otel_collector() {
    helm upgrade --install \
        --debug --atomic \
        --namespace kube-system \
        opentelemetry-collector \
        open-telemetry/opentelemetry-collector \
        --values otel-collector/values.yaml \
        --version 0.69.0 --timeout 10m
}

# this cleansup some of the softwares that are installed on eks and don't work on ARM64 architecture
cleanup_unsupported_softwares() {
    $KUBECTL delete deploy/cni-metrics-helper --namespace kube-system >/dev/null 2>&1
    $KUBECTL delete mutatingwebhookconfigurations/mutating-webhook > /dev/null 2>&1
    $KUBECTL delete validatingwebhookconfigurations/validating-webhook > /dev/null 2>&1
    $KUBECTL delete validatingwebhookconfigurations/opa-validating-webhook > /dev/null 2>&1
    $KUBECTL delete deploy/opa deploy/webhook --namespace webhook > /dev/null 2>&1
}

create_route53_records() {
    # get UIP (internal) ALB DNS name
    # --------------------------------------
    # wait for alb to come up
    retry=0
    until [ "$retry" -ge 10 ]
    do
        # read alb dns name
        DESCRIBE_ALB_RESULT=$(aws elbv2 describe-load-balancers --region=${AWS_REGION} | jq ".LoadBalancers[] | select(.LoadBalancerName==\"uip-services-${AWS_K8S_CLUSTER}\")")

        if [ "x${DESCRIBE_ALB_RESULT}" == "x" ]; then
            sleep 15
            retry=$((retry+1))
        else
            break
        fi
    done

    # fail if max retries reached
    if [ "$retry" -ge 10 ]; then
        exit 0
    fi

    ALB_DNS_NAME=`echo $DESCRIBE_ALB_RESULT | jq -r .DNSName`
    ALB_CANONICAL_HOSTED_ZONEID=`echo $DESCRIBE_ALB_RESULT | jq -r .CanonicalHostedZoneId`
    echo "UIP platform AWS/ALB dns name: ${ALB_DNS_NAME}, hostedZone: ${ALB_CANONICAL_HOSTED_ZONEID}"

    # get UIP (internet-facing) ALB DNS name
    # --------------------------------------
    UIP_PUBLIC_ALB_DNS_NAME="unknown"
    UIP_PUBLIC_ALB_CANONICAL_HOSTED_ZONEID="unknown"

    if [ "${ENVIRONMENT}" == "prod" ]; then
        retry=0
        until [ "$retry" -ge 10 ]
        do
            # read alb dns name
            DESCRIBE_UIP_PUBLIC_ALB_RESULT=$(aws elbv2 describe-load-balancers --region=${AWS_REGION} | jq ".LoadBalancers[] | select(.LoadBalancerName==\"uip-services-public-${AWS_K8S_CLUSTER}\")")
            if [ "x${DESCRIBE_UIP_PUBLIC_ALB_RESULT}" == "x" ]; then
                sleep 15
                retry=$((retry+1))
            else
                break
            fi
        done

        # fail if max retries reached
        if [ "$retry" -ge 10 ]; then
            exit 0
        fi

        UIP_PUBLIC_ALB_DNS_NAME=$(echo $DESCRIBE_UIP_PUBLIC_ALB_RESULT | jq -r .DNSName)
        UIP_PUBLIC_ALB_CANONICAL_HOSTED_ZONEID=$(echo $DESCRIBE_UIP_PUBLIC_ALB_RESULT | jq -r .CanonicalHostedZoneId)
        echo "UIP External AWS/ALB dns name: ${UIP_PUBLIC_ALB_DNS_NAME}, hostedZone: ${UIP_PUBLIC_ALB_CANONICAL_HOSTED_ZONEID}"
    fi

    # get Keychain ALB DNS name
    # --------------------------------------
    KEYCHAIN_ALB_DNS_NAME="unknwon"
    KEYCHAIN_ALB_CANONICAL_HOSTED_ZONEID="unknown"

    retry=0
    until [ "$retry" -ge 10 ]
    do
        # read alb dns name
        KEYCHAIN_DESCRIBE_ALB_RESULT=$(aws elbv2 describe-load-balancers --region=${AWS_REGION} | jq ".LoadBalancers[] | select(.LoadBalancerName==\"keychain-${AWS_K8S_CLUSTER}\")")
        if [ "x${KEYCHAIN_DESCRIBE_ALB_RESULT}" == "x" ]; then
            sleep 15
            retry=$((retry+1))
        else
            break
        fi
    done

    # fail if max retries reached
    if [ "$retry" -ge 10 ]; then
        exit 0
    fi

    KEYCHAIN_ALB_DNS_NAME=`echo $KEYCHAIN_DESCRIBE_ALB_RESULT | jq -r .DNSName`
    KEYCHAIN_ALB_CANONICAL_HOSTED_ZONEID=`echo $KEYCHAIN_DESCRIBE_ALB_RESULT | jq -r .CanonicalHostedZoneId`
    echo "UIP platform Keychain AWS/ALB dns name: ${KEYCHAIN_ALB_DNS_NAME}, hostedZone: ${KEYCHAIN_ALB_CANONICAL_HOSTED_ZONEID}"


    KEYCHAIN_USWEST2_ALB_DNS_NAME="unknown"
    KEYCHAIN_USWEST2_ALB_CANONICAL_HOSTED_ZONEID="unknown"

    if [ "${ENVIRONMENT}" == "dev-private" ] || [ "${ENVIRONMENT}" == "prod" ]; then
        if [ "${AWS_REGION}" == "us-west-2" ]; then
            retry=0
            until [ "$retry" -ge 10 ]
            do
                # read alb dns name
                KEYCHAIN_DESCRIBE_ALB_RESULT=$(aws elbv2 describe-load-balancers --region=${AWS_REGION} | jq ".LoadBalancers[] | select(.LoadBalancerName==\"keychain-us-west-2-${AWS_K8S_CLUSTER}\")")
                if [ "x${KEYCHAIN_DESCRIBE_ALB_RESULT}" == "x" ]; then
                    sleep 15
                    retry=$((retry+1))
                else
                    break
                fi
            done

            # fail if max retries reached
            if [ "$retry" -ge 10 ]; then
                exit 0
            fi

            KEYCHAIN_USWEST2_ALB_DNS_NAME=`echo $KEYCHAIN_DESCRIBE_ALB_RESULT | jq -r .DNSName`
            KEYCHAIN_USWEST2_ALB_CANONICAL_HOSTED_ZONEID=`echo $KEYCHAIN_DESCRIBE_ALB_RESULT | jq -r .CanonicalHostedZoneId`
            echo "UIP platform Keychain us-west-2 AWS/ALB dns name: ${KEYCHAIN_USWEST2_ALB_DNS_NAME}, hostedZone: ${KEYCHAIN_USWEST2_ALB_CANONICAL_HOSTED_ZONEID}"
        fi
    fi

    KEYCHAIN_USEAST1_ALB_DNS_NAME="unknown"
    KEYCHAIN_USEAST1_ALB_CANONICAL_HOSTED_ZONEID="unknown"

    if [ "${ENVIRONMENT}" == "dev-private" ] || [ "${ENVIRONMENT}" == "prod" ]; then
        if [ "${AWS_REGION}" == "us-east-1" ]; then
            retry=0
            until [ "$retry" -ge 10 ]
            do
                # read alb dns name
                KEYCHAIN_DESCRIBE_ALB_RESULT=$(aws elbv2 describe-load-balancers --region=${AWS_REGION} | jq ".LoadBalancers[] | select(.LoadBalancerName==\"keychain-us-east-1-${AWS_K8S_CLUSTER}\")")
                if [ "x${KEYCHAIN_DESCRIBE_ALB_RESULT}" == "x" ]; then
                    sleep 15
                    retry=$((retry+1))
                else
                    break
                fi
            done

            # fail if max retries reached
            if [ "$retry" -ge 10 ]; then
                exit 0
            fi

            KEYCHAIN_USEAST1_ALB_DNS_NAME=`echo $KEYCHAIN_DESCRIBE_ALB_RESULT | jq -r .DNSName`
            KEYCHAIN_USEAST1_ALB_CANONICAL_HOSTED_ZONEID=`echo $KEYCHAIN_DESCRIBE_ALB_RESULT | jq -r .CanonicalHostedZoneId`
            echo "UIP platform Keychain us-east-1 AWS/ALB dns name: ${KEYCHAIN_USEAST1_ALB_DNS_NAME}, hostedZone: ${KEYCHAIN_USEAST1_ALB_CANONICAL_HOSTED_ZONEID}"
        fi
    fi

    ASP_SEGMENTS_ALB_DNS_NAME="unknwon"
    ASP_SEGMENTS_ALB_CANONICAL_HOSTED_ZONEID="unknown"

    if [ "${ENVIRONMENT}" == "dev-private" ] || [ "${ENVIRONMENT}" == "prod" ]; then
      retry=0
      until [ "$retry" -ge 10 ]
      do
          # read alb dns name
          ASP_SEGMENTS_DESCRIBE_ALB_RESULT=$(aws elbv2 describe-load-balancers --region=${AWS_REGION} | jq "
          .LoadBalancers[] | select(.LoadBalancerName==\"asp-segments-${AWS_K8S_CLUSTER}\")")
          if [ "x${ASP_SEGMENTS_DESCRIBE_ALB_RESULT}" == "x" ]; then
              sleep 15
              retry=$((retry+1))
          else
              break
          fi
      done

      # fail if max retries reached
      if [ "$retry" -ge 10 ]; then
          exit 0
      fi

      ASP_SEGMENTS_ALB_DNS_NAME=`echo $ASP_SEGMENTS_DESCRIBE_ALB_RESULT | jq -r .DNSName`
      ASP_SEGMENTS_ALB_CANONICAL_HOSTED_ZONEID=`echo $ASP_SEGMENTS_DESCRIBE_ALB_RESULT | jq -r .CanonicalHostedZoneId`
      echo "ASP Segments AWS/ALB dns name: ${ASP_SEGMENTS_ALB_DNS_NAME}, hostedZone:
      ${ASP_SEGMENTS_ALB_CANONICAL_HOSTED_ZONEID}"
    fi

    ASP_SEGMENTS_USWEST2_ALB_DNS_NAME="unknown"
    ASP_SEGMENTS_USWEST2_ALB_CANONICAL_HOSTED_ZONEID="unknown"
    if [ "${ENVIRONMENT}" == "dev-private" ] || [ "${ENVIRONMENT}" == "prod" ]; then
        if [ "${AWS_REGION}" == "us-west-2" ]; then
            retry=0
            until [ "$retry" -ge 10 ]
            do
                # read alb dns name
                ASP_SEGMENTS_DESCRIBE_ALB_RESULT=$(aws elbv2 describe-load-balancers --region=${AWS_REGION} | jq "
                .LoadBalancers[] | select(.LoadBalancerName==\"asp-segments-us-west-2-${AWS_K8S_CLUSTER}\")")
                if [ "x${ASP_SEGMENTS_DESCRIBE_ALB_RESULT}" == "x" ]; then
                    sleep 15
                    retry=$((retry+1))
                else
                    break
                fi
            done

            # fail if max retries reached
            if [ "$retry" -ge 10 ]; then
                exit 0
            fi

            ASP_SEGMENTS_USWEST2_ALB_DNS_NAME=`echo $ASP_SEGMENTS_DESCRIBE_ALB_RESULT | jq -r .DNSName`
            ASP_SEGMENTS_USWEST2_ALB_CANONICAL_HOSTED_ZONEID=`echo $ASP_SEGMENTS_DESCRIBE_ALB_RESULT | jq -r .CanonicalHostedZoneId`
            echo "ASP Segments us-west-2 AWS/ALB dns name: ${ASP_SEGMENTS_USWEST2_ALB_DNS_NAME}, hostedZone:
            ${ASP_SEGMENTS_USWEST2_ALB_CANONICAL_HOSTED_ZONEID}"
        fi
    fi

    ASP_SEGMENTS_USEAST1_ALB_DNS_NAME="unknown"
    ASP_SEGMENTS_USEAST1_ALB_CANONICAL_HOSTED_ZONEID="unknown"
    if [ "${ENVIRONMENT}" == "dev-private" ] || [ "${ENVIRONMENT}" == "prod" ]; then
        if [ "${AWS_REGION}" == "us-east-1" ]; then
            retry=0
            until [ "$retry" -ge 10 ]
            do
                # read alb dns name
                ASP_SEGMENTS_DESCRIBE_ALB_RESULT=$(aws elbv2 describe-load-balancers --region=${AWS_REGION} | jq "
                .LoadBalancers[] | select(.LoadBalancerName==\"asp-segments-us-east-1-${AWS_K8S_CLUSTER}\")")
                if [ "x${ASP_SEGMENTS_DESCRIBE_ALB_RESULT}" == "x" ]; then
                    sleep 15
                    retry=$((retry+1))
                else
                    break
                fi
            done

            # fail if max retries reached
            if [ "$retry" -ge 10 ]; then
                exit 0
            fi

            ASP_SEGMENTS_USEAST1_ALB_DNS_NAME=`echo $ASP_SEGMENTS_DESCRIBE_ALB_RESULT | jq -r .DNSName`
            ASP_SEGMENTS_USEAST1_ALB_CANONICAL_HOSTED_ZONEID=`echo $ASP_SEGMENTS_DESCRIBE_ALB_RESULT | jq -r .CanonicalHostedZoneId`
            echo "ASP Segments us-east-1 AWS/ALB dns name: ${ASP_SEGMENTS_USEAST1_ALB_DNS_NAME}, hostedZone:
            ${ASP_SEGMENTS_USEAST1_ALB_CANONICAL_HOSTED_ZONEID}"
        fi
    fi



    UIP_DATA_ACCESS_USWEST2_ALB_DNS_NAME="unknown"
    UIP_DATA_ACCESS_USWEST2_ALB_CANONICAL_HOSTED_ZONEID="unknown"
    if [ "${ENVIRONMENT}" == "prod" ]; then
        if [ "${AWS_REGION}" == "us-west-2" ]; then
            retry=0
            until [ "$retry" -ge 10 ]
            do
                # read alb dns name
                UIP_DATA_ACCESS_DESCRIBE_ALB_RESULT=$(aws elbv2 describe-load-balancers --region=${AWS_REGION} | jq "
                .LoadBalancers[] | select(.LoadBalancerName==\"uip-us-west-2-${AWS_K8S_CLUSTER}\")")
                if [ "x${UIP_DATA_ACCESS_DESCRIBE_ALB_RESULT}" == "x" ]; then
                    sleep 15
                    retry=$((retry+1))
                else
                    break
                fi
            done

            # fail if max retries reached
            if [ "$retry" -ge 10 ]; then
                exit 0
            fi

            UIP_DATA_ACCESS_USWEST2_ALB_DNS_NAME=`echo $UIP_DATA_ACCESS_DESCRIBE_ALB_RESULT | jq -r .DNSName`
            UIP_DATA_ACCESS_USWEST2_ALB_CANONICAL_HOSTED_ZONEID=`echo $UIP_DATA_ACCESS_DESCRIBE_ALB_RESULT | jq -r .CanonicalHostedZoneId`
            echo "UIP_DATA_ACCESS us-west-2 AWS/ALB dns name: ${UIP_DATA_ACCESS_USWEST2_ALB_DNS_NAME}, hostedZone:
            ${UIP_DATA_ACCESS_USWEST2_ALB_CANONICAL_HOSTED_ZONEID}"
        fi
    fi

    UIP_DATA_ACCESS_USEAST1_ALB_DNS_NAME="unknown"
    UIP_DATA_ACCESS_USEAST1_ALB_CANONICAL_HOSTED_ZONEID="unknown"
    if [ "${ENVIRONMENT}" == "prod" ]; then
        if [ "${AWS_REGION}" == "us-east-1" ]; then
            retry=0
            until [ "$retry" -ge 10 ]
            do
                # read alb dns name
                UIP_DATA_ACCESS_DESCRIBE_ALB_RESULT=$(aws elbv2 describe-load-balancers --region=${AWS_REGION} | jq "
                .LoadBalancers[] | select(.LoadBalancerName==\"uip-us-east-1-${AWS_K8S_CLUSTER}\")")
                if [ "x${UIP_DATA_ACCESS_DESCRIBE_ALB_RESULT}" == "x" ]; then
                    sleep 15
                    retry=$((retry+1))
                else
                    break
                fi
            done

            # fail if max retries reached
            if [ "$retry" -ge 10 ]; then
                exit 0
            fi

            UIP_DATA_ACCESS_USEAST1_ALB_DNS_NAME=`echo $UIP_DATA_ACCESS_DESCRIBE_ALB_RESULT | jq -r .DNSName`
            UIP_DATA_ACCESS_USEAST1_ALB_CANONICAL_HOSTED_ZONEID=`echo $UIP_DATA_ACCESS_DESCRIBE_ALB_RESULT | jq -r .CanonicalHostedZoneId`
            echo "UIP_DATA_ACCESS us-east-1 AWS/ALB dns name: ${UIP_DATA_ACCESS_USEAST1_ALB_DNS_NAME}, hostedZone:
            ${UIP_DATA_ACCESS_USEAST1_ALB_CANONICAL_HOSTED_ZONEID}"
        fi
    fi


    EXT_ALB_DNS_NAME="unknwon"
    EXT_ALB_CANONICAL_HOSTED_ZONEID="unknown"

    retry=0
    until [ "$retry" -ge 10 ]
    do
        # read alb dns name
        EXT_DESCRIBE_ALB_RESULT=$(aws elbv2 describe-load-balancers --region=${AWS_REGION} | jq ".LoadBalancers[] | select(.LoadBalancerName==\"ext-uip-services-${AWS_K8S_CLUSTER}\")")
        if [ "x${EXT_DESCRIBE_ALB_RESULT}" == "x" ]; then
            sleep 15
            retry=$((retry+1))
        else
            break
        fi
    done

    # fail if max retries reached
    if [ "$retry" -ge 10 ]; then
        exit 0
    fi

    EXT_ALB_DNS_NAME=`echo $EXT_DESCRIBE_ALB_RESULT | jq -r .DNSName`
    EXT_ALB_CANONICAL_HOSTED_ZONEID=`echo $EXT_DESCRIBE_ALB_RESULT | jq -r .CanonicalHostedZoneId`
    echo "UIP platform External AWS/ALB dns name: ${EXT_ALB_DNS_NAME}, hostedZone: ${EXT_ALB_CANONICAL_HOSTED_ZONEID}"


    # get ASP (internet-facing) ALB DNS name
    ASP_ALB_DNS_NAME="unknown"
    ASP_ALB_CANONICAL_HOSTED_ZONEID="unknown"

    retry=0
    until [ "$retry" -ge 10 ]
    do
        # read alb dns name
        ASP_DESCRIBE_ALB_RESULT=$(aws elbv2 describe-load-balancers --region=${AWS_REGION} | jq ".LoadBalancers[] | select(.LoadBalancerName==\"asp-services-${AWS_K8S_CLUSTER}\")")
        if [ "x${ASP_DESCRIBE_ALB_RESULT}" == "x" ]; then
            sleep 15
            retry=$((retry+1))
        else
            break
        fi
    done

    # fail if max retries reached
    if [ "$retry" -ge 10 ]; then
        exit 0
    fi

    ASP_ALB_DNS_NAME=`echo $ASP_DESCRIBE_ALB_RESULT | jq -r .DNSName`
    ASP_ALB_CANONICAL_HOSTED_ZONEID=`echo $ASP_DESCRIBE_ALB_RESULT | jq -r .CanonicalHostedZoneId`
    echo "ASP platform External AWS/ALB dns name: ${ASP_ALB_DNS_NAME}, hostedZone: ${ASP_ALB_CANONICAL_HOSTED_ZONEID}"


    poetry run sceptre --dir route53/sceptre \
        --var alb_dns_name=${ALB_DNS_NAME} \
        --var alb_hosted_zoneid=${ALB_CANONICAL_HOSTED_ZONEID} \
        --var uip_public_alb_dns_name=${UIP_PUBLIC_ALB_DNS_NAME} \
        --var uip_public_alb_hosted_zoneid=${UIP_PUBLIC_ALB_CANONICAL_HOSTED_ZONEID} \
        --var keychain_alb_dns_name=${KEYCHAIN_ALB_DNS_NAME} \
        --var keychain_alb_hosted_zoneid=${KEYCHAIN_ALB_CANONICAL_HOSTED_ZONEID} \
        --var keychain_uswest2_alb_dns_name=${KEYCHAIN_USWEST2_ALB_DNS_NAME} \
        --var keychain_uswest2_alb_hosted_zoneid=${KEYCHAIN_USWEST2_ALB_CANONICAL_HOSTED_ZONEID} \
        --var keychain_useast1_alb_dns_name=${KEYCHAIN_USEAST1_ALB_DNS_NAME} \
        --var keychain_useast1_alb_hosted_zoneid=${KEYCHAIN_USEAST1_ALB_CANONICAL_HOSTED_ZONEID} \
        --var asp_alb_dns_name=${ASP_ALB_DNS_NAME} \
        --var asp_alb_hosted_zoneid=${ASP_ALB_CANONICAL_HOSTED_ZONEID} \
        --var asp_segments_alb_dns_name=${ASP_SEGMENTS_ALB_DNS_NAME} \
        --var asp_segments_alb_hosted_zoneid=${ASP_SEGMENTS_ALB_CANONICAL_HOSTED_ZONEID} \
        --var asp_segments_uswest2_alb_dns_name=${ASP_SEGMENTS_USWEST2_ALB_DNS_NAME} \
        --var asp_segments_uswest2_alb_hosted_zoneid=${ASP_SEGMENTS_USWEST2_ALB_CANONICAL_HOSTED_ZONEID} \
        --var asp_segments_useast1_alb_dns_name=${ASP_SEGMENTS_USEAST1_ALB_DNS_NAME} \
        --var asp_segments_useast1_alb_hosted_zoneid=${ASP_SEGMENTS_USEAST1_ALB_CANONICAL_HOSTED_ZONEID} \
        --var uip_data_access_uswest2_alb_dns_name=${UIP_DATA_ACCESS_USWEST2_ALB_DNS_NAME} \
        --var uip_data_access_uswest2_alb_hosted_zoneid=${UIP_DATA_ACCESS_USWEST2_ALB_CANONICAL_HOSTED_ZONEID} \
        --var uip_data_access_useast1_alb_dns_name=${UIP_DATA_ACCESS_USEAST1_ALB_DNS_NAME} \
        --var uip_data_access_useast1_alb_hosted_zoneid=${UIP_DATA_ACCESS_USEAST1_ALB_CANONICAL_HOSTED_ZONEID} \
        --var ext_alb_dns_name=${EXT_ALB_DNS_NAME} \
        --var ext_alb_hosted_zoneid=${EXT_ALB_CANONICAL_HOSTED_ZONEID} \
    launch -y ${ENVIRONMENT}/${AWS_REGION}


    verifyExitCode $?
}

deploy_sonarqube() {
    if [ "${ENVIRONMENT}" == "dev-private" ]; then
        if [ "${AWS_REGION}" == "us-west-2" ]; then
            $KUBECTL get namespace sonarqube
            if [ $? -ne 0 ]; then
                $KUBECTL create namespace sonarqube
            fi
        fi
        helm upgrade --install -n sonarqube --values sonarqube/values.yaml sonarqube sonarqube/sonarqube
    fi
}

setup_iam_jwt_user() {
    IAM_JWT_USER_SECRETS=$(aws secretsmanager get-secret-value --secret-id /Secrets/IAMUser/uip-jwt-user --region us-west-2 | jq -r .SecretString)
    IAM_JWT_USER_ACCESS_KEY_ID=$(echo ${IAM_JWT_USER_SECRETS} | jq -r .AccessKeyId)
    IAM_JWT_USER_SECRET_ACCESS_KEY=$(echo ${IAM_JWT_USER_SECRETS} | jq -r .SecretAccessKey)
    if [ "x${IAM_JWT_USER_ACCESS_KEY_ID}" != "x" ]; then
        $KUBECTL create secret generic iam-jwt-user \
            --from-literal=accessKeyId=${IAM_JWT_USER_ACCESS_KEY_ID} \
            --from-literal=secretAccessKey=${IAM_JWT_USER_SECRET_ACCESS_KEY} \
            --namespace uip --dry-run=client -o yaml | $KUBECTL apply -f -
    fi
}

setup_datahub_pat() {
    DATAHUB_CREDENTIALS=$(aws secretsmanager get-secret-value --secret-id datahub_credentials --region us-west-2 | jq -r .SecretString)
    DATAHUB_PAT=$(echo ${DATAHUB_CREDENTIALS} | jq -r .datahub_access_token)
    DATAHUB_URL=$(echo ${DATAHUB_CREDENTIALS} | jq -r .datahub_url)
    if [ "x${DATAHUB_PAT}" != "x" ]; then
        $KUBECTL create secret generic datahub-credentials \
            --from-literal=datahub_pat=${DATAHUB_PAT} \
            --from-literal=datahub_url=${DATAHUB_URL} \
            --namespace uip --dry-run=client -o yaml | $KUBECTL apply -f -
    fi
}

deploy_metrics_server() {
    REPLICAS=1
    if [ "${ENVIRONMENT}" == "prod" ]; then
        REPLICAS=2
    fi

    helm upgrade --install uip-metrics-server metrics-server/metrics-server --debug --set replicas=$REPLICAS --namespace kube-system --version 3.10.0
}

artifactory_login() {
  docker login -u $ARTIFACTORY_USER -p $ARTIFACTORY_PASSWORD $ARTIFACTORY_URL
}

upload_eep_sidecar_ecr() {
    ARTIFACTORY=${ARTIFACTORY_URL}/docker-virt
    aws ecr get-login-password --region ${AWS_REGION} | docker login --username AWS --password-stdin ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com
    for tag in v2-arm v2; do
        docker pull $ARTIFACTORY/eep-sidecar:$tag
        ecrImageName="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/eep-sidecar:$tag"
        docker tag $ARTIFACTORY/eep-sidecar:$tag $ecrImageName
        # Build the docker image locally with the image name and then push it to ECR with the full name.
        docker push ${ecrImageName}
    done
}

# execute all of them in the right order
setup_kubectl_context
helm_add_repos

if [ "${UPDATE_ROUTE53}" == "true" ]; then
    create_route53_records
else
    artifactory_login
    setup_essp_secrets
    cleanup_unsupported_softwares
    deploy_namespace
    setup_iam_jwt_user
    deploy_cluster_autoscaler
    deploy_alb_ingress_controller
    deploy_fluentbit
    deploy_metricbeat
    deploy_otel_collector
    deploy_ingress_rules
    deploy_ebs_csi_driver
    deploy_metrics_server
    upload_eep_sidecar_ecr
#    deploy_sonarqube  # enable only while provisioning cluster for the first time
    setup_datahub_pat
fi

# change back to initial working directory
cd "${INITIAL_WORKING_DIRECTORY}" || exit
