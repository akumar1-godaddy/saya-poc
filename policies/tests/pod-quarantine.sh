#!/bin/bash
# Test Pod Quarantine Policy
kubectl run test-client --image=busybox --restart=Never --namespace=my-namespace --labels="quarantine=true" -- sleep 3600

echo "Testing ingress traffic to quarantined pod..."
kubectl exec test-client -n my-namespace -- wget -q --timeout=5 --spider google.com
if [ $? -eq 0 ]; then
  echo "Ingress Allowed: Fail"
else
  echo "Ingress Denied: Pass"
fi

echo "Testing egress traffic from quarantined pod..."
kubectl exec test-client -n my-namespace -- wget -q --timeout=5 --spider google.com
if [ $? -eq 0 ]; then
  echo "Egress Allowed: Fail"
else
  echo "Egress Denied: Pass"
fi
