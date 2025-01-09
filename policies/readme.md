
# Kubernetes Network Policies - Usage Guide

This repository contains network policies and test scripts to validate network isolation and connectivity within a Kubernetes cluster. The policies are organized into tiers (`app` and `security`), and test scripts are provided to validate their functionality.

## Folder Structure

```plaintext
.
├── policies
│   ├── app
│   │   ├── allow-app-ingress.yaml
│   │   ├── allow-intra-namespace.yaml
│   │   ├── allow-selected.yaml
│   │   ├── default-deny.yaml
│   │   ├── egress-policy.yaml
│   │   ├── inter-namespace-policy.yaml
│   │   ├── pod-quarantine-policy.yaml
│   ├── security
│   │   ├── allow-external-api.yaml
│   │   ├── deny-all-global.yaml
├── tests
│   ├── create-test-pods.sh
│   ├── egress-policy.sh
│   ├── inter-namespace.sh
│   ├── pod-quarantine.sh
│   ├── test-external-access.sh
│   ├── test-global-policy.sh
│   ├── test-intra-namespace.sh
```

---

## Policy Tiering

### **Security Tier**
- Policies in the `security` folder are global and managed by the security team.
- These policies enforce global rules such as denying all traffic by default or allowing external API access for specific namespaces.
- Example: `deny-all-global.yaml` ensures all traffic is denied unless explicitly allowed by application-level policies.

### **Application Tier**
- Policies in the `app` folder are specific to application teams.
- These policies manage traffic within namespaces or between specific pods and services.
- Example: `allow-intra-namespace.yaml` allows communication between pods with matching labels within the same namespace.

### **How Tiering Works**
- Tiers define the order in which policies are applied.
- `security` tier policies have higher precedence, ensuring organization-wide rules are enforced before application-specific rules.
- **Use Case:** If the security team applies a `deny-all-global` policy in the `security` tier, the application team can only add exceptions (e.g., for specific egress or ingress rules) in the `app` tier.

---

## Quarantine Policy

The quarantine policy isolates pods by applying ingress and egress restrictions to pods with the `quarantine=true` label.

### **Policy Example**

```yaml
apiVersion: crd.projectcalico.org/v1
kind: GlobalNetworkPolicy
metadata:
  name: pod-quarantine-policy
spec:
  tier: security
  order: 100
  selector: quarantine == 'true'
  types:
    - Ingress
    - Egress
  ingress:
    - action: Deny
  egress:
    - action: Deny
```

**How It Works:**
1. Any pod labeled with `quarantine=true` is denied all ingress and egress traffic.
2. To quarantine a pod:
   ```bash
   kubectl label pod <pod-name> quarantine=true
   ```
3. To remove quarantine:
   ```bash
   kubectl label pod <pod-name> quarantine-
   ```

---

## Prerequisites

1. **Ensure Kubernetes Context**:
   ```bash
   kubectl config current-context
   ```

2. **Install Necessary Tools**:
   Ensure `kubectl` and `calicoctl` are installed and configured.

3. **Namespace Creation**:
   Create namespaces required by the test pods:
   ```bash
   kubectl create namespace app-namespace || true
   kubectl create namespace test-namespace || true
   ```

4. **Create Test Pods**:
   Use the `create-test-pods.sh` script to create test pods:
   ```bash
   ./tests/create-test-pods.sh
   ```

---

## How to Run Tests

### **1. Test Intra-Namespace Policy**
Validates communication between pods within the same namespace.
   ```bash
   ./tests/test-intra-namespace.sh
   ```

### **2. Test Inter-Namespace Policy**
Validates communication between pods across different namespaces.
   ```bash
   ./tests/inter-namespace.sh
   ```

### **3. Test Quarantine Policy**
Ensures quarantined pods cannot communicate with other pods.
   ```bash
   ./tests/pod-quarantine.sh
   ```

### **4. Test Egress Policy**
Validates outbound communication from pods.
   ```bash
   ./tests/egress-policy.sh
   ```

### **5. Test External Access**
Ensures only authorized pods can connect to external services.
   ```bash
   ./tests/test-external-access.sh
   ```

### **6. Test Global Policy**
Tests deny-all or allow-all global policies.
   ```bash
   ./tests/test-global-policy.sh
   ```

---

## Steps to Run All Tests

1. Apply Policies:
   ```bash
   kubectl apply -f policies/app/
   kubectl apply -f policies/security/
   ```

2. Run All Tests:
   Execute all test scripts sequentially:
   ```bash
   ./tests/create-test-pods.sh
   ./tests/test-intra-namespace.sh
   ./tests/inter-namespace.sh
   ./tests/pod-quarantine.sh
   ./tests/egress-policy.sh
   ./tests/test-external-access.sh
   ./tests/test-global-policy.sh
   ```

3. Clean Up:
   Delete policies and namespaces after testing:
   ```bash
   kubectl delete -f policies/app/
   kubectl delete -f policies/security/
   kubectl delete namespace app-namespace test-namespace
   ```

---

## Verifying Results

Each test script provides logs indicating whether the test passed or failed. If a test fails:
- Inspect the logs.
- Verify applied policies:
  ```bash
  kubectl get networkpolicies -A
  ```
- Describe Pods:
  ```bash
  kubectl describe pod <pod-name> -n <namespace>
  ```
- Simulate with Calico:
  ```bash
  calicoctl policy check --from-pod=<source-pod> --to-pod=<destination-pod>
  ```

---

## Notes
- Each test script logs its actions and results for easier debugging.
- Tiers ensure proper enforcement of organization-wide policies (`security`) and application-specific policies (`app`).
```
