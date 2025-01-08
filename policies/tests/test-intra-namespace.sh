#!/bin/bash
echo "Testing intra-namespace connectivity..."

POD_B_IP=$(kubectl get pod test-pod-b -n app-namespace -o jsonpath='{.status.podIP}')
POD_C_IP=$(kubectl get pod test-pod-c -n app-namespace -o jsonpath='{.status.podIP}')

kubectl exec test-pod-a -n app-namespace -- ping -c 3 $POD_B_IP && echo "Pod A to Pod B: Allowed"
kubectl exec test-pod-a -n app-namespace -- ping -c 3 $POD_C_IP && echo "Pod A to Pod C: Allowed" || echo "Pod A to Pod C: Denied"
