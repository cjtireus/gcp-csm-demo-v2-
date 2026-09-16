#!/bin/bash
# clean-up-basic.sh
#
# Removes everything created by csm-demo-v2-script-basic.sh.
# Safe to run repeatedly; missing resources are ignored.

set +e

export PROJECT_ID=$(gcloud config get-value project)
export PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format="value(projectNumber)")
export REGION="europe-north2"
export VPC_NAME="csm-vpc-v2-basic"
export SUBNET_NAME="csm-subnet-v2-basic"
export CLUSTER_NAME="csm-autopilot-cluster"
export NAMESPACE="csm-demo-v2-basic"
export EDGE_IP_NAME="csm-v2-edge-ip"
export MEMBERSHIP_NAME="${CLUSTER_NAME}-membership"

echo "=========================================="
echo "🧹 Cleaning up CSM v2 demo"
echo "Project: $PROJECT_ID / Region: $REGION"
echo "=========================================="

# 1. Kubernetes resources (best-effort; needs cluster credentials)
echo "[1] Deleting Kubernetes resources..."
gcloud container clusters get-credentials "$CLUSTER_NAME" --region="$REGION" >/dev/null 2>&1
kubectl delete pod mtls-probe -n default --ignore-not-found
kubectl delete namespace "$NAMESPACE" --ignore-not-found --wait=false

# 2. Delete the GKE cluster (also releases gateway/NEG/LB resources it created)
echo "[2] Deleting GKE cluster (this can take several minutes)..."
gcloud container clusters delete "$CLUSTER_NAME" --region="$REGION" --quiet

# 3. Unregister fleet membership and disable mesh
echo "[3] Unregistering Fleet membership and disabling mesh..."
gcloud container fleet memberships unregister "$MEMBERSHIP_NAME" \
    --gke-cluster="${REGION}/${CLUSTER_NAME}" --quiet
gcloud container fleet mesh disable --quiet

# 4. Release the reserved edge static IP
echo "[4] Releasing reserved edge IP..."
gcloud compute addresses delete "$EDGE_IP_NAME" --global --quiet

# 5. Networking
echo "[5] Deleting subnet and VPC..."
gcloud compute networks subnets delete "$SUBNET_NAME" --region="$REGION" --quiet
gcloud compute networks delete "$VPC_NAME" --quiet

# 6. Remove IAM bindings added by the setup script
echo "[6] Removing IAM bindings..."
gcloud projects remove-iam-policy-binding "$PROJECT_ID" \
    --member="group:${PROJECT_ID}.svc.id.goog:/allAuthenticatedUsers/" \
    --role="roles/trafficdirector.client" --condition="None" >/dev/null 2>&1

echo "✅ Cleanup complete."
echo "   Note: enabled APIs and service identities are left in place (harmless)."
