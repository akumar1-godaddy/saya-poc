#!/bin/bash
# Test Egress Policy
kubectl run test-client --image=busybox --restart=Never --namespace=my-namespace -- sleep 3600

echo "Testing external access to allowed domain..."
kubectl exec test-client -n my-namespace -- wget -q --timeout=5 --spider https://api.example.com
if [ $? -eq 0 ]; then
  echo "Access Allowed: Pass"
else
  echo "Access Denied: Fail"
fi

echo "Testing external access to blocked domain..."
kubectl exec test-client -n my-namespace -- wget -q --timeout=5 --spider https://google.com
if [ $? -eq 0 ]; then
  echo "Access Allowed: Fail"
else
  echo "Access Denied: Pass"
fi
