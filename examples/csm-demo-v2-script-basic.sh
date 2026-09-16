#!/bin/bash
# csm-demo-v2-script-basic.sh
#
# Envoy-based Cloud Service Mesh (managed) on GKE Autopilot using the
# Kubernetes Gateway API. Demonstrates:
#   - Managed CSM with automatic Envoy sidecar injection
#   - East-west (GAMMA) routing via HTTPRoute anchored to a Service
#   - STRICT mTLS enforced with a PeerAuthentication resource
#   - (Optional) a north-south edge Gateway with a self-signed cert
#
# Sources (Google Cloud Service Mesh docs):
#   - Set up an Envoy sidecar service mesh on GKE
#   - Configure transport security (PeerAuthentication STRICT)
#   - Prepare the Gateway API for Cloud Service Mesh

set -e

# ==========================================
# 1. Configuration
# ==========================================
export PROJECT_ID=$(gcloud config get-value project)
export PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format="value(projectNumber)")
export REGION="europe-north2"
export VPC_NAME="csm-vpc-v2-basic"
export SUBNET_NAME="csm-subnet-v2-basic"
export CLUSTER_NAME="csm-autopilot-cluster"
export NAMESPACE="csm-demo-v2-basic"
export EDGE_IP_NAME="csm-v2-edge-ip"

# Optional north-south edge Gateway (self-signed TLS). Default OFF.
# When enabled, the external ALB routes to the PERMISSIVE whereami-frontend
# (NOT directly to the STRICT backend). This is the key to edge-to-mesh under
# STRICT mTLS: the ALB speaks plaintext (health checks + traffic) to the
# frontend, and the frontend's sidecar re-originates mTLS to the STRICT
# backend. See Steps 8-9 for the frontend + its workload-scoped PERMISSIVE
# PeerAuthentication.
export DEPLOY_EDGE_GATEWAY="${DEPLOY_EDGE_GATEWAY:-false}"

# Optional frontend mTLS (client-certificate validation) at the edge ALB.
# Only takes effect when DEPLOY_EDGE_GATEWAY=true. Default OFF. When enabled the
# ALB REQUIRES a client cert on the HTTPS listener, validates it against a demo
# client-CA trust store (a ConfigMap), and forwards the parsed cert fields to
# the backend as X-Client-Cert-* headers (which the whereami-frontend echoes).
# See Step 10 (issuing the demo client CA/cert + wiring) and Step 16 (tests).
export DEPLOY_FRONTEND_MTLS="${DEPLOY_FRONTEND_MTLS:-false}"

echo "=========================================="
echo "🚀 CSM v2 (Envoy sidecar + Gateway API) Setup"
echo "Project:      $PROJECT_ID"
echo "Region:       $REGION"
echo "Namespace:    $NAMESPACE"
echo "Edge GW:      $DEPLOY_EDGE_GATEWAY"
echo "Frontend mTLS: $DEPLOY_FRONTEND_MTLS"
echo "=========================================="

# ==========================================
# 2. Enable APIs
# ==========================================
echo "[Step 1] Enabling APIs..."
gcloud services enable \
    cloudresourcemanager.googleapis.com \
    compute.googleapis.com \
    container.googleapis.com \
    gkehub.googleapis.com \
    mesh.googleapis.com \
    meshconfig.googleapis.com \
    trafficdirector.googleapis.com \
    networkservices.googleapis.com \
    networksecurity.googleapis.com

# ==========================================
# 3. Service Identities & IAM Setup
# ==========================================
echo "[Step 2] Creating Service Identities and applying IAM bindings..."
gcloud beta services identity create --service=meshconfig.googleapis.com --project="${PROJECT_ID}" >/dev/null 2>&1 || true
gcloud beta services identity create --service=trafficdirector.googleapis.com --project="${PROJECT_ID}" >/dev/null 2>&1 || true
gcloud beta services identity create --service=networkservices.googleapis.com --project="${PROJECT_ID}" >/dev/null 2>&1 || true
gcloud beta services identity create --service=networksecurity.googleapis.com --project="${PROJECT_ID}" >/dev/null 2>&1 || true

# GKE Service Agent bindings
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:service-${PROJECT_NUMBER}@container-engine-robot.iam.gserviceaccount.com" \
    --role="roles/compute.securityAdmin" --condition="None" >/dev/null
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:service-${PROJECT_NUMBER}@container-engine-robot.iam.gserviceaccount.com" \
    --role="roles/compute.networkAdmin" --condition="None" >/dev/null

# Cloud Service Mesh Service Agent bindings
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:service-${PROJECT_NUMBER}@gcp-sa-servicemesh.iam.gserviceaccount.com" \
    --role="roles/anthosservicemesh.serviceAgent" --condition="None" >/dev/null 2>&1 || true
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:service-${PROJECT_NUMBER}@gcp-sa-servicemesh.iam.gserviceaccount.com" \
    --role="roles/meshcontrolplane.serviceAgent" --condition="None" >/dev/null 2>&1 || true
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:service-${PROJECT_NUMBER}@gcp-sa-servicemesh.iam.gserviceaccount.com" \
    --role="roles/compute.securityAdmin" --condition="None" >/dev/null

# ==========================================
# 4. Networking
# ==========================================
echo "[Step 3] Creating VPC and Subnet..."
if ! gcloud compute networks describe "$VPC_NAME" >/dev/null 2>&1; then
    gcloud compute networks create "$VPC_NAME" --subnet-mode=custom
fi
if ! gcloud compute networks subnets describe "$SUBNET_NAME" --region="$REGION" >/dev/null 2>&1; then
    gcloud compute networks subnets create "$SUBNET_NAME" \
        --network="$VPC_NAME" --region="$REGION" \
        --range="10.20.0.0/20" --enable-private-ip-google-access
fi

if [ "$DEPLOY_EDGE_GATEWAY" = "true" ]; then
    echo "  Reserving global static IP for the edge Gateway..."
    if ! gcloud compute addresses describe "$EDGE_IP_NAME" --global >/dev/null 2>&1; then
        gcloud compute addresses create "$EDGE_IP_NAME" --global
    fi
fi

# ==========================================
# 5. GKE Autopilot Cluster
# ==========================================
echo "[Step 4] Provisioning GKE Autopilot cluster..."
if ! gcloud container clusters describe "$CLUSTER_NAME" --region="$REGION" >/dev/null 2>&1; then
    gcloud container clusters create-auto "$CLUSTER_NAME" \
        --region="$REGION" --network="$VPC_NAME" --subnetwork="$SUBNET_NAME"
fi

gcloud container clusters get-credentials "$CLUSTER_NAME" --region="$REGION"

gcloud container clusters update "$CLUSTER_NAME" --region="$REGION" --enable-mesh-certificates
gcloud container clusters update "$CLUSTER_NAME" --region="$REGION" --gateway-api=standard

# ==========================================
# 6. Fleet Registration & Managed Mesh
# ==========================================
echo "[Step 5] Registering to Fleet and enabling managed Cloud Service Mesh..."
MEMBERSHIP_NAME="${CLUSTER_NAME}-membership"
if ! gcloud container fleet memberships describe "$MEMBERSHIP_NAME" --location="$REGION" >/dev/null 2>&1; then
    gcloud container fleet memberships register "$MEMBERSHIP_NAME" \
        --gke-cluster="${REGION}/${CLUSTER_NAME}" --enable-workload-identity
fi

gcloud container fleet mesh enable

# Provision managed CSM using the Gateway API (GAMMA) config model.
#
# IMPORTANT: --config-api and --management are MUTUALLY EXCLUSIVE and cannot
# be set together. The config-api=gateway path provisions BOTH the managed
# control plane AND the managed Envoy data plane (automatic sidecar
# injection). Do NOT also pass "--management automatic": that selects the
# Istio config API and permanently locks the cluster out of the Gateway API.
gcloud alpha container fleet mesh update \
    --config-api=gateway \
    --memberships="$MEMBERSHIP_NAME" \
    --location="$REGION"

# trafficdirector.client for mesh workloads (Workload Identity principal)
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="group:${PROJECT_ID}.svc.id.goog:/allAuthenticatedUsers/" \
    --role="roles/trafficdirector.client" --condition="None" >/dev/null

# Wait for the managed control plane to be reconciled. This is the true
# readiness signal for sidecar injection.
#
# NOTE: We poll the IN-CLUSTER ControlPlaneRevision (asm-managed) for
# Reconciled=True rather than the fleet-level membership state. The fleet
# membershipStates API can lag for a long time at PROVISIONING even after the
# in-cluster control plane is fully reconciled and injecting, so relying on it
# can hang for the full timeout. The ControlPlaneRevision reflects real
# in-cluster readiness. Provisioning typically takes 10-20 minutes on a new
# cluster. (Also: waiting only for the webhook object to *exist* is not
# enough — it can appear before the control plane can actually inject.)
echo "⏳ Waiting for the managed control plane (asm-managed) to reconcile (up to ~30m)..."
for i in $(seq 1 90); do
    RECON=$(kubectl get controlplanerevision asm-managed -n istio-system \
        -o jsonpath='{.status.conditions[?(@.type=="Reconciled")].status}' 2>/dev/null)
    echo "  [$i] ControlPlaneRevision asm-managed Reconciled=${RECON:-<not-present-yet>}"
    if [ "$RECON" = "True" ]; then
        echo "  Managed control plane is reconciled."
        break
    fi
    sleep 20
done

# ==========================================
# 7. CRDs
# ==========================================
echo "[Step 6] Installing GRPCRoute CRD and verifying Gateway API CRDs..."
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.1.0/config/crd/standard/gateway.networking.k8s.io_grpcroutes.yaml
kubectl get crd | grep -E "gateway.networking.k8s.io" || true

# ==========================================
# 8. Namespace + wait for injection webhook
# ==========================================
echo "[Step 7] Creating namespace with sidecar injection label..."
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
# Use istio-injection=enabled: this is the canonical, channel-agnostic label
# that the managed CSM injection webhooks actually select on (istio-injection
# / istio.io/rev). The mesh.cloud.google.com/csm-injection=sidecar label shown
# in some docs only takes effect once the managed DATA PLANE is fully active
# and its translating webhook is installed, which can lag well behind control-
# plane readiness — so injection with it is unreliable on a fresh cluster.
kubectl label namespace "$NAMESPACE" istio-injection=enabled --overwrite

# Secondary confirmation: the injection webhook should already exist now that
# the control plane is reconciled (waited for in Step 5).
echo "⏳ Confirming the sidecar injection webhook is present..."
for i in $(seq 1 30); do
    if kubectl get mutatingwebhookconfiguration 2>/dev/null | grep -qiE "istiod-asm-managed|istio-revision-tag-default"; then
        echo "  Injection webhook detected."
        break
    fi
    sleep 10
done

# ==========================================
# 9. Mesh Workloads (Envoy sidecars auto-injected)
# ==========================================
echo "[Step 8] Deploying whereami backend + frontend + curl client..."
# Two mesh workloads:
#   - whereami          : the BACKEND (STRICT mTLS, mesh-internal only)
#   - whereami-frontend : the edge-facing FRONTEND. It is a mesh member (so its
#                         sidecar auto-originates mTLS to the STRICT backend),
#                         but a workload-scoped PERMISSIVE policy (Step 9) lets
#                         the external ALB reach it in plaintext. The whereami
#                         image's built-in BACKEND_ENABLED/BACKEND_SERVICE makes
#                         it call the backend and embed the reply as
#                         "backend_result", proving the frontend->backend mTLS hop.
cat <<EOF | kubectl apply -f -
# Dedicated ServiceAccounts give each workload a DISTINCT SPIFFE identity
# (spiffe://<pool>/ns/<ns>/sa/<ksa>) in its Mesh CA certificate, so the mTLS
# peer identity shown in X-Forwarded-Client-Cert is meaningful (e.g. the backend
# sees sa/whereami-frontend as the caller instead of a generic sa/default).
apiVersion: v1
kind: ServiceAccount
metadata:
  name: whereami-backend
  namespace: $NAMESPACE
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: whereami-frontend
  namespace: $NAMESPACE
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: curl-client
  namespace: $NAMESPACE
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: whereami
  namespace: $NAMESPACE
spec:
  replicas: 1
  selector:
    matchLabels:
      app: whereami
  template:
    metadata:
      labels:
        app: whereami
    spec:
      serviceAccountName: whereami-backend
      containers:
      - name: whereami
        image: us-docker.pkg.dev/google-samples/containers/gke/whereami:v1
        ports:
        - containerPort: 8080
        env:
        # Echo request headers in the JSON response so the mTLS peer's SPIFFE
        # identity (carried in X-Forwarded-Client-Cert by the inbound sidecar)
        # is visible in the output.
        - name: ECHO_HEADERS
          value: "True"
---
apiVersion: v1
kind: Service
metadata:
  name: whereami
  namespace: $NAMESPACE
spec:
  selector:
    app: whereami
  ports:
  - name: http
    port: 8080
    targetPort: 8080
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: whereami-frontend
  namespace: $NAMESPACE
spec:
  replicas: 1
  selector:
    matchLabels:
      app: whereami-frontend
  template:
    metadata:
      labels:
        app: whereami-frontend
    spec:
      serviceAccountName: whereami-frontend
      containers:
      - name: whereami
        image: us-docker.pkg.dev/google-samples/containers/gke/whereami:v1
        ports:
        - containerPort: 8080
        env:
        - name: BACKEND_ENABLED
          value: "True"
        - name: BACKEND_SERVICE
          value: "http://whereami.$NAMESPACE.svc.cluster.local:8080"
        # Echo headers so the caller SPIFFE identity (XFCC) shows in the output.
        - name: ECHO_HEADERS
          value: "True"
---
apiVersion: v1
kind: Service
metadata:
  name: whereami-frontend
  namespace: $NAMESPACE
spec:
  selector:
    app: whereami-frontend
  ports:
  - name: http
    port: 8080
    targetPort: 8080
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: curl-client
  namespace: $NAMESPACE
spec:
  replicas: 1
  selector:
    matchLabels:
      app: curl-client
  template:
    metadata:
      labels:
        app: curl-client
    spec:
      serviceAccountName: curl-client
      containers:
      - name: curl
        image: curlimages/curl
        command: ["/bin/sh", "-c", "sleep infinity"]
EOF

# GAMMA east-west routes: parentRef is the Service, not a Gateway. One route
# per mesh Service anchors it as a routable mesh destination.
cat <<EOF | kubectl apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: whereami-mesh-route
  namespace: $NAMESPACE
spec:
  parentRefs:
  - name: whereami
    kind: Service
    group: ""
    port: 8080
  rules:
  - backendRefs:
    - name: whereami
      port: 8080
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: whereami-frontend-mesh-route
  namespace: $NAMESPACE
spec:
  parentRefs:
  - name: whereami-frontend
    kind: Service
    group: ""
    port: 8080
  rules:
  - backendRefs:
    - name: whereami-frontend
      port: 8080
EOF

# ==========================================
# 10. STRICT mTLS (PeerAuthentication)
# ==========================================
echo "[Step 9] Enforcing STRICT mTLS in the namespace (with a PERMISSIVE frontend)..."
# Namespace-wide STRICT: every workload must speak mTLS...
cat <<EOF | kubectl apply -f -
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: strict-mtls
  namespace: $NAMESPACE
spec:
  mtls:
    mode: STRICT
---
# ...except the edge-facing frontend. This workload-scoped policy overrides the
# namespace default for app=whereami-frontend only, so the external ALB (which
# speaks plaintext for both health checks and traffic) can reach it. The
# frontend's own sidecar still auto-originates mTLS when it calls the STRICT
# backend, so the mesh-internal hop stays encrypted and authenticated.
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: frontend-permissive
  namespace: $NAMESPACE
spec:
  selector:
    matchLabels:
      app: whereami-frontend
  mtls:
    mode: PERMISSIVE
EOF

echo "⏳ Waiting for workloads to become Ready..."
kubectl rollout status deployment/whereami -n "$NAMESPACE" --timeout=600s || echo "Warning: whereami not ready in time."
kubectl rollout status deployment/whereami-frontend -n "$NAMESPACE" --timeout=600s || echo "Warning: whereami-frontend not ready in time."
kubectl rollout status deployment/curl-client -n "$NAMESPACE" --timeout=600s || echo "Warning: curl-client not ready in time."

# Ensure sidecars were injected; if not, restart to trigger injection.
SERVER_POD=$(kubectl get pod -l app=whereami -n "$NAMESPACE" -o jsonpath='{.items[0].metadata.name}')
if ! kubectl get pod "$SERVER_POD" -n "$NAMESPACE" -o jsonpath='{.spec.containers[*].name}' | grep -q "istio-proxy"; then
    echo "  No sidecar detected — restarting workloads to trigger injection..."
    kubectl rollout restart deployment/whereami deployment/whereami-frontend deployment/curl-client -n "$NAMESPACE"
    kubectl rollout status deployment/whereami -n "$NAMESPACE" --timeout=600s || true
    kubectl rollout status deployment/whereami-frontend -n "$NAMESPACE" --timeout=600s || true
    kubectl rollout status deployment/curl-client -n "$NAMESPACE" --timeout=600s || true
fi

# Hard assertion: BOTH workloads must have the istio-proxy sidecar. Without
# this, a namespace whose injection label matched no webhook would sail through
# with plaintext pods and give a FALSE PASS on the mTLS checks below.
echo "  Asserting Envoy sidecars are present on both workloads..."
assert_sidecar() {
    local app="$1" pod
    pod=$(kubectl get pod -l app="$app" -n "$NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if kubectl get pod "$pod" -n "$NAMESPACE" -o jsonpath='{.spec.containers[*].name}' 2>/dev/null | grep -q "istio-proxy"; then
        echo "    ✅ $app ($pod) has an istio-proxy sidecar."
        return 0
    fi
    echo "    ❌ $app ($pod) has NO istio-proxy sidecar — injection is not working."
    echo "       Check: namespace label (istio-injection=enabled) and that the"
    echo "       managed control plane (ControlPlaneRevision asm-managed) is reconciled."
    return 1
}
assert_sidecar whereami || exit 1
assert_sidecar whereami-frontend || exit 1
assert_sidecar curl-client || exit 1

# ==========================================
# 11. Optional: north-south edge Gateway (self-signed)
# ==========================================
if [ "$DEPLOY_EDGE_GATEWAY" = "true" ]; then
    echo "[Step 10] Deploying edge Gateway (self-signed TLS)..."
    TLSDIR=$(mktemp -d)
    openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
        -keyout "$TLSDIR/tls.key" -out "$TLSDIR/tls.crt" \
        -subj "/CN=csm-demo-v2.example.com" >/dev/null 2>&1
    kubectl create secret tls csm-v2-edge-cert \
        --cert="$TLSDIR/tls.crt" --key="$TLSDIR/tls.key" \
        -n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
    rm -rf "$TLSDIR"

    # ---- Optional frontend mTLS (client-cert validation at the ALB) ----------
    # These two variables are injected into the Gateway/HTTPRoute manifests
    # below. When frontend mTLS is off they stay empty (harmless blank lines).
    CLIENT_MTLS_DIR=""
    FRONTEND_TLS_BLOCK=""
    FILTERS_BLOCK=""
    if [ "$DEPLOY_FRONTEND_MTLS" = "true" ]; then
        echo "  Frontend mTLS enabled: issuing a demo client CA + client cert..."
        CLIENT_MTLS_DIR=$(mktemp -d)
        # 1) Self-signed client CA — the root of trust the ALB validates against.
        openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
            -keyout "$CLIENT_MTLS_DIR/client-ca.key" \
            -out "$CLIENT_MTLS_DIR/client-ca.crt" \
            -subj "/CN=csm-demo-v2 client CA" >/dev/null 2>&1
        # 2) Client leaf cert: clientAuth EKU (required by the LB) + a SPIFFE URI
        #    SAN so the LB can surface {client_cert_spiffe_id} to the backend.
        cat > "$CLIENT_MTLS_DIR/client.cnf" <<'CNF'
[req]
default_bits = 2048
distinguished_name = dn
req_extensions = ext
prompt = no
[dn]
CN = edge-client.csm-demo-v2.example.com
[ext]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = clientAuth
subjectAltName = @sans
[sans]
URI.1 = spiffe://csm-demo-v2.example.com/edge-client
CNF
        openssl req -new -newkey rsa:2048 -nodes \
            -keyout "$CLIENT_MTLS_DIR/client.key" \
            -out "$CLIENT_MTLS_DIR/client.csr" \
            -config "$CLIENT_MTLS_DIR/client.cnf" >/dev/null 2>&1
        openssl x509 -req -days 365 \
            -in "$CLIENT_MTLS_DIR/client.csr" \
            -CA "$CLIENT_MTLS_DIR/client-ca.crt" \
            -CAkey "$CLIENT_MTLS_DIR/client-ca.key" -CAcreateserial \
            -extfile "$CLIENT_MTLS_DIR/client.cnf" -extensions ext \
            -out "$CLIENT_MTLS_DIR/client.crt" >/dev/null 2>&1
        # 3) Trust store: a ConfigMap holding exactly one PEM root under ca.crt.
        kubectl create configmap csm-v2-client-ca \
            --from-file=ca.crt="$CLIENT_MTLS_DIR/client-ca.crt" \
            -n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

        # spec.tls.frontend block (Gateway API config method — recommended;
        # requires Gateway API 1.5+). Default validation mode is strict
        # (AllowValidOnly): requests with no/invalid client cert are rejected.
        # Indented for spec: (2 spaces); the whole block sits on one injected line.
        FRONTEND_TLS_BLOCK="  tls:
    frontend:
      default:
        validation:
          caCertificateRefs:
          - kind: ConfigMap
            group: \"\"
            name: csm-v2-client-ca"

        # HTTPRoute filter that forwards the parsed client-cert fields to the
        # backend as custom headers. GKE implements these in the URL map and
        # supports the {client_cert_*} substitution variables. Indented for a
        # rule entry (4 spaces).
        FILTERS_BLOCK="    filters:
    - type: RequestHeaderModifier
      requestHeaderModifier:
        add:
        - name: X-Client-Cert-Present
          value: \"{client_cert_present}\"
        - name: X-Client-Cert-Chain-Verified
          value: \"{client_cert_chain_verified}\"
        - name: X-Client-Cert-SPIFFE
          value: \"{client_cert_spiffe_id}\"
        - name: X-Client-Cert-URI-SANs
          value: \"{client_cert_uri_sans}\"
        - name: X-Client-Cert-Subject-Dn
          value: \"{client_cert_subject_dn}\""
    fi

    cat <<EOF | kubectl apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: csm-v2-edge
  namespace: $NAMESPACE
spec:
  gatewayClassName: gke-l7-global-external-managed
$FRONTEND_TLS_BLOCK
  addresses:
  - type: NamedAddress
    value: $EDGE_IP_NAME
  listeners:
  - name: https
    protocol: HTTPS
    port: 443
    tls:
      mode: Terminate
      certificateRefs:
      - name: csm-v2-edge-cert
    allowedRoutes:
      namespaces:
        from: Same
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: whereami-edge-route
  namespace: $NAMESPACE
spec:
  parentRefs:
  - name: csm-v2-edge
    kind: Gateway
  rules:
  - backendRefs:
    - name: whereami-frontend
      port: 8080
$FILTERS_BLOCK
EOF
    echo "  Edge routes to the PERMISSIVE frontend (not the STRICT backend), so"
    echo "  the ALB's plaintext health checks and traffic are accepted. The"
    echo "  frontend then reaches the STRICT backend over mesh mTLS."
    echo "  The GCLB backend can take a few minutes to report HEALTHY."
    if [ "$DEPLOY_FRONTEND_MTLS" = "true" ]; then
        echo "  Frontend mTLS is ON: clients must present a cert issued by the demo"
        echo "  client CA. Cert/key written to: $CLIENT_MTLS_DIR"
    fi
fi

# ==========================================
# 12. Validation
# ==========================================
echo "[Step 11] Validating HTTPRoute acceptance..."
# NOTE: `kubectl wait --for=condition=Accepted` does NOT work on Gateway API
# routes — their conditions live under .status.parents[].conditions[], not at
# the top level, so that wait always times out regardless of actual state.
# Poll the nested per-parent Accepted condition instead.
for i in $(seq 1 24); do
    ACC=$(kubectl get httproute whereami-mesh-route -n "$NAMESPACE" \
        -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null)
    if [ "$ACC" = "True" ]; then
        echo "  ✅ mesh HTTPRoute Accepted=True."
        break
    fi
    [ "$i" = "24" ] && echo "  Warning: mesh HTTPRoute not Accepted within timeout (last=${ACC:-<none>})."
    sleep 5
done

echo "[Step 12] Verifying Envoy sidecar on the server pod..."
SERVER_POD=$(kubectl get pod -l app=whereami -n "$NAMESPACE" -o jsonpath='{.items[0].metadata.name}')
echo "  Containers in $SERVER_POD:"
kubectl get pod "$SERVER_POD" -n "$NAMESPACE" -o jsonpath='{.spec.containers[*].name}'; echo

CLIENT_POD=$(kubectl get pod -l app=curl-client -n "$NAMESPACE" -o jsonpath='{.items[0].metadata.name}')

echo "[Step 13] In-mesh request (client sidecar -> server sidecar, auto-mTLS)..."
set +e
MESH_RESULT=$(kubectl exec "$CLIENT_POD" -n "$NAMESPACE" -c curl -- \
    curl -s -m 15 -o /dev/null -w "%{http_code}" http://whereami.$NAMESPACE.svc.cluster.local:8080 2>&1)
if [ "$MESH_RESULT" = "200" ]; then
    echo "✅ Success: in-mesh request returned HTTP 200 (mTLS between sidecars)."
else
    echo "❌ Failed: in-mesh request returned '$MESH_RESULT'."
fi

echo "[Step 13b] Frontend->backend hop + SPIFFE identity (client -> PERMISSIVE frontend -> mTLS -> STRICT backend)..."
# A 200 whose body contains "backend_result" proves the frontend reached the
# STRICT backend over mesh mTLS. With ECHO_HEADERS=True, the backend echoes the
# X-Forwarded-Client-Cert header its inbound sidecar injected on the mTLS
# connection — its URI= field is the CALLER's SPIFFE identity. This runs
# regardless of the edge Gateway.
FE_BODY=$(kubectl exec "$CLIENT_POD" -n "$NAMESPACE" -c curl -- \
    curl -s -m 15 http://whereami-frontend.$NAMESPACE.svc.cluster.local:8080 2>&1)
if echo "$FE_BODY" | grep -q "backend_result"; then
    echo "✅ Success: frontend returned backend_result (frontend->backend mTLS confirmed)."
    echo "$FE_BODY" | python3 -c "
import sys, json
d = json.load(sys.stdin)
def spiffe(h):
    x = (h or {}).get('X-Forwarded-Client-Cert', '')
    return x.split('URI=')[-1] if 'URI=' in x else '<none (not mTLS)>'
print('   frontend authenticated caller as:', spiffe(d.get('headers')))
print('   backend  authenticated caller as:', spiffe(d.get('backend_result', {}).get('headers')))
" 2>/dev/null || true
else
    echo "❌ Failed: frontend response had no backend_result. Body was:"
    echo "$FE_BODY" | head -c 300; echo
fi

echo "[Step 14] STRICT enforcement check (plaintext from a NON-injected pod should fail)..."
kubectl run mtls-probe --image=curlimages/curl --restart=Never -n default \
    --command -- /bin/sh -c "sleep 60" >/dev/null 2>&1 || true
kubectl wait --for=condition=Ready pod/mtls-probe -n default --timeout=120s >/dev/null 2>&1
PROBE_RESULT=$(kubectl exec mtls-probe -n default -- \
    curl -s -m 10 -o /dev/null -w "%{http_code}" \
    http://whereami.$NAMESPACE.svc.cluster.local:8080 2>&1)
if [ "$PROBE_RESULT" = "200" ]; then
    echo "⚠️  Unexpected: plaintext from non-injected pod succeeded (STRICT may not be active yet)."
else
    echo "✅ Success: plaintext from non-injected pod was rejected (result: '$PROBE_RESULT'). STRICT mTLS enforced."
fi
kubectl delete pod mtls-probe -n default --ignore-not-found >/dev/null 2>&1

if [ "$DEPLOY_EDGE_GATEWAY" = "true" ]; then
    echo "[Step 15] Edge Gateway status (may take several minutes to program)..."
    kubectl get gateway csm-v2-edge -n "$NAMESPACE" -o wide || true
    EDGE_IP=$(gcloud compute addresses describe "$EDGE_IP_NAME" --global --format="value(address)" 2>/dev/null)
    echo "  Reserved edge IP: ${EDGE_IP:-<pending>}"

    echo "[Step 16] Polling the public edge endpoint end-to-end (up to ~10m)..."
    # The GKE Gateway must program the ALB AND the GCLB health check must go
    # green against the PERMISSIVE frontend before this serves 200. A 200 whose
    # body contains "backend_result" proves the full chain:
    #   external client -> ALB (TLS terminate) -> PERMISSIVE frontend
    #   -> mesh mTLS -> STRICT backend.
    # When frontend mTLS is on, the client MUST present a cert from the demo
    # client CA, so we pass --cert/--key here.
    CURL_CERT_ARGS=""
    if [ "$DEPLOY_FRONTEND_MTLS" = "true" ] && [ -n "$CLIENT_MTLS_DIR" ]; then
        CURL_CERT_ARGS="--cert $CLIENT_MTLS_DIR/client.crt --key $CLIENT_MTLS_DIR/client.key"
        echo "  Frontend mTLS is ON — presenting the demo client certificate."
    fi
    if [ -n "$EDGE_IP" ]; then
        EDGE_OK=false
        for i in $(seq 1 40); do
            BODY=$(curl -k -s -m 15 $CURL_CERT_ARGS "https://${EDGE_IP}/" 2>/dev/null)
            if echo "$BODY" | grep -q "backend_result"; then
                echo "  ✅ Edge returned 200 with backend_result — edge-to-mesh mTLS works."
                # With frontend mTLS, the response also carries the X-Client-Cert-*
                # headers the ALB forwarded (echoed by the frontend), proving the
                # edge authenticated the client and passed the identity downstream.
                echo "$BODY" | python3 -m json.tool 2>/dev/null | head -35 || echo "$BODY" | head -c 500
                EDGE_OK=true
                break
            fi
            echo "  [$i] not ready yet (ALB/health-check converging)..."
            sleep 15
        done
        if [ "$EDGE_OK" = "false" ]; then
            echo "  Warning: edge did not serve backend_result within timeout."
            echo "  Retry: curl -k $CURL_CERT_ARGS https://${EDGE_IP}/"
        fi

        # Frontend mTLS negative test: a client presenting NO cert must be
        # rejected (strict AllowValidOnly validation fails the handshake, so
        # curl reports 000 — anything other than 200 is a pass).
        if [ "$EDGE_OK" = "true" ] && [ "$DEPLOY_FRONTEND_MTLS" = "true" ]; then
            echo "[Step 16b] Frontend mTLS negative test (no client cert should be rejected)..."
            NOCERT_CODE=$(curl -k -s -m 15 -o /dev/null -w "%{http_code}" "https://${EDGE_IP}/" 2>/dev/null)
            if [ "$NOCERT_CODE" = "200" ]; then
                echo "  ⚠️  Unexpected: request WITHOUT a client cert succeeded (frontend mTLS not enforced?)."
            else
                echo "  ✅ Success: request without a client cert was rejected (result: '$NOCERT_CODE'). Frontend mTLS enforced."
            fi
            echo "  Test manually with the demo client cert:"
            echo "    curl -k --cert $CLIENT_MTLS_DIR/client.crt --key $CLIENT_MTLS_DIR/client.key https://${EDGE_IP}/"
        fi
    fi
fi
set -e

echo "✅ Setup complete!"
echo "   Core mesh mTLS path is validated above:"
echo "     - STRICT backend rejects plaintext from outside the mesh"
echo "     - PERMISSIVE frontend calls the STRICT backend over mesh mTLS"
if [ "$DEPLOY_EDGE_GATEWAY" = "true" ]; then
    echo "   Edge path: external client -> ALB -> PERMISSIVE frontend -> mTLS -> STRICT backend."
    if [ "$DEPLOY_FRONTEND_MTLS" = "true" ]; then
        echo "   Frontend mTLS ON: the ALB validated your client cert and forwarded the"
        echo "   X-Client-Cert-* identity headers to the backend."
        echo "   Test with cert:    curl -k --cert $CLIENT_MTLS_DIR/client.crt --key $CLIENT_MTLS_DIR/client.key https://${EDGE_IP}/"
        echo "   Test without cert: curl -k https://${EDGE_IP}/   (expected to be rejected)"
    else
        echo "   Test any time with: curl -k https://${EDGE_IP}/"
    fi
else
    echo "   To also expose it publicly via the edge Gateway:"
    echo "     DEPLOY_EDGE_GATEWAY=true ./csm-demo-v2-script-basic.sh"
    echo "   ...and to require client certs at the edge (frontend mTLS):"
    echo "     DEPLOY_EDGE_GATEWAY=true DEPLOY_FRONTEND_MTLS=true ./csm-demo-v2-script-basic.sh"
fi
