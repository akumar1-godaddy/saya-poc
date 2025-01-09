
# **Network Policies Implementation Plan**

## **Objective**
Implement a **layered network security model** in Kubernetes using Calico's tiered policies, ensuring:
1. A **default deny (zero trust)** baseline for all traffic.
2. Controlled exceptions for application-specific communication.
3. A structured, scalable approach for managing network policies.

---

## **Key Learnings**

1. **Tiered Approach**:
    - **Security Tier**: Defines cluster-wide, organization-level rules.
        - Example: Default deny-all (`GlobalNetworkPolicy`) to enforce zero trust.
    - **Application Tier**: Defines namespace-specific or application-level rules.
        - Example: Allow communication between pods in trusted namespaces.

2. **Policy Precedence**:
    - Policies are evaluated in **tier order**:
        1. **Security Tier**: Evaluated first for global rules.
        2. **Application Tier**: Evaluated next for specific overrides.
    - Within each tier, policies are evaluated based on the `order` field (lower `order` takes precedence).

3. **Default Deny with Selective Allow**:
    - Use a **deny-all policy** as the foundation.
    - Add explicit allow rules for approved communication to ensure compliance with the zero-trust model.

4. **Testing and Debugging**:
    - Validate policies by deploying test pods and simulating traffic flows.
    - Use tools like `calicoctl` to check policy evaluation and connectivity issues.

---

## **Implementation Plan**

### **1. Define Policy Tiers**
- **Security Tier**:
    - Create `GlobalNetworkPolicies` with `deny-all` as the baseline.
    - Add explicit global rules (e.g., allow external APIs).
    - Store these in a dedicated `security/` directory.

- **Application Tier**:
    - Create namespace-specific `NetworkPolicies` for application needs (e.g., intra-namespace communication).
    - Store these in an `app/` directory.

### **2. Create Policies**

#### Security Tier Policies
- **Default Deny All**:
  ```yaml
  apiVersion: crd.projectcalico.org/v1
  kind: GlobalNetworkPolicy
  metadata:
    name: default-deny-global
  spec:
    tier: security
    order: 100
    selector: all()
    types:
      - Ingress
      - Egress
    ingress:
      - action: Deny
    egress:
      - action: Deny
  ```

- **Allow External API Access**:
  ```yaml
  apiVersion: crd.projectcalico.org/v1
  kind: GlobalNetworkPolicy
  metadata:
    name: allow-external-api
  spec:
    tier: security
    order: 200
    selector: all()
    types:
      - Egress
    egress:
      - action: Allow
        destination:
          nets:
            - 203.0.113.0/24
  ```

#### Application Tier Policies
- **Allow Intra-Namespace Communication**:
  ```yaml
  apiVersion: crd.projectcalico.org/v1
  kind: NetworkPolicy
  metadata:
    name: allow-intra-namespace
    namespace: app-namespace
  spec:
    tier: application
    order: 200
    selector: all()
    types:
      - Ingress
      - Egress
    ingress:
      - action: Allow
        source:
          selector: app == 'frontend'
    egress:
      - action: Allow
        destination:
          selector: app == 'frontend'
  ```

---

### **3. Validate Policies**

1. **Test Pods**:
   Deploy test pods in relevant namespaces:
   ```bash
   kubectl run test-pod --image=busybox --namespace=app-namespace --labels="app=frontend" -- sleep 3600
   kubectl run test-external --image=busybox --namespace=app-namespace --labels="app=external" -- sleep 3600
   ```

2. **Run Tests**:
    - Verify intra-namespace communication:
      ```bash
      kubectl exec test-pod -n app-namespace -- ping -c 3 <other-pod-ip>
      ```
    - Test external access:
      ```bash
      kubectl exec test-pod -n app-namespace -- wget -q --timeout=5 --spider http://203.0.113.5
      ```

3. **Debug**:
    - Check applied policies:
      ```bash
      kubectl get networkpolicies -A
      calicoctl policy check --from-pod=test-pod --to-pod=other-pod
      ```

---


- **Guide for Adding Applications**:
    - Every new namespace must inherit `security` tier policies.
    - Developers can add their namespace-specific policies in the `app` tier.

- **Testing Requirements**:
  Include test scripts for all new policies to validate compliance.

---

### **4. Monitor and Maintain**

1. **Audit Policy Changes**:
    - Use Git for version control and mandatory reviews.
    - Regularly audit policies to avoid conflicts or redundant rules.

2. **Monitor Traffic**:
    - Enable Calico logging and metrics to monitor traffic flows and blocked requests.

3. **Iterate**:
    - Continuously improve based on new application requirements and security needs.

---
