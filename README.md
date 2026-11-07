# Enterprise Bot DevOps assignment

This repository contains a small Python/Flask service, its Docker image, a Helm chart, a one-command setup script, and the supplied debugging lab.

## Prerequisites

- Docker
- kind
- kubectl
- Helm
- Bash (I used Ubuntu through WSL)

## Run everything locally

From the repository root:

```bash
chmod +x setup.sh
./setup.sh
```

The script creates or reuses a kind cluster named `demo`, installs ingress-nginx, builds the service image, loads it into kind, and installs the Helm release `demo` in namespace `demo`.

The script is written to be idempotent, so it can be run again:

```bash
./setup.sh
```

Check the Kubernetes resources:

```bash
kubectl -n demo get deployments,pods,services,ingresses
kubectl -n demo rollout status deployment/demo-demo-service
```

Verify both endpoints through the Ingress:

```bash
curl --resolve demo.local:80:127.0.0.1 http://demo.local/
curl --resolve demo.local:80:127.0.0.1 http://demo.local/healthz
```

Expected response format:

```json
{"app":"enterprise-bot-demo","pod":"<pod-name>","version":"1.0.0"}
{"status":"ok"}
```

## Run the service tests

```bash
cd service
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
python -m unittest -v
```

The service reads `APP_NAME` and `VERSION` from environment variables. In Kubernetes, the ConfigMap is also mounted as projected files. The file values are checked on each request, so a ConfigMap projection update can be seen without restarting the Pod.

To test a ConfigMap update:

```bash
kubectl -n demo patch configmap demo-demo-service --type merge \
  -p '{"data":{"APP_NAME":"patched-demo","VERSION":"2.0.0"}}'

# Kubernetes may take some time to refresh the projected files.
curl --resolve demo.local:80:127.0.0.1 http://demo.local/
```

## Helm values and overrides

The chart keeps replicas, image, application configuration, Ingress, probes, and resources configurable through `chart/values.yaml`.

For example:

```bash
helm upgrade demo ./chart -n demo \
  --set replicaCount=3 \
  --set config.appName=override-demo \
  --set config.version=9.9.9 \
  --wait
```

## Resource choices

Each demo-service Pod requests `50m` CPU and `64Mi` memory. Its limits are `250m` CPU and `128Mi` memory.

I selected small values because this is a simple HTTP service with very little work and no database connection. The request gives the scheduler a realistic minimum, while the CPU limit allows short bursts. The memory limit is also enough for this small Flask/Gunicorn process. For a real service I would not treat these as final values. I would run load tests, check actual CPU and memory percentiles, and then adjust the requests and limits.

## Debug lab

The lab can be run with:

```bash
cd lab
./scenario.sh up
./scenario.sh verify
```

I fixed the chart problems relating to the Job restart policy, numeric non-root UID, worker writable cache, application port, gateway Service DNS, reporter RoleBinding, and metrics CPU resources. Details and actual command output are in `lab/FINDINGS.md`.

My final verification result was 9 of 11 checks passing. The remaining two checks are both for the reporter. After fixing RBAC, the reporter ServiceAccount could list Pods. A separate curl Pod using the same ServiceAccount received a valid 118,653-byte `PodList`, but the supplied `docker.io/ebinterview/eb-debug-app:1.0.1` reporter still logged `parse pod list: unexpected end of JSON input`.

I did not change the pinned image, add a fake reporter, or disable readiness just to make the result green. I would ask the assignment owner to confirm the expected image digest or provide a corrected image.

## Deliberately skipped and risks

- I did not bypass the broken reporter behaviour. This leaves two lab checks failing, but hiding the failure would break the lab rules and give a false result.
- I did not add TLS or certificate management. This is acceptable only for the local kind setup; production traffic should be encrypted.
- I did not add NetworkPolicies, an HPA, or a PodDisruptionBudget. Without these, production isolation, scaling, and availability during disruptions are weaker.
- I did not add a secret manager because this demo service has no secrets. Production credentials should not be kept in Git or plain Helm values.
- I skipped the optional CI workflow due to the time limit. The risk is that linting, image scanning, and integration checks are not automatically enforced on every change.

## What I would improve for production

I would add TLS with automated certificate rotation, NetworkPolicies, a dedicated ServiceAccount with least privilege, PodDisruptionBudget, topology spread constraints, and autoscaling based on measured load. I would also add structured logs, metrics, tracing, alerts, and SLOs. The image should be scanned, signed, and deployed using an immutable digest with an SBOM. Finally, I would use a CI/CD pipeline with Helm linting, policy checks, tests against supported Kubernetes versions, and staged promotion between environments.

## How I used AI

I used ChatGPT. It helped me understand the assignment, review the Python, Docker, Helm, and shell files, and suggested Kubernetes commands while I debugged the lab. I ran the commands myself in my local kind cluster, read the output, and made the changes one by one.

I also used it to organise this README and the findings after the debugging was completed. I had to correct a few suggestions during the work. For example, the first ConfigMap test exposed the required file-over-environment behaviour, the Windows/WSL commands needed adjustment, and a BusyBox `wget` diagnostic failed because of TLS, so I repeated the check with a curl image. The terminal outputs and final verification result in this repository are from my own local environment.
