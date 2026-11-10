# Breaks log: eks-llm-platform (homelab)

Every real failure on this platform: symptom → diagnosis → root cause → fix → what I'd do in production → interview answer → post draft.
All numbers are copied from real command output in my homelab (AWS, ap-southeast-2, 2× m7i-flex.large). Nothing estimated.

| ID | Date | Title | Status |
|---|---|---|---|
| B-01 | Sun 8 Nov 2026 | EBS CSI sidecars restarted 8× at bootstrap (DNS race with kube-proxy/CoreDNS) | fixed · TODO write up |
| B-02 | Tue 10 Nov 2026 | Ingress got no ADDRESS: `invalid CIDR address` in `inbound-cidrs` (placeholder applied literally) | fixed · TODO write up |
| **B-03** | **Tue 10 Nov 2026** | **Ollama Pending: "Insufficient cpu" on nodes at 1–3% CPU** | **fixed · written** |

---

## B-03 · Ollama Pending: "Insufficient cpu" while the nodes were idle

**One line:** a pod asking for 1.5 CPU couldn't be scheduled on two nodes using 1–3% CPU, because the scheduler counts *requests*, not *usage*. The best node was **10 millicores** short.

### Context
- Cluster: EKS, 2 managed nodes, m7i-flex.large (2 vCPU each), **allocatable 1930m CPU per node** (70m held back for kubelet/system).
- Namespace `llm`: Ollama (qwen2.5:1.5b, gp3 PVC, `updateStrategy: Recreate`) + Open WebUI.
- What I was doing: a **CPU-limit sweep** for tokens/sec at 500m, 1 and 1500m, with request = limit each time. The 500m and 1 runs scheduled fine.
- The 1500m run: `helm upgrade … --set resources.requests.cpu=1500m --set resources.limits.cpu=1500m`.

### Symptom
```
$ kubectl -n llm rollout status deploy/ollama --timeout=300s
Waiting for deployment "ollama" rollout to finish: 0 of 1 updated replicas are available...

$ kubectl get po -n llm
ollama-7bd5985568-zs9hc            0/1     Pending   0          4m
open-webui-0                       1/1     Running   0          118m

Events:
  Warning  FailedScheduling  default-scheduler  0/2 nodes are available: 2 Insufficient cpu.
  preemption: 0/2 nodes are available: 2 No preemption victims found for incoming pod.
```

### Why it was confusing
```
$ kubectl top nodes
ip-10-0-22-99…   38m   1%
ip-10-0-41-70…   59m   3%
```
Both nodes were basically idle, but the scheduler said there was no CPU.

### Diagnosis path (commands in order)
1. `kubectl -n llm describe pod <ollama>` → Events → `FailedScheduling … Insufficient cpu`
2. `kubectl get nodes -o custom-columns='NODE:.metadata.name,ALLOCATABLE_CPU:.status.allocatable.cpu'` → 1930m each
3. `kubectl describe nodes | grep -A8 "Allocated resources"` → **Requests** 440m and 790m
4. `kubectl get pods -A -o custom-columns='NS:…,POD:…,NODE:.spec.nodeName,CPU_REQ:.spec.containers[*].resources.requests.cpu'` → who reserved what

### Root cause
| | Node A `ip-10-0-22-99` (private subnet 2a) | Node B `ip-10-0-41-70` (private subnet 2b) |
|---|---|---|
| Allocatable | 1930m | 1930m |
| Already requested | 440m | 790m |
| **Free to request** | **1490m** | 1140m |
| Ollama asked for | 1500m | 1500m |
| Result | ❌ 10m short | ❌ |

- `kubectl top` shows **usage** (from metrics-server). The scheduler ignores usage and sums **requests** (reservations) against **allocatable**. A node can be 1% busy and fully booked.
- Node A's 440m = aws-node 50m + kube-proxy 100m + ebs-csi-node 30m + coredns 100m + **metrics-server 100m** + ebs-csi-controller 60m.
- Node B's 790m = the same 440m of system pods + **open-webui 250m** + **open-webui-redis 100m** (that 100m is the LimitRange **default request**: the redis pod set none).

### Contributing factors
- **metrics-server, added earlier the same day, requests 100m on each node.** Without it, node A would have had 1590m free and the 1.5 CPU request would have fit.
- **Recreate strategy:** the old Ollama pod was deleted *before* the new one was scheduled, so Ollama was **down for the whole time it was Pending**. Recreate's trade-off was "a few seconds of downtime"; here it became minutes.
- **"No preemption victims found":** node A only runs system pods (higher priority, can't be preempted); on node B the only evictable pods (open-webui 250m + redis 100m = 350m) would still leave 1490m. So even a PriorityClass wouldn't have saved it.
- Pods with **no requests** (aws-load-balancer-controller, eks-pod-identity-agent) are BestEffort: free to schedule, but first to be evicted under memory pressure.
- TODO (verify): Ollama's PV is pinned to one AZ. The scheduler reports the CPU filter first, so a volume-zone conflict could be hidden behind it. Check: `kubectl get pv -o custom-columns='NAME:.metadata.name,CLAIM:.spec.claimRef.name,ZONE:.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0]'`.

### Fix applied
`--set resources.requests.cpu=1 --set resources.limits.cpu=1500m` (the values file's defaults) → scheduled, Running.
**Is the sweep still fair?** Yes. Throttling comes only from the **limit** (`cpu.max` = `150000 100000`). The request only decides *where* the pod lands and its CPU *share under contention* (`cpu.weight`); the nodes were idle. Footnote in the results: *"1500m run used request 1 / limit 1.5."*

### If I had to keep request = 1500m (options)
| Option | Works here? | Trade-off |
|---|---|---|
| Free ≥10m on the right node (metrics-server 1 replica or lower request, via EKS add-on `configuration_values`) | Only if the PV is in that node's AZ | Margins of 10m are fragile; one new DaemonSet breaks it again |
| Bigger nodes (4 vCPU) | ✅ | Cost (not free-tier); node group replacement |
| A 3rd node | Only if it lands in the PV's AZ | One managed node group spreads across AZs; can't choose |
| PriorityClass + preemption | ❌ (see "No preemption victims") | Evicts other apps |
| Cluster Autoscaler / **Karpenter** | ✅ | Prod answer: adds a node that fits the pending pod, AZ-aware for volumes |
| Dedicated node group for LLM (taint + toleration), sized for it | ✅ | Prod pattern (and where GPU nodes go later) |

### Production takeaways
- Size requests from real usage (metrics-server / Prometheus), not guesses. Request = what you need to be scheduled; limit = the ceiling.
- Budget for system pods: every add-on's request comes out of allocatable on every node.
- Give controllers requests so they're not BestEffort.
- Use an autoscaler (Karpenter) so Pending pods get a node instead of an outage.
- With RWO volumes + Recreate, a failed reschedule = downtime → alert on Pending pods.

### Interview answer (45 s)
> "In my homelab, an Ollama pod asking for 1.5 CPU stayed Pending with 'Insufficient cpu', while kubectl top showed both nodes at 1 to 3 percent. The scheduler doesn't look at usage, it sums requests against allocatable. After the system pods' requests, my best node had 1490 millicores free, ten short, and the gap was metrics-server's 100m that I'd added that morning. I fixed it by requesting 1 CPU and keeping the limit at 1.5, since throttling comes from the limit. In production I'd right-size requests from real usage and let Karpenter add capacity."

### Post draft (LinkedIn · refine later)
**Hook options**
1. "My Kubernetes nodes were 98% idle. The scheduler said there was no CPU left. Both were right."
2. "10 millicores. That's how short my cluster was of running my LLM."

**Body**
> I'm building a self-hosted LLM platform on AWS EKS in my homelab (Terraform, my own VPC + EKS modules, Ollama + Open WebUI).
>
> While benchmarking CPU limits, I asked for 1.5 CPU for the model server. It stayed Pending: "0/2 nodes available: Insufficient cpu".
>
> But `kubectl top` showed the nodes at 1–3% CPU.
>
> The catch: the scheduler doesn't care what pods *use*. It adds up what they *request*.
> → Each node: 1930m allocatable
> → System pods had already requested 440m and 790m
> → Best node had 1490m free. I asked for 1500m.
>
> The 10m gap? metrics-server, which I'd installed that same morning, requests 100m on every node.
>
> What I took away:
> 1. Requests are reservations, not usage. An idle node can be fully booked.
> 2. Every add-on you install takes a slice of every node.
> 3. With a Recreate rollout, "Pending" means "down".
>
> Fix: request 1 CPU, keep the limit at 1.5 (throttling comes from the limit).
> In production: size requests from real metrics and let Karpenter add nodes.

**Hashtags:** #Kubernetes #EKS #AWS #DevOps #SRE #Homelab #LLM

**Visuals to attach** (blur account ID, ALB DNS, public IPs)
- [ ] `kubectl get po -n llm` showing Pending
- [ ] the FailedScheduling event
- [ ] `kubectl top nodes` (1–3%)
- [ ] `Allocated resources` for both nodes
- [ ] simple diagram: allocatable bar = system requests + free (1490m) vs Ollama 1500m

**Label:** homelab / personal project, not production.
