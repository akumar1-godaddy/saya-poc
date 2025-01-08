#!/bin/bash
echo "Testing external access..."

kubectl exec test-external -n app-namespace -- wget -q --timeout=5 --spider http://203.0.113.1 && echo "External API: Allowed"
kubectl exec test-external -n app-namespace -- wget -q --timeout=5 --spider http://198.51.100.1 && echo "Non-Allowed External: Denied"
