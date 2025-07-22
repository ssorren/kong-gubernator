# Kong Konnect

## Kong Gateway Operator (KGO), Konnect Control Plane creation and Data Plane deployment

We are going to use [Kong Gateway Operator (KGO)](https://docs.konghq.com/gateway-operator) to create the Konnect Control Plane and Data Plane. First, install the KGO Operator:

```
helm repo add kong https://charts.konghq.com
helm repo update kong
```

```
helm upgrade --install kgo kong/gateway-operator \
  -n kg-operator \
  --create-namespace \
  --set image.tag=1.6 \
  --set kubernetes-configuration-crds.enabled=true \
  --set env.ENABLE_CONTROLLER_KONNECT=true
  --set env.VALIDATE_IMAGES=false
```

You can check the Operator's logs with:
 0
```
kubectl logs -f $(kubectl get pod -n kg-operator -o json | jq -r '.items[].metadata | select(.name | startswith("kgo-gateway"))' | jq -r '.name') -n kg-operator
```

And if you want to uninstall it run:
```
helm uninstall kg-operator -n kong
kubectl delete namespace kong
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


```
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.15.2/config/manifests/metallb-native.yaml
kubectl get pods -n metallb-system
kubectl apply -f metal-lb.yaml
```

### Kong Konnect Control Plane

The Control Plane installation uses the following [cp.yaml](../kgo/cp.yaml) file.

```
kubectl apply -f ./control-plane.yaml
kubectl apply -f ./role-binding.yaml
```

```
export CONTROL_PLANE_ID=$(curl -s -X GET "https://us.api.konghq.com/v2/control-planes?filter\[name\]=<your control plane name>" -H "Authorization: Bearer ${PAT}" | jq -r '.data[0].id' )
echo $CONTROL_PLANE_ID
```

```
curl -i -X POST \
  "https://us.api.konghq.com/v2/control-planes/${CONTROL_PLANE_ID}/core-entities/plugin-schemas" \
  --header "Content-Type: application/json" \
  --header "Authorization: Bearer ${PAT}" \
  --data "{
    \"lua_schema\": $(jq -Rs '.' ./kong/plugins/<your plugin name>/schema.lua)
  }"
```

```
curl -i -X DELETE \
  "https://us.api.konghq.com/v2/control-planes/${CONTROL_PLANE_ID}/core-entities/plugin-schemas/gubernator" \
  --header "Authorization: Bearer ${PAT}"
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
deck gateway sync --konnect-control-plane-name gubernator --konnect-token $PAT rate-limit-config.yaml
```

You can reset your Control Plane if you will:
```
deck gateway reset --konnect-control-plane-name gubernator --konnect-token $PAT -f
```


## Checking the Proxy

Inside the K6's EC2 use the DP's Load Balancer created during the deployment

```
export DATAPLANE_LB=$(kubectl get service -n kong proxy1 --output=jsonpath='{.status.loadBalancer.ingress[0].hostname}')
```

```
http $DATAPLANE_LB
```

