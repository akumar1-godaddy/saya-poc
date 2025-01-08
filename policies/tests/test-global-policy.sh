#!/bin/bash
echo "Testing global network policy..."

POD_B_IP=$(kubectl get pod test-pod-b -n app-namespace -o jsonpath='{.status.podIP}')
POD_C_IP=$(kubectl get pod test-pod-c -n app-namespace -o jsonpath='{.status.podIP}')

kubectl exec test-pod-a -n app-namespace -- ping -c 3 $POD_B_IP && echo "Pod A to Pod B: Allowed" || echo "Pod A to Pod B: Denied"
kubectl exec test-pod-a -n app-namespace -- ping -c 3 $POD_C_IP && echo "Pod A to Pod C: Allowed" || echo "Pod A to Pod C: Denied"

kubectl exec test-external -n app-namespace -- wget -q --timeout=5 --spider http://203.0.113.1 && echo "External API: Allowed" || echo "External API: Denied"
