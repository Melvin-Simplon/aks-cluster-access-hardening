# Step 1: Restrict API server access with an IP allowlist

## Goal

Limit access to the AKS control plane (the Kubernetes API server) to a known
list of source IP addresses. Every request coming from any other address is
rejected at the network level, before authentication even happens.

Target cluster: `aks-lab`, resource group `mpetitRG`, region France Central.

## Why this step comes first

By default an AKS public cluster exposes its API server to the entire internet.
Anyone who obtains a valid kubeconfig can reach it from anywhere.

This step does not fix *who* is allowed in, that is step 2 (Entra ID). It fixes
*from where* the cluster can be reached, which shrinks the attack surface
immediately and at low risk.

## Preconditions

Both were verified on `aks-lab` before applying the change:

| Requirement | Required value | Cluster value |
| --- | --- | --- |
| Load balancer SKU | `standard` | `standard` |
| Cluster type | public (not private) | public, `Public access to API server: Enabled` |

Authorized IP ranges are not supported on private clusters, and not supported
with the Basic load balancer SKU.

## Starting state

Azure portal, `aks-lab` > Networking > Resource settings:

```
Public access to API server : Enabled
Load balancer              : standard
Authorized IP ranges       : Not enabled
```

Anyone, from any network, can reach the API server endpoint.

Worth noting: running `az aks list` from an ordinary account on this
subscription returns the clusters of every other user on it. This is the exact
problem the mission describes, observed in the real environment rather than
assumed.

## Determining the address to authorize

The address to allow is the **public egress IP** of the network used to
administer the cluster, not a private LAN address.

```bash
# Option 1, the command used in the Microsoft documentation
CURRENT_IP=$(dig @resolver1.opendns.com ANY myip.opendns.com +short)

# Option 2, any public echo service
curl -s https://api.ipify.org
```

The value must be written in **CIDR notation**. A single address is a `/32`:

```
<ADMIN_IP>/32
```

> The real address used during the lab is intentionally not committed to this
> repository, which is public. Keep it in a local variable or a private note.

## Procedure

### Azure portal

1. Open the cluster, then **Networking** in the left menu.
2. Under **Resource settings**, find **Authorized IP ranges**, click **Manage**.
3. Tick **Set authorized IP ranges**.
4. Enter the CIDR, one per line.
5. Click **Save**.

### Azure CLI, equivalent

```bash
az aks update \
  --resource-group mpetitRG \
  --name aks-lab \
  --api-server-authorized-ip-ranges "<ADMIN_IP>/32"
```

**The flag replaces the whole list, it does not append to it.** To add an
address, pass the complete list again, comma separated.

## Expected impact

| Effect | Detail |
| --- | --- |
| Requests from an authorized IP | Unchanged, reach the API server normally |
| Requests from any other IP | Dropped, the client sees a connection timeout |
| Running workloads | Not affected, pods keep running |
| Propagation delay | Up to 2 minutes before the rules take effect |
| Reversibility | Fully reversible, see Rollback |

No downtime is expected for applications. Only administrative access changes.

## Verification

First refresh the kubeconfig, since it may still point at an older cluster:

```bash
az aks get-credentials --resource-group mpetitRG --name aks-lab
```

Then run the positive test, from the authorized network:

```bash
kubectl get nodes
```

Observed result:

```
NAME                                STATUS   ROLES    AGE   VERSION
aks-nodepool1-22164361-vmss000000   Ready    <none>   30m   v1.35.7
```

Then the negative test, from a different network such as a phone hotspot. The
same command must fail with a timeout. This second test is what actually proves
the restriction works, the first only proves it did not break anything.

## Troubleshooting

Two failure modes look similar but have opposite causes. Telling them apart
saves time:

| Error | Meaning |
| --- | --- |
| `Unable to connect to the server: dial tcp ... i/o timeout` | The address is genuinely blocked by the allowlist, or the rules are still propagating |
| `dial tcp: lookup <fqdn>: no such host` | DNS failure. The name does not exist, usually a kubeconfig pointing at a deleted cluster. Nothing to do with the allowlist |

The second case was hit during this lab: the kubeconfig still referenced a
previously deleted cluster. It was fixed by re-running `az aks get-credentials`
against `aks-lab`.

## Rollback

Emptying the list disables the restriction:

```bash
az aks update \
  --resource-group mpetitRG \
  --name aks-lab \
  --api-server-authorized-ip-ranges ""
```

This command goes through the Azure control plane, not through the Kubernetes
API server. It therefore still works when `kubectl` is locked out, which makes
it the recovery path if the wrong range is applied.

## Known limitations and risks

**Lockout risk.** If the configured range does not cover the current egress
address, administrative access is lost immediately. Always confirm the address
before saving, and keep the rollback command at hand.

**Dynamic addresses.** Consumer ISP lines usually hand out dynamic addresses.
When the address changes, access breaks with no warning and no change on the
Azure side. A fixed address, or a NAT gateway with a reserved public IP, is the
production answer.

**Cluster egress IP.** Microsoft recommends also allowing the cluster egress
address (firewall, NAT gateway, depending on the outbound type). The mission
statement asks for the office address only. This deviation is deliberate and
recorded here.

**Scale.** A maximum of 200 ranges is supported. Beyond that, API Server VNet
Integration allows up to 2000.

## References

- [Secure access to the API server using authorized IP address ranges (AKS)](https://learn.microsoft.com/azure/aks/api-server-authorized-ip-ranges)
- [Plan control plane networking for AKS](https://learn.microsoft.com/azure/aks/plan-control-plane-networking)
