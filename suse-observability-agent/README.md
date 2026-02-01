# suse-observability-agent

The suse-observability-agent add-on is an addon to install the suse-observability-agent onto the Harvester cluster, the Harvester cluster will connect to the SUSE observability. [SUSE Observability](https://www.suse.com/products/rancher/observability/) delivers comprehensive monitoring, advanced analytics, and seamless integration capabilities.

## How to

### Prepare access data from SUSE Observability

On the running SUSE Observability, add a new instance, it will guide to create a new `CREATE NEW SERVICE TOKEN`, and then the page shows a long text, find the key word `Generic Kubernetes`.

```
...
Generic Kubernetes (including RKE2)
Instructions on how to deploy the SUSE Observability Agent and Cluster Agent on a Kubernetes cluster can be found below:

If you do not already have it, add the SUSE Observability helm repository to the local helm client:

helm repo add suse-observability https://charts.rancher.com/server-charts/prime/suse-observability
helm repo update
Deploy the SUSE Observability Kubernetes Node, Cluster and Checks Agents to namespace suse-observability with the helm command below:

helm upgrade --install \
--namespace suse-observability \
--create-namespace \
--set-string 'stackstate.apiKey'=$SERVICE_TOKEN \
--set-string 'stackstate.cluster.name'='harvester1' \
--set-string 'stackstate.url'='http://192.168.122.141:8090/receiver/stsAgent' \
suse-observability-agent suse-observability/suse-observability-agent
Once the SUSE Observability Kubernetes Node, Cluster and Checks Agents have been deployed, wait for data to be collected from the Kubernetes cluster and sent to SUSE Observability.
...
```

Copy and fill the values to 

### Create the experimental addons on a running Harvester cluster

```sh
kubectl apply -f https://raw.githubusercontent.com/harvester/experimental-addons/main/suse-observability-agent/suse-observability-agent.yaml
```

### Fill in above data to following fields

From Harvester UI, click `Addons`, locate `suse-observability-agent` and then click `Edit YAML`; or run `kubectl edit addons.harvesterhci -n suse-observability suse-observability-agent`, then:

Fill below fields

```
  valuesContent: |
    stackstate:
      apiKey: svctok-OxZrVBdB5g7UUESBNW1ozx5u7NrqaaBx // the generated token
      cluster:
        name: harvester1 // the instance name
      url: http://192.168.122.233:8090/receiver/stsAgent // the auto generated URL from SUSE Observability
```

:::note

If any of above fields does not match the value on SUSE Observability, the registration will fail.

:::

### Enable the addon

When the addon is successfully enabled, you will observe following PoDs are deployed to the `suse-observability` namespace on Harvester.

```
$ kubectl get pods -n suse-observability
NAME                                                      READY   STATUS      RESTARTS   AGE
helm-install-suse-observability-agent-tbk8w               0/1     Completed   0          7s
suse-observability-agent-checks-agent-5f5f5dc5b4-jgr6w    0/1     Running     0          5s
suse-observability-agent-cluster-agent-5f865f5f84-6q648   1/1     Running     0          5s
suse-observability-agent-logs-agent-rd6ks                 1/1     Running     0          5s
suse-observability-agent-node-agent-c5ldd                 1/2     Running     0          5s
suse-observability-agent-rbac-agent-7888cc47c9-pgj22      1/1     Running     0          5s
```

On `SUSE Observability`, the Harvester instance is registered.