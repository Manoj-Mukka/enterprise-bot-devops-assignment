# Findings — Part 4 debug lab

I found seven chart problems even though the brief mentions six. I fixed them without modifying `cluster-state/`, changing the supplied image, or deleting any workload to hide a failure. The last section documents a separate issue that remains inside the supplied reporter image.

## Defect 1 — invalid restart policy on the migration Job

**Symptom**

The first Helm installation failed with this validation error:

```text
Job.batch "migrate" is invalid: spec.template.spec.restartPolicy:
Required value: valid values: "OnFailure", "Never"
```

**Cause**

The migration Job used `restartPolicy: Always`. Kubernetes Jobs allow only `OnFailure` or `Never`.

**Fix**

I changed the restart policy to `OnFailure`. This allows Kubernetes to retry a failed migration container while keeping the manifest valid for a Job.

**How I found it**

`./scenario.sh up` printed the API validation error before the remaining workloads could be investigated. I opened `broken-chart/templates/migrate-job.yaml` and found `restartPolicy: Always` in the Pod template.

---

## Defect 2 — Kubernetes could not verify the named image user

**Symptom**

All Pods stayed in `CreateContainerConfigError`. The migration Pod event showed:

```text
Warning  Failed  kubelet  Error: container has runAsNonRoot and image has
non-numeric user (nonroot), cannot verify user is non-root
```

The image inspection also showed:

```text
ConfiguredUser="nonroot"
```

**Cause**

The image declares a user by the name `nonroot`. The chart enabled `runAsNonRoot`, but kubelet could not verify from a name alone that the UID was not zero.

**Fix**

I kept `runAsNonRoot: true` and added `runAsUser: 65532` to all six workload container security contexts. I did not disable the security check.

**How I found it**

I first ran `kubectl -n debug-lab get pods`, which showed the same configuration error everywhere. Then `kubectl -n debug-lab describe pod migrate-...` showed the exact kubelet message. I searched all the templates for `runAsNonRoot` and applied the same numeric UID consistently.

---

## Defect 3 — worker cache path was read-only

**Symptom**

The worker entered `CrashLoopBackOff`. Its log was:

```text
FATAL: worker could not initialise its cache: mkdir /var/cache/app:
read-only file system — the process needs a writable directory at
/var/cache/app (mount a volume there, or set CACHE_DIR)
```

**Cause**

The container correctly had `readOnlyRootFilesystem: true`, but the worker needed to create files below `/var/cache/app`. No writable volume was mounted there.

**Fix**

I added an `emptyDir` volume called `cache` and mounted it at `/var/cache/app`. This keeps the rest of the container filesystem read-only.

**How I found it**

The worker was the only Pod crashing after the UID correction. I used `kubectl -n debug-lab logs deployment/worker --previous`, and the application log gave the failing directory. After the fix, the new Pod showed `/var/cache/app from cache (rw)` and zero restarts.

---

## Defect 4 — readiness probes used the wrong application port

**Symptom**

The containers were running but remained `0/1 Ready`. Backend logs showed:

```text
eb-debug-app 2.0.0 starting: mode=api ... listening on :8081
(image default is 8081; set PORT to override)
```

The Pod event showed:

```text
Readiness probe failed: Get "http://10.244.0.18:8080/healthz":
dial tcp 10.244.0.18:8080: connect: connection refused
```

**Cause**

The chart set `common.port` to 8080, but the supplied image listens on 8081 by default. The container ports, probes, and Service target ports were therefore pointing to a closed port.

**Fix**

I changed `common.port` to 8081. I kept the public backend and reporter Service port at 8080 and the gateway Service port at 80. Only their target port changed to the actual container port.

**How I found it**

I compared `kubectl logs deployment/backend`, the readiness event from `kubectl describe`, the Service output, and `common.port` in `values.yaml`. The application log clearly stated 8081 while the probe was using 8080.

---

## Defect 5 — gateway was resolving backend in the wrong namespace

**Symptom**

The gateway remained unready and returned HTTP 503 from `/healthz`. Its logs showed:

```text
readiness failed: backend not reachable:
GET http://backend.default.svc:8080/healthz:
dial tcp: lookup backend.default.svc on 10.96.0.10:53: no such host
```

**Cause**

`BACKEND_URL` referred to the backend Service in the `default` namespace, but both applications were installed in `debug-lab`.

**Fix**

I changed the URL to `http://backend:8080`. The short Service name resolves in the current namespace and does not hardcode the namespace name.

**How I found it**

I selected the newest gateway Pod, read its logs, and inspected the environment value in the live Deployment and in `values.yaml`. The failed hostname included the wrong namespace directly.

---

## Defect 6 — reporter RoleBinding targeted the wrong ServiceAccount

**Symptom**

Reporter logs initially showed an HTTP 403:

```text
pods is forbidden: User "system:serviceaccount:debug-lab:reporter"
cannot list resource "pods" in API group "" in the namespace "debug-lab"
```

The permission checks showed:

```text
$ kubectl auth can-i list pods -n debug-lab \
    --as=system:serviceaccount:debug-lab:reporter
no

$ kubectl auth can-i list pods -n debug-lab \
    --as=system:serviceaccount:debug-lab:default
yes
```

The live RoleBinding subject was `default`.

**Cause**

The reporter Pod used the `reporter` ServiceAccount, but the RoleBinding granted the Role to the `default` ServiceAccount.

**Fix**

I changed the ServiceAccount resource and RoleBinding subject to use `{{ .Values.reporter.serviceAccountName }}`. The existing Role already had the required `get` and `list` permissions, so I did not grant anything broader.

**How I found it**

I checked the reporter logs, confirmed the Pod's ServiceAccount, compared `kubectl auth can-i` for `reporter` and `default`, and then inspected `kubectl -n debug-lab get rolebinding reporter-read -o yaml`. After upgrading, the verifier confirmed that `debug-lab/reporter` could list Pods.

---

## Defect 7 — metrics resources violated the namespace LimitRange

**Symptom**

The metrics Deployment had zero up-to-date replicas. The newest ReplicaSet reported:

```text
Warning  FailedCreate  replicaset-controller  Error creating:
pods "metrics-764bbdc887-..." is forbidden: maximum cpu usage per
Container is 1, but limit is 4
```

The chart configured:

```yaml
requests:
  cpu: "2"
limits:
  cpu: "4"
```

The supplied LimitRange allowed a maximum CPU value of `1` per container.

**Cause**

The metrics request and limit were above the namespace guardrail, so admission rejected every new Pod before it could be scheduled.

**Fix**

I changed the metrics CPU request to `50m` and its CPU limit to `200m`, matching the size of the other lightweight lab processes. I did not modify the supplied LimitRange.

**How I found it**

`kubectl get deployments` showed `metrics` with zero up-to-date replicas even though an older Pod existed. I inspected the newest ReplicaSet events and then compared `values.yaml` with `kubectl -n debug-lab get limitrange debug-lab-guardrails -o yaml`. After the change, metrics became `1/1 Ready`.

---

## Unresolved supplied-image issue — reporter cannot parse a valid PodList

**Symptom**

After the RoleBinding fix, authorization passed but the reporter remained unready:

```text
$ kubectl auth can-i list pods -n debug-lab \
    --as=system:serviceaccount:debug-lab:reporter
yes

pod list failed: parse pod list: unexpected end of JSON input
GET /healthz -> 503
```

The reporter EndpointSlice showed both endpoints as not ready:

```text
["10.244.0.23"] ready=false
["10.244.0.29"] ready=false
```

I tested the Kubernetes API from a temporary curl Pod using the same reporter ServiceAccount:

```text
Response bytes:
118653
Beginning of response:
{
  "kind": "PodList",
  "apiVersion": "v1",
  "metadata": {
```

**Cause found so far**

The Kubernetes API and RBAC return a valid PodList, but the reporter process in the supplied image fails while parsing that response. This isolates the remaining problem to the supplied reporter image or its API client. The source code for this image is not provided.

**Fix status**

I did not change the required image, add a replacement reporter, remove readiness, or return a fake Pod count. Those options would hide the actual fault and violate the lab rules. The final result is 9 of 11 checks passing, with only the two reporter runtime checks failing.

**Clarification I would ask**

> The reporter ServiceAccount is authorized, and the same ServiceAccount retrieves a valid 118,653-byte PodList from the Kubernetes API. The pinned `eb-debug-app:1.0.1` reporter still fails with `unexpected end of JSON input`. Could you please confirm the expected image digest or whether a corrected image is available?

## Environment note

On my Windows/WSL setup, the first directory apply created the namespace but briefly failed to create the LimitRange because the namespace was not found yet:

```text
namespace/debug-lab created
Error from server (NotFound): error when creating "cluster-state\\limits.yaml":
namespaces "debug-lab" not found
```

I reapplied the unchanged `cluster-state/` directory after the namespace existed. The LimitRange was then created successfully. I did not edit either cluster-state file.
