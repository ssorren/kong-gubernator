# AWS and EKS

## AWS Region
If necessary, set your default AWS region. This variable will be used in several scripts.

```
export AWS_DEFAULT_REGION=<your region>
```

## EKS Cluster Creation and Tools Node

Initially, the EKS Cluster has a single Node where we are going to install the tools and controller necessary for the benchmark including
* AWS Load Balancer Controller
* EBS CSI Driver add-on
* Prometheus

Create an AWS Key Pair to be able to login to the Node if needed.

```
aws ec2 create-key-pair \
    --key-name ssorren-sandbox \
    --key-type rsa \
    --key-format pem \
    --query "KeyMaterial" \
    --output text > ssorren-sandbox.pem

chmod 400 ssorren-sandbox.pem
```

Create the EKS cluster. Ensure you use the ssh key you created above, or replace it with your own ssh key. This ssh key will be needed in later steps.

```
eksctl create cluster -f - <<EOF
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: ssorren-ratelimit
  region: $AWS_DEFAULT_REGION
  version: "1.33"

managedNodeGroups:
  - name: node-tools
    instanceType: c5.xlarge
    minSize: 1
    maxSize: 8
    ssh:
      publicKeyName: ssorren-sandbox
EOF
```



## Pod Identity

EKS Pod Identity is used to manage the Load Balancerd Controller and EBS CSI Driver Add-On.

```
eksctl create addon --cluster ssorren-ratelimit \
  --region $AWS_DEFAULT_REGION \
  --name eks-pod-identity-agent
```

## Check the Add-Ons

Before installing any Add-On make sure they are ``ACTIVE``:

```
eksctl get addons --cluster ssorren-ratelimit --region $AWS_DEFAULT_REGION
```


## AWS Load Balancer Controller

To learn mode about the AWS Load Balancer Controller read its [documentation](https://kubernetes-sigs.github.io/aws-load-balancer-controller/latest/)


```
curl -O https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.13.2/docs/install/iam_policy.json
```

```
aws iam create-policy \
    --policy-name SsorrenRLLoadBalancerPolicy \
    --policy-document file://iam_policy.json
```


### Install AWS Load Balancer Controller

Use your AWS account to install the Load Balancer Controller

```
eksctl create podidentityassociation \
    --cluster ssorren-ratelimit \
    --region $AWS_DEFAULT_REGION \
    --namespace kube-system \
    --service-account-name aws-load-balancer-controller \
    --role-name SsorrenRLLoadBalancerControllerIAMRole-ssorren-ratelimit \
    --permission-policy-arns arn:aws:iam::162225303348:policy/SsorrenRLLoadBalancerPolicy
```

```
helm install aws-load-balancer-controller eks/aws-load-balancer-controller -n kube-system \
  --set clusterName=ssorren-ratelimit \
  --set region=$AWS_DEFAULT_REGION \
  --set serviceAccount.create=true \
  --set serviceAccount.name=aws-load-balancer-controller
```


## EBS CSI Driver add-on

EBS CSI Driver is required to deploy the Kong Gateway Enterprise database.

```
eksctl create addon --cluster ssorren-ratelimit \
  --region $AWS_DEFAULT_REGION \
  --name aws-ebs-csi-driver
```

```
eksctl update addon -f - <<EOF
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig
metadata:
  name: ssorren-ratelimit
  region: $AWS_DEFAULT_REGION
addons:
- name: aws-ebs-csi-driver
  podIdentityAssociations:
  - serviceAccountName: ebs-csi-controller-sa
    namespace: kube-system
    permissionPolicyARNs:
    - arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy
EOF


eksctl create nodegroup -f - <<EOF
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: kong310-eks132
  region: $AWS_DEFAULT_REGION

managedNodeGroups:
  - name: node-ai-gateway
    instanceType: c5.4xlarge
    amiFamily: AmazonLinux2023
    minSize: 1
    maxSize: 8
    ssh:
      publicKeyName: ssorren-sandbox
EOF
```

## kubectl

In order to perform kubectl operations, you will need to set your config to the newly created cluster. You may want to backup your existing configs first.

```
aws eks update-kubeconfig --region $AWS_DEFAULT_REGION --name ssorren-ratelimit
```


# Kong Konnect

## Kong Gateway Operator (KGO), Konnect Control Plane creation and Data Plane deployment

We are going to use [Kong Gateway Operator (KGO)](https://docs.konghq.com/gateway-operator) to create the Konnect Control Plane and Data Plane. First, install the KGO Operator:

```
helm repo add kong https://charts.konghq.com
helm repo update kong
```

```
helm upgrade --install kgo kong/gateway-operator \
  -n kong-system \
  --create-namespace \
  --set image.tag=1.6 \
  --set kubernetes-configuration-crds.enabled=true \
  --set env.ENABLE_CONTROLLER_KONNECT=true
```

You can check the Operator's logs with:

```
kubectl logs -f $(kubectl get pod -n kong-system -o json | jq -r '.items[].metadata | select(.name | startswith("kgo-gateway"))' | jq -r '.name') -n kong-system
```

And if you want to uninstall it run:
```
helm uninstall kgo -n kong-system
kubectl delete namespace kong-system
```

### Konnect registration
You will need a Konnect subscription. Click on the [Registration](https://konghq.com/products/kong-konnect/register) link, present your credentials and get a 30-day Konnect Plus trial.


### Konnect PAT (Personal Access Token)
KGO requires a [Konnect Personal Access Token (PAT)](https://docs.konghq.com/konnect/org-management/access-tokens/) for creating the Control Plane. You need to register first. To generate your PAT, click on your initials in the upper right corner of the Konnect home page, then select Personal Access Tokens. Click on ``+ Generate Token``, name your PAT, set its expiration time, and be sure to copy and save it, as Konnect won’t display it again.


### Konnect Control Plane creation

Create a Namespace and a Secret 

```
kubectl create namespace kong

kubectl create secret generic konnect-pat -n kong --from-literal=token="${PAT}"

kubectl label secret konnect-pat -n kong "konghq.com/credential=konnect"
```

If you run the following command you should see you PAT:
```
kubectl get secret konnect-pat -n kong -o jsonpath='{.data.*}' | base64 -d
```

### Kong Konnect Control Plane

The Control Plane installation uses the following [cp.yaml](../kgo/cp.yaml) file.

```
kubectl apply -f ./control-plane.yaml
kubectl apply -f ./role-binding.yaml.yaml
```


### Kong Konnect Data Plane

The Data Plane uses the [dp.yaml](../kgo/dp.yaml) file. Note the deployment also spings up 3 replicas for the Data Plane:

```
kubectl apply -f ./data-plane.yaml
```

#### Check DP's logs

You can check the Data Plane logs with

```
kubectl logs -f $(kubectl get pod -n kong -o json | jq -r '.items[].metadata | select(.name | startswith("dataplane-"))' | jq -r '.name') -n kong
```



## decK

Submit the same ``kong.yaml`` declaration, refering your Konnect Control Plane. Make sure you've updated it with the WireMock's NLB DNS Name.

```
deck gateway sync --konnect-control-plane-name ai-gateway --konnect-token $PAT kong.yaml
```

You can reset your Control Plane if you will:
```
deck gateway reset --konnect-control-plane-name ai-gateway --konnect-token $PAT -f
```


## Checking the Proxy

Inside the K6's EC2 use the DP's Load Balancer created during the deployment

```
export DATAPLANE_LB=$(kubectl get service -n kong proxy1 --output=jsonpath='{.status.loadBalancer.ingress[0].hostname}')
```

```
http $DATAPLANE_LB
```


```
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.15.2/config/manifests/metallb-native.yaml
kubectl get pods -n metallb-system
kubectl apply -f metal-lb.yaml
```