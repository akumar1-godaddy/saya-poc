#!/bin/bash
echo "Creating test pods..."
kubectl create namespace app-namespace || true

kubectl run test-pod-a --image=busybox --restart=Never --namespace=app-namespace --labels="app=frontend" -- sleep 3600
kubectl run test-pod-b --image=busybox --restart=Never --namespace=app-namespace --labels="app=frontend" -- sleep 3600
kubectl run test-pod-c --image=busybox --restart=Never --namespace=app-namespace --labels="app=backend" -- sleep 3600
kubectl run test-external --image=busybox --restart=Never --namespace=app-namespace -- sleep 3600

kubectl get pods -n app-namespace
