#!/bin/bash
# Test Inter-Namespace Communication
kubectl run test-client-a --image=busybox --restart=Never --namespace=namespace-a -- sleep 3600
kubectl run test-server-b --image=busybox --restart=Never --namespace=namespace-b -- sleep 3600

echo "Testing inter-namespace access..."
kubectl exec test-client-a -n namespace-a -- wget -q --timeout=5 --spider test-server-b.namespace-b.svc.cluster.local
if [ $? -eq 0 ]; then
  echo "Access Allowed: Pass"
else
  echo "Access Denied: Fail"
fi
