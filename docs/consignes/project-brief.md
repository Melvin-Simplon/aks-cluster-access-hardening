# Project Brief

## Summary

A company runs a Kubernetes cluster in production that every user on the Azure
subscription can access. The situation has become critical, so you are assigned
to fix the problem: set up clean permission management, and restrict access to
the Kubernetes control plane based on IP address. While you are at it, you will
also put in place the other restrictions detailed in the mission objectives.

One of their applications authenticates to Azure using an access key hardcoded
in a Kubernetes Secret, and uses it to deploy arbitrary resources. You will
explain which mechanism lets an application (a pod) authenticate to the cloud
without going through a secret, how it works in practice, and finally how to set
it up on Kubernetes and on AKS.

Every step must be documented in a git repository. The company wants a precise
plan of what will be applied in production, and wants to know what to expect at
each step.

## Objectives

1. Reproduce the situation on your own test cluster ("Local RBAC", Azure
   Monitoring "OFF", public cluster with no IP restriction).
2. Have your setup validated by the trainer before going further.
3. Set up an IP allowlist, authorizing the Simplon premises IP only.
4. Enable authentication and authorization based on Entra ID.
   - One Entra ID group represents the cluster "admins", containing only you.
   - A second group represents the "readers", containing the trainer.
   - Both groups, and only their members, must be able to connect to the
     cluster.
5. In a `prod` namespace, set up a resource limitation policy (the actual values
   do not matter).
6. Explain how to authenticate to the cloud without an access key (a "medium"
   level of detail is expected).

## Out of scope

- Infrastructure as Code
- CI/CD

## Bonus

- The organization of the Entra ID groups and their associated roles is
  described in a clean diagram (draw.io style).
- Given an AKS cluster ID or name, a script of your choice runs through all of
  your steps one by one.

## Teaching arrangements

- To be done alone.
- Duration: 2 days.
- Collaboration tool: your choice.

## Assessment

- Review of your repository and documents.
