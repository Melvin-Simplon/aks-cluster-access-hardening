# Step 3: Resource limitation policy in the `prod` namespace

## Goal

Create a `prod` namespace and constrain what workloads running in it are allowed
to consume, so that a single misbehaving application cannot starve the rest of
the cluster.

The brief states that the exact values do not matter. They were still chosen to
be coherent with the lab cluster, and the reasoning is given below.

## Why two objects and not one

This is the part worth understanding, because `ResourceQuota` and `LimitRange`
are often confused.

| | ResourceQuota | LimitRange |
| --- | --- | --- |
| Scope | the namespace as a whole | each container individually |
| Answers | "how much may this namespace consume in total?" | "how much may one container ask for, and what does it get if it asks for nothing?" |
| Effect when exceeded | the pod is refused at creation | the pod is refused, or given defaults |

They are complementary. A quota alone lets one pod swallow the entire namespace
budget. A LimitRange alone caps each container but places no ceiling on their
number.

**There is also a dependency between them that is easy to get wrong.** As soon
as a `ResourceQuota` constrains `cpu` or `memory`, the API server rejects every
pod that does not declare the corresponding requests and limits. Applying a
quota to a namespace where manifests omit `resources:` breaks those deployments
immediately.

The `LimitRange` is what prevents that: it injects default requests and limits
into any container that declares none, so existing manifests keep working
unchanged. This is the reason the two objects are applied together.

## What is applied

All three manifests live in [`k8s/prod/`](../../k8s/prod/).

### The namespace

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: prod
  labels:
    environment: production
```

### The namespace ceiling

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: prod-quota
  namespace: prod
spec:
  hard:
    requests.cpu: "1"
    requests.memory: 2Gi
    limits.cpu: "2"
    limits.memory: 4Gi
    pods: "20"
    persistentvolumeclaims: "5"
    services.loadbalancers: "2"
```

`requests` is what the scheduler reserves, `limits` is the hard ceiling at
runtime. Limits are deliberately set above requests: that is normal
overcommitment, workloads are allowed to burst beyond what they reserved.

The `services.loadbalancers` entry is there for a practical reason: every
LoadBalancer service provisions a billable Azure public IP. Capping them is a
cost control as much as a technical one.

### The per-container rules

```yaml
apiVersion: v1
kind: LimitRange
metadata:
  name: prod-limits
  namespace: prod
spec:
  limits:
    - type: Container
      default:
        cpu: 500m
        memory: 512Mi
      defaultRequest:
        cpu: 100m
        memory: 128Mi
      min:
        cpu: 50m
        memory: 64Mi
      max:
        cpu: "1"
        memory: 2Gi
```

`default` and `defaultRequest` are filled in when a container says nothing.
`min` and `max` bound what a container is allowed to ask for explicitly.

## Why these values

The lab cluster is a single `Standard_B2s` node, 2 vCPU and 4 GiB, of which
roughly 1.5 GiB is reserved by the system.

The quota is set slightly below that capacity on requests, so that a pod
accepted by the quota also has a realistic chance of being scheduled. A quota
larger than the cluster is perfectly legal and would still be accepted by the
API server, but pods would then pass the quota check and stay `Pending` forever
for lack of a node to run on. That failure mode is confusing to diagnose, and it
is worth avoiding even in a lab.

## Procedure

```bash
kubectl apply -f k8s/prod/
```

The filenames are numbered so that a plain directory apply creates the namespace
before the objects that live inside it.

## Expected impact

| Effect | Detail |
| --- | --- |
| Pods without `resources:` | Accepted, and silently given the LimitRange defaults |
| Pods asking beyond `max` | Rejected at creation, with an explicit error |
| Namespace total exceeded | Rejected at creation, quota error naming the resource |
| Existing namespaces | Unaffected, both objects are namespace scoped |
| Running pods | Unaffected, neither object is applied retroactively |

That last row matters: applying a quota does not evict or resize anything that
is already running. It only governs what is admitted from now on.

## Verification

Current consumption against the ceiling:

```bash
kubectl describe resourcequota prod-quota -n prod
kubectl describe limitrange prod-limits -n prod
```

Check that the defaults are really injected, by creating a pod that declares no
resources at all:

```bash
kubectl run quota-test --image=nginx -n prod

kubectl get pod quota-test -n prod \
  -o jsonpath='{.spec.containers[0].resources}{"\n"}'
# expected: requests cpu=100m memory=128Mi, limits cpu=500m memory=512Mi

kubectl delete pod quota-test -n prod
```

Check that the ceiling is enforced, by asking for more than `max` allows:

```bash
kubectl run quota-test-big --image=nginx -n prod \
  --overrides='{"spec":{"containers":[{"name":"quota-test-big","image":"nginx","resources":{"requests":{"cpu":"4"}}}]}}'
# expected: rejected, maximum cpu usage per Container is 1
```

Those two commands are the real proof. The first shows the defaults being
applied, the second shows the limit being enforced.

## Rollback

```bash
kubectl delete -f k8s/prod/
```

Deleting the namespace also deletes everything inside it, so on a namespace that
holds real workloads, remove only the two policy objects:

```bash
kubectl delete resourcequota prod-quota -n prod
kubectl delete limitrange prod-limits  -n prod
```

## Known limitations

**Nothing here restricts who may deploy into `prod`.** Resource limits and
access control are separate concerns. Restricting deployment rights per
namespace is done with Kubernetes RBAC, as covered in step 2.

**A quota is not a reservation.** It caps what may be requested, it does not
guarantee the cluster has the capacity to satisfy it.

**Pods created before the quota are untouched.** On an existing production
namespace, the policy has to be introduced alongside a review of running
workloads, otherwise the first restart of an oversized pod fails.

## References

- [Resource Quotas](https://kubernetes.io/docs/concepts/policy/resource-quotas/)
- [Limit Ranges](https://kubernetes.io/docs/concepts/policy/limit-range/)
- [Managing Resources for Containers](https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/)
