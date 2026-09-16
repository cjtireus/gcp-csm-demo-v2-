# Cloud Service Mesh (Envoy Sidecar) on GKE Autopilot with Gateway API & STRICT mTLS

## About
This project provides a reference implementation for **Google Cloud Service Mesh (CSM)** using the **managed control plane** with **automatic Envoy sidecar injection** on GKE Autopilot. Traffic is configured with the **Kubernetes Gateway API for Mesh (GAMMA initiative)**, and workload-to-workload traffic is secured with **STRICT mTLS** enforced by a `PeerAuthentication` policy.

This is the v2 companion to the [proxyless gRPC demo](../gcp-csm-demo). Where v1 ran a completely sidecar-less mesh, v2 uses managed Envoy sidecars — the more conventional data plane — which unlocks reliable STRICT mTLS enforcement and a north-south edge Gateway path.

## The "AI-First" Development Story
This repository wasn't built by manual documentation digging alone. It is the result of an experiment using the **Google Developer Knowledge API** and its **MCP (Model Context Protocol)** server.

By connecting an agentic CLI (Gemini CLI or Claude Code) to Google’s live developer knowledge base, you bypass the "fragmentation trap" where documentation often mixes legacy Istio APIs with the modern Gateway API. Every non-obvious command in the scripts here — the managed-mesh enablement flow, the sidecar injection label, the `PeerAuthentication` shape, the edge Gateway static-IP syntax — was cross-checked against the DK API before being committed.

## The Workflow
The scripts in this repo were largely generated and verified by AI—you review the proposed `gcloud`/`kubectl` commands and approve them to execute locally. Expect a little try-and-error; follow along and "learn".

### How to Generate the Scripts via AI

# 1. Configure the Developer Knowledge API (MCP)
```
# 1. Enable the API
gcloud services enable developerknowledge.googleapis.com

# 2. Create an API Key
gcloud services api-keys create --display-name="DK API Key"

# 3a. Add the MCP server to Gemini CLI
gemini mcp add -t http \
  -H "X-Goog-Api-Key: YOUR_API_KEY" \
  google-developer-knowledge \
  https://developerknowledge.googleapis.com/mcp \
  --scope user

# 3b. ...or add it to Claude Code
claude mcp add --scope user --transport http \
  google-developer-knowledge \
  https://developerknowledge.googleapis.com/mcp \
  --header "X-Goog-Api-Key: YOUR_API_KEY"
```

More information: https://developers.google.com/knowledge/mcp#config-api

# 2. Run the Generation Prompt
Feed the provided prompt to your AI CLI. This triggers the "Reasoning" phase where the agent plans the infrastructure:
```
gemini "Using the Google Developer Knowledge MCP, follow the instructions in $(cat promt-basic-v2.txt)"
```

### What to expect
The agent operates in a **Research -> Strategy -> Execution** lifecycle:

1.  **Research & Planning:** It queries live Google Cloud documentation via the MCP server and identifies the exact sequence of `gcloud` and `kubectl` commands for GKE Autopilot, managed CSM, and the Gateway API.
2.  **Proposed Strategy:** Before acting, it presents a summary of its plan.
3.  **Interactive Execution:** For every command that modifies your environment, it explains the intent and asks for permission (Allow / Deny / Modify).
4.  **Self-Correction:** If a command fails (propagation delay, missing IAM permission), it analyzes the error and proposes a fix or retry.

## Working with an Agentic CLI
*   **Contextual Awareness:** Use `@` to reference files (e.g., `"Explain what @examples/csm-demo-v2-script-basic.sh does"`).
*   **Iteration over perfection:** Give broad instructions and refine ("Actually, change the region to us-central1").
*   **Troubleshooting:** Paste an error straight into the CLI; the agent will investigate your local environment and suggest corrections.
*   **Built-in Help:** Type `/help` inside the interactive CLI for available commands.

# Architecture & Core Technologies
* **Compute:** GKE Autopilot (fully managed).
* **Service Mesh:** Cloud Service Mesh (managed control plane, provisioned with `--config-api=gateway`). This single flag provisions both the managed control plane and the managed Envoy data plane. It is mutually exclusive with `--management automatic`, which selects the Istio config API and permanently locks the cluster out of the Gateway API.
* **Data Plane:** Managed **Envoy sidecars**, auto-injected via the `istio-injection=enabled` namespace label (the canonical label the managed CSM injection webhooks select on).
* **Traffic Management:** Kubernetes Gateway API — `HTTPRoute` anchored to the Service for east-west (GAMMA) routing, and an optional `gke-l7-global-external-managed` Gateway for north-south edge ingress.
* **Security:** STRICT mTLS via `PeerAuthentication` (`security.istio.io/v1beta1`), with short-lived SPIFFE certificates issued by the Mesh CA through GKE Workload Identity. A workload-scoped **PERMISSIVE** `PeerAuthentication` on the edge-facing frontend lets the external ALB in without weakening STRICT anywhere else.
* **Verifiable identity:** each workload has its own `ServiceAccount`, giving it a distinct SPIFFE identity (`spiffe://<pool>/ns/<ns>/sa/<ksa>`). With `ECHO_HEADERS=True`, the whereami response echoes the `X-Forwarded-Client-Cert` header the inbound sidecar injects, so you can see the authenticated mTLS peer identity right in the JSON — e.g. the STRICT backend reports its caller as `.../sa/whereami-frontend`.
* **Edge-to-mesh pattern:** A public `whereami-frontend` (PERMISSIVE) fronts the STRICT `whereami` backend. The ALB speaks plaintext to the frontend; the frontend's sidecar re-originates mTLS to the STRICT backend.
* **Frontend mTLS (optional):** the edge ALB can additionally authenticate the *external* client's certificate (`spec.tls.frontend` trust store) and forward the parsed identity to the pod as `X-Client-Cert-*` headers. Enabled with `DEPLOY_FRONTEND_MTLS=true`.

### Examples
Pre-generated reference scripts live in the [/examples](examples) folder:
* `csm-demo-v2-script-basic.sh` — full setup (core mesh mTLS path; edge Gateway is optional via `DEPLOY_EDGE_GATEWAY=true`).
* `clean-up-basic.sh` — removes everything.

# 💰 Cost Warning
Running this demo provisions several paid Google Cloud resources, including:
* **GKE Autopilot Cluster:** Management fees and resource consumption.
* **Cloud Service Mesh:** Managed control plane usage.
* **Networking Resources:** VPC, subnets, and (if the edge Gateway is enabled) a reserved global static IP and a global external Application Load Balancer.

**Important:** To avoid incurring unnecessary costs, run the cleanup script immediately after you are finished with the demo.

# Edge-to-mesh under STRICT mTLS
STRICT mTLS between sidecar-equipped workloads works out of the box. The classic friction point is **edge-to-mesh**: an external L7 Gateway (`gke-l7-global-external-managed`) sits *outside* the mesh and speaks plaintext, so pointing it straight at a STRICT backend gets its traffic and health checks rejected (the ALB reports `UNHEALTHY` backends and serves `503`).

This demo resolves that with the **PERMISSIVE-frontend pattern** rather than deferring it:

* A dedicated `whereami-frontend` runs *inside* the mesh (sidecar injected) but carries a **workload-scoped `PeerAuthentication` in `PERMISSIVE` mode**, so it accepts the ALB's plaintext health checks and traffic. The namespace-wide STRICT policy is untouched — only this one workload is exempted.
* The ALB terminates public TLS and routes to the frontend. The frontend's **own sidecar auto-originates mTLS** to the STRICT `whereami` backend, so the mesh-internal hop is still encrypted and authenticated.
* Proof is end-to-end: the public response embeds a nested `backend_result` from the STRICT backend, confirming the request traversed `client → ALB → PERMISSIVE frontend → mTLS → STRICT backend`.

Enable it with `DEPLOY_EDGE_GATEWAY=true`. The edge Gateway is **off by default** (it provisions a global static IP and an external ALB — see the cost warning), and OIDC/Cloud Armor/Cloud CDN remain out of scope for this demo.

> **Note:** An alternative production pattern places a dedicated in-mesh **ingress gateway** (a standalone Envoy that is a mesh member) between the ALB and the backends, with the ALB health-checking the gateway's `15021` status port. The PERMISSIVE-frontend approach here is simpler and keeps the demo to a single application image while still exercising real edge-to-mesh mTLS.

## Frontend mTLS (client-certificate auth at the edge)
The edge Gateway can also **authenticate the external client** with mutual TLS. Enable it with `DEPLOY_FRONTEND_MTLS=true` (requires `DEPLOY_EDGE_GATEWAY=true`; off by default):

```
DEPLOY_EDGE_GATEWAY=true DEPLOY_FRONTEND_MTLS=true ./examples/csm-demo-v2-script-basic.sh
```

What it does:
* **Issues a demo client CA + client certificate** (RSA, `clientAuth` EKU, with a SPIFFE URI SAN) and stores the CA root in a Kubernetes **ConfigMap** used as the Gateway's trust store.
* **Turns on frontend mTLS** via the Gateway API `spec.tls.frontend.default.validation.caCertificateRefs` field (requires Gateway API 1.5+). The default validation mode is strict — the ALB **rejects any request without a valid client cert**.
* **Forwards the cert identity to the pod** using an HTTPRoute `RequestHeaderModifier` filter with Google's `{client_cert_*}` substitution variables (e.g. `X-Client-Cert-SPIFFE: {client_cert_spiffe_id}`). Because the frontend runs with `ECHO_HEADERS=True`, the response shows those headers — so you can see the edge-authenticated client identity right in the JSON.

The `gke-l7-global-external-managed` class **always terminates TLS** (there is no raw TLS pass-through on an L7 ALB); frontend mTLS validates the client cert at the edge and passes the *parsed identity* to the backend as headers, rather than handing the pod an unbroken TLS session.

Test it with `curl` (the script does this automatically):
```
# succeeds — presents a cert issued by the demo client CA:
curl -k --cert client.crt --key client.key https://EDGE_IP/

# rejected — no client cert:
curl -k https://EDGE_IP/
```
The script prints the exact path to the generated `client.crt`/`client.key`. (Browser testing also works — import the client cert as a PKCS#12 into your OS/browser keystore — but `curl` is the clean path for this demo.)

# Cleanup
```
./examples/clean-up-basic.sh
```

# More Information
*   **Cloud Service Mesh (CSM):** [Official Overview](https://cloud.google.com/service-mesh/docs/overview)
*   **Set up an Envoy sidecar mesh on GKE:** [Guide](https://cloud.google.com/service-mesh/docs/gateway/set-up-envoy-mesh)
*   **Provision managed CSM (control plane):** [Guide](https://cloud.google.com/service-mesh/docs/onboarding/provision-control-plane)
*   **Configure transport security (mTLS):** [PeerAuthentication](https://cloud.google.com/service-mesh/docs/security/configuring-mtls)
*   **Gateway API for Mesh (GAMMA):** [Cloud Service Mesh Configuration](https://cloud.google.com/service-mesh/docs/gateway-api-mesh-overview)
*   **Securing a GKE Gateway with a Secret:** [Guide](https://cloud.google.com/kubernetes-engine/docs/how-to/secure-gateway)
*   **Google Developer Knowledge MCP:** [Getting Started](https://developers.google.com/knowledge/mcp)
