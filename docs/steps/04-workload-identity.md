# Step 4: Authenticating to Azure without an access key

## The problem being solved

One of the applications on the cluster authenticates to Azure with an access key
stored in a Kubernetes Secret, and uses it to deploy resources.

A Kubernetes Secret is not encrypted, it is base64 encoded. That distinction
matters, because it means the key is readable by anyone who can read Secrets in
that namespace, it sits in the cluster datastore, it appears in backups and in
any manifest or pipeline that created it, and it stays valid until a human
remembers to rotate it. It also carries no information about *who* used it, so
an audit trail cannot distinguish the application from someone who copied the
key months ago.

The fix is not a better place to store the key. It is to stop having one.

## The mechanism: Microsoft Entra Workload ID

The idea is to replace a shared secret with **proof of identity issued by the
cluster itself**, verified cryptographically by Entra ID.

Kubernetes can act as an OpenID Connect identity provider. It signs short lived
tokens describing which service account a pod runs as, and publishes the public
keys needed to verify them. Entra ID is configured to trust that issuer, for one
specific service account, and to hand out an Azure token in exchange.

The same pattern exists everywhere under different names: IAM Roles for Service
Accounts on EKS, Workload Identity on GKE, OIDC federation for GitHub Actions.
Understanding it once covers all of them.

## How it works concretely

What happens when a pod calls Azure:

1. The cluster exposes an **OIDC issuer URL**, a public endpoint serving the
   OpenID discovery document and the JWKS, which is the set of public keys used
   to verify its signatures. Nothing secret is published there.

2. The kubelet **projects a service account token** into the pod as a file. That
   token is a JWT signed by the cluster, valid one hour by default, whose
   `sub` claim is `system:serviceaccount:<namespace>:<name>` and whose audience
   is `api://AzureADTokenExchange`.

3. A **mutating admission webhook** injects the plumbing into every pod carrying
   the `azure.workload.identity/use: "true"` label: the token volume, plus the
   environment variables `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`,
   `AZURE_FEDERATED_TOKEN_FILE` and `AZURE_AUTHORITY_HOST`.

4. The application, through an Azure Identity SDK or MSAL, reads that file and
   presents it to Entra ID as a **client assertion**, asking for a token for the
   identity named by `AZURE_CLIENT_ID`.

5. Entra ID fetches the cluster's public keys from the issuer URL, verifies the
   signature, then checks the token against the **federated identity credential**
   configured on that identity: does the issuer match, does the subject match,
   does the audience match. All three must match.

6. Entra ID returns a standard **Azure access token**, valid 24 hours.

7. The application calls Azure with it, and Azure RBAC decides what it may do.

The property that matters: **no secret is stored, transmitted or rotated at any
point.** Trust comes from the cluster's signature and from a declaration made in
advance about which service account is allowed to speak for which identity. A
token stolen from a pod expires in an hour, and only works for the one identity
it was scoped to.

## Setting it up on AKS

### 1. Enable the cluster features

```bash
az aks update \
  --resource-group mpetitRG \
  --name aks-lab \
  --enable-oidc-issuer \
  --enable-workload-identity

AKS_OIDC_ISSUER=$(az aks show -g mpetitRG -n aks-lab \
  --query "oidcIssuerProfile.issuerUrl" -o tsv)
```

`--enable-oidc-issuer` publishes the discovery endpoint. `--enable-workload-identity`
installs the mutating webhook. On AKS Automatic both are preconfigured.

Two things to know before running this on production: enabling the OIDC issuer
on an existing cluster causes a **brief control plane interruption**, and once
enabled **it cannot be disabled**.

### 2. Create the Azure identity

```bash
az identity create --resource-group mpetitRG --name id-prod-app

CLIENT_ID=$(az identity show -g mpetitRG -n id-prod-app --query clientId -o tsv)
IDENTITY_ID=$(az identity show -g mpetitRG -n id-prod-app --query principalId -o tsv)
```

A user-assigned managed identity. Prefer one identity per workload, so that Azure
permissions can be scoped to exactly what that workload needs.

### 3. Create the Kubernetes service account

Defined in [`k8s/workload-identity/serviceaccount.yaml`](../../k8s/workload-identity/serviceaccount.yaml):

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: prod-app
  namespace: prod
  annotations:
    azure.workload.identity/client-id: __MANAGED_IDENTITY_CLIENT_ID__
```

```bash
sed "s/__MANAGED_IDENTITY_CLIENT_ID__/$CLIENT_ID/" \
  k8s/workload-identity/serviceaccount.yaml | kubectl apply -f -
```

A client id is a public identifier, not a credential. Writing it in a manifest
leaks nothing.

### 4. Declare the trust in Entra ID

This is the step that replaces the access key.

```bash
az identity federated-credential create \
  --name fc-prod-app \
  --identity-name id-prod-app \
  --resource-group mpetitRG \
  --issuer "$AKS_OIDC_ISSUER" \
  --subject "system:serviceaccount:prod:prod-app" \
  --audience api://AzureADTokenExchange
```

Read it as a sentence: *the identity `id-prod-app` accepts tokens issued by this
cluster, for the service account `prod-app` in the namespace `prod`, and for no
one else.*

Change the namespace or the service account name, and authentication stops
working. That is the point.

### 5. Give the identity its Azure permissions

```bash
az role assignment create \
  --assignee-object-id "$IDENTITY_ID" \
  --assignee-principal-type ServicePrincipal \
  --role "Contributor" \
  --scope "/subscriptions/<SUBSCRIPTION_ID>/resourceGroups/mpetitRG"
```

`Contributor` is used here only because the application in the brief deploys
arbitrary resources. Any real workload should get the narrowest role that covers
its actual needs.

### 6. Deploy the workload

[`k8s/workload-identity/demo-pod.yaml`](../../k8s/workload-identity/demo-pod.yaml)
signs in to Azure and prints the resulting account, with no credential anywhere
in its specification.

```bash
kubectl apply -f k8s/workload-identity/demo-pod.yaml
kubectl logs workload-identity-demo -n prod
```

**The `azure.workload.identity/use: "true"` label is mandatory.** Only labelled
pods are mutated by the webhook. Without it the pod starts normally and fails to
authenticate, which is a confusing failure to diagnose.

### Verification

```bash
# the variables injected by the webhook, no secret among them
kubectl exec workload-identity-demo -n prod -- env | grep AZURE_

# the projected token, signed by the cluster, valid one hour
kubectl exec workload-identity-demo -n prod -- \
  cat /var/run/secrets/azure/tokens/azure-identity-token

# and the proof that nothing was stored
kubectl get secrets -n prod
```

That last command is the demonstration worth keeping: the pod authenticates to
Azure while the namespace holds no credential at all.

## Setting it up on plain Kubernetes

The mechanism is identical, but AKS hides three things that must be handled
manually elsewhere.

**Publishing the OIDC issuer.** The API server is started with
`--service-account-issuer` set to a publicly reachable HTTPS URL, along with
`--service-account-signing-key-file` and `--api-audiences`. The discovery
document and the JWKS must then be served at that URL. A common approach is to
copy them into a public object storage bucket, since Entra ID must reach them
from outside the cluster and will not authenticate to do so.

**Installing the webhook.** The `azure-workload-identity` mutating admission
webhook is installed with Helm. It is the component that injects the token
volume and the environment variables.

**Registering the federated credential.** Identical to AKS, except the issuer URL
is the one published above. The identity can be a managed identity or a plain
app registration.

Everything after that, the annotated service account, the labelled pod, the SDK
performing the exchange, is unchanged.

## Comparison

| | Access key in a Secret | Workload Identity |
| --- | --- | --- |
| Stored credential | yes, long lived | none |
| Readable by | anyone who can read the Secret | nobody, there is nothing to read |
| Lifetime | until manually rotated | 1 hour for the cluster token, 24 hours for the Azure token |
| Scope | whatever the key was granted | one service account, one namespace |
| On theft | valid until noticed and rotated | expires on its own, unusable elsewhere |
| Rotation | manual, and often forgotten | automatic, nothing to rotate |
| Audit | one shared identity | the workload's own identity |

## Limitations and things to know

**The OIDC issuer cannot be disabled** once enabled on a cluster.

**20 federated identity credentials per user-assigned identity.** Sharing one
identity across many clusters hits this ceiling. Identity bindings for AKS exist
to work around it.

**The application must use a recent SDK.** The exchange is performed by the Azure
Identity libraries or MSAL. Code that reads a connection string from an
environment variable has to be adapted.

**Pod-managed identity is the old answer and is deprecated.** It relied on
intercepting IMDS calls. Workload Identity replaces it and is the supported path.

**Restart after changing annotations.** Updating a service account annotation
requires restarting the pods for the change to take effect.

## References

- [Microsoft Entra Workload ID overview](https://learn.microsoft.com/azure/aks/workload-identity-overview)
- [Deploy and configure workload identity on an AKS cluster](https://learn.microsoft.com/azure/aks/workload-identity-deploy-cluster)
- [Use the OIDC issuer on AKS](https://learn.microsoft.com/azure/aks/use-oidc-issuer)
- [Overview of federated identity credentials in Microsoft Entra ID](https://learn.microsoft.com/graph/api/resources/federatedidentitycredentials-overview)
- [Service Account Token Volume Projection (Kubernetes)](https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/#serviceaccount-token-volume-projection)
