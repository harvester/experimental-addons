# rancher-vcluster

The rancher-vcluster addon leverages [vcluster](https://github.com/loft-sh/vcluster) to create a vcluster named `rancher-vcluster` in the `harvester-system` namespace.

The addon will also inject additional manifests to configure and install a fully functional rancher.

The rancher will be using a self signed certificate.

~~Users can define the rancher version and rancher url via the `valuesContent` section in the addon.~~
(this is no longer relevant please see "NOTE" heading section, things must be edited in the valuesContent.global section of the addon now)
```
#    hostname: "rancher.172.19.108.3.sslip.io"
#    rancherVersion: "v2.7.4"
```

The vcluster will sync the ingress for the newly deployed rancher to the underlying harvester cluster.

Users need to ensure that the `hostname` defined for accessing rancher is accessible via a DNS record pointing to the harvester vip.

Updates to `rancherVersion` in the contentValues can be used to trigger rancher upgrades in the vcluster.

Similar workflow can also be used to trigger k3s upgrades.

*NOTE:* The rancher deployed in vcluster can be used for managing the underlying harvester, including provisioning more downstream clusters. Please be aware that running rancher in vcluster is not as secure as a separate VM based install. A user with cluster level or project admin access to harvester-system namespace, will be able to access the rancher deployed in the vcluster.

# NOTE:
- Rancher vCluster Experimental Addon starting from December 2025 users will need to either generate their own manifest or Edit As YAML to provide correct values for global.hostname, global.bootstrapPassword, global.rancherVersion.
- [PR For Reference That Introduced The Change With Further Info](https://github.com/harvester/experimental-addons/pull/39)

### sample manifest w/ Rancher v2.13.1:
```
---
apiVersion: v1
kind: Namespace
metadata:
  name: rancher-vcluster
---
apiVersion: harvesterhci.io/v1beta1
kind: Addon
metadata:
  name: rancher-vcluster
  namespace: rancher-vcluster
  labels:
    addon.harvesterhci.io/experimental: "true"
spec:
  enabled: true
  repo: https://charts.loft.sh
  version: "v0.30.0"
  chart: vcluster
  valuesContent: |-
    global:
      hostname: "rancher-vcluster.192.168.104.136.sslip.io"
      rancherVersion: v2.13.1
      bootstrapPassword: "testtesttest"

    sync:
      toHost:
        ingresses:
          enabled: true

    controlPlane:
      distro:
        k3s:
          enabled: true
          image:
            registry: ""
            repository: "rancher/k3s"
            tag: "v1.34.4-k3s1"
          securityContext: {}
          resources:
            limits:
              cpu: 200m
              memory: 512Mi
            requests:
              cpu: 40m
              memory: 64Mi
      backingStore:
        database:
          embedded:
            enabled: true

      statefulSet:
        image:
          registry: "ghcr.io"
          repository: "loft-sh/vcluster-pro"
          tag: "0.30.0"
        resources:
          # Limits are resource limits for the container
          limits:
            ephemeral-storage: 30Gi
            memory: 6Gi
          # Requests are minimal resources that will be consumed by the container
          requests:
            ephemeral-storage: 1Gi
            cpu: 200m
            memory: 256Mi

    experimental:
      deploy:
        vcluster:
          manifestsTemplate: |-
            apiVersion: v1
            kind: Namespace
            metadata:
              name: cattle-system
            ---
            apiVersion: v1
            kind: Namespace
            metadata:
              name: cert-manager
              labels:
                certmanager.k8s.io/disable-validation: "true"
            ---
            apiVersion: helm.cattle.io/v1
            kind: HelmChart
            metadata:
              name: cert-manager
              namespace: kube-system
            spec:
              targetNamespace: cert-manager
              repo: https://charts.jetstack.io
              chart: cert-manager
              version: v1.18.0
              helmVersion: v3
              set:
                installCRDs: "true"
            ---
            apiVersion: helm.cattle.io/v1
            kind: HelmChart
            metadata:
              name: rancher
              namespace: kube-system
            spec:
              targetNamespace: cattle-system
              repo: https://releases.rancher.com/server-charts/latest
              chart: rancher
              version: {{ .Values.global.rancherVersion }}
              set:
                ingress.tls.source: rancher
                hostname: {{ .Values.global.hostname }}
                replicas: 1
                global.cattle.psp.enabled: "false"
                bootstrapPassword: {{ .Values.global.bootstrapPassword }}
              helmVersion: v3
```


### example connection to vcluster flow w/ Harvester cluster's kubeconfig

```bash

╭─mike at suse-workstation-team-harvester in ~
╰─○ sudo vcluster upgrade
[sudo] password for mike: 
14:04:18 info Downloading newest version...
14:04:19 done Successfully updated to version 0.32.1
14:04:19 info Release note: 

## What's Changed
* [v0.32] chore(ci): remove slack release notification from vcluster (#3594) by @loft-bot in https://github.com/loft-sh/vcluster/pull/3603
* [v0.32] refactor: make pulling binaries more resilient (#3608) by @loft-bot in https://github.com/loft-sh/vcluster/pull/3609


**Full Changelog**: https://github.com/loft-sh/vcluster/compare/v0.32.0...v0.32.1
╭─mike at suse-workstation-team-harvester in ~
╰─○ vcluster connect -n rancher-vcluster rancher-vcluster
14:04:37 done vCluster is up and running
14:04:37 info Stopping background proxy...
14:04:37 info Starting background proxy container...
14:04:41 done Switched active kube context to vcluster_rancher-vcluster_rancher-vcluster_local
- Use `vcluster disconnect` to return to your previous kube context
- Use `kubectl get namespaces` to access the vcluster
╭─mike at suse-workstation-team-harvester in ~
╰─○ k9s
╭─mike at suse-workstation-team-harvester in ~
╰─○ vcluster disconnect
14:04:56 info Successfully disconnected and switched back to the original context: local


```
