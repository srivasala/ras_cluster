# Keylime Architecture Quick Reference

## Is Keylime Monolithic?

**NO** - Keylime is a **microservices architecture** designed for cloud-native deployment.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                    Keylime Architecture                      │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  ┌──────────────┐      ┌──────────────┐      ┌──────────┐  │
│  │   Verifier   │      │  Registrar   │      │  Agent   │  │
│  │   Service    │      │   Service    │      │ (Rust)   │  │
│  │              │      │              │      │          │  │
│  │ Port: 8881   │      │ Port: 8891   │      │ On Node  │  │
│  │ Stateless    │      │ Stateless    │      │          │  │
│  └──────┬───────┘      └──────┬───────┘      └────┬─────┘  │
│         │                     │                    │        │
│         └─────────────────────┼────────────────────┘        │
│                               │                             │
│                      ┌────────┴────────┐                    │
│                      │   PostgreSQL    │                    │
│                      │    Database     │                    │
│                      └─────────────────┘                    │
└─────────────────────────────────────────────────────────────┘
```

## Key Characteristics

| Feature | Status | Details |
|---------|--------|---------|
| **Architecture** | ✅ Microservices | 3 independent services |
| **Stateless** | ✅ Yes | Database-backed state |
| **Containerized** | ✅ Yes | Official Docker images |
| **Horizontal Scaling** | ✅ Yes | Multiple replicas supported |
| **Load Balancing** | ✅ Yes | Standard HTTP/HTTPS LB |
| **High Availability** | ✅ Yes | Multi-instance deployment |
| **Cloud Native** | ✅ Yes | Kubernetes ready |

## Containerization

### Docker Images

```bash
# Official images
docker pull keylime/keylime_verifier:latest
docker pull keylime/keylime_registrar:latest
```

### Dockerfile Locations

- `docker/release/verifier/Dockerfile.in`
- `docker/release/registrar/Dockerfile.in`
- `docker/release/tenant/Dockerfile.in`

## Horizontal Scaling

### Verifier Scaling

```yaml
# Kubernetes example
apiVersion: apps/v1
kind: Deployment
metadata:
  name: keylime-verifier
spec:
  replicas: 3  # Scale to 3 instances
  template:
    spec:
      containers:
      - name: verifier
        image: keylime/keylime_verifier:latest
        env:
        - name: DATABASE_URL
          value: "postgresql://user:pass@db:5432/verifier"
```

**Capacity per instance:**
- ~1,000 agents (10-second attestation)
- ~10,000 agents (60-second attestation)

### Registrar Scaling

```yaml
# Kubernetes example
apiVersion: apps/v1
kind: Deployment
metadata:
  name: keylime-registrar
spec:
  replicas: 2  # Scale to 2 instances
  template:
    spec:
      containers:
      - name: registrar
        image: keylime/keylime_registrar:latest
```

## Database Support

| Database | Use Case | Multi-Instance |
|----------|----------|----------------|
| SQLite | Development | ❌ No |
| PostgreSQL | Production | ✅ Yes (recommended) |
| MySQL/MariaDB | Production | ✅ Yes |

### Shared Database Architecture

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│ Verifier-1  │────▶│             │◀────│ Verifier-2  │
└─────────────┘     │ PostgreSQL  │     └─────────────┘
                    │  (Shared)   │
┌─────────────┐     │             │     ┌─────────────┐
│Registrar-1  │────▶│             │◀────│Registrar-2  │
└─────────────┘     └─────────────┘     └─────────────┘
```

## Deployment Patterns

### Pattern 1: Development

```bash
# Single instance with SQLite
docker-compose up
```

**Components:**
- 1 Verifier
- 1 Registrar
- SQLite database

### Pattern 2: Production

```yaml
# Kubernetes with HA
Verifier: 2-3 replicas
Registrar: 2 replicas
Database: PostgreSQL with replication
Load Balancer: Yes
```

### Pattern 3: Enterprise

```yaml
# Large-scale deployment
Verifier: 5-10+ replicas
Registrar: 3-5 replicas
Database: PostgreSQL cluster (Patroni)
Auto-scaling: HPA enabled
Multi-region: Yes
```

## Scaling Formula

```
Required Verifier Instances = Total Agents / Agents per Instance

Example:
  50,000 agents ÷ 5,000 agents/instance = 10 instances
```

## Load Balancing

### Requirements

- ✅ Layer 7 (HTTP/HTTPS) load balancer
- ✅ Health check support
- ❌ Session affinity NOT required (stateless)

### Kubernetes Service

```yaml
apiVersion: v1
kind: Service
metadata:
  name: keylime-verifier-lb
spec:
  type: LoadBalancer
  selector:
    app: keylime-verifier
  ports:
  - port: 8881
    targetPort: 8881
```

## Auto-Scaling

### Horizontal Pod Autoscaler

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: keylime-verifier-hpa
spec:
  scaleTargetRef:
    kind: Deployment
    name: keylime-verifier
  minReplicas: 2
  maxReplicas: 10
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 70
```

## Code References

### Service Implementations

- **Verifier**: `keylime/web/verifier_server.py`
- **Registrar**: `keylime/web/registrar_server.py`
- **Base Server**: `keylime/web/base/server.py`

### Database Layer

- **Connection**: `keylime/db/keylime_db.py`
- **Verifier DB**: `keylime/db/verifier_db.py`
- **Registrar DB**: `keylime/db/registrar_db.py`

### State Management

- **Attestation**: `keylime/models/verifier/attestation.py`
- **Agent Registration**: `keylime/models/registrar/registrar_agent.py`

## Stateless Design Evidence

```python
# From keylime/models/verifier/attestation.py
class Attestation(PersistableModel):
    """All state stored in database, not in memory"""
    agent_id: str
    attestation_count: int
    last_received_quote: bytes
    # No in-memory session state
```

```python
# From keylime/web/verifier_server.py
class VerifierServer(Server):
    """Stateless server - any instance handles any request"""
    # Database-backed persistence
    # No instance-specific state
```

## High Availability

### Service Level

- Multiple replicas (no single point of failure)
- Health checks detect failures
- Automatic removal from load balancer pool

### Database Level

- PostgreSQL replication (primary-replica)
- Automatic failover (Patroni)
- Point-in-time recovery

## Monitoring

### Health Check Endpoints

```bash
# Check service health
curl https://verifier:8881/version
curl https://registrar:8891/version
```

### Kubernetes Probes

```yaml
livenessProbe:
  httpGet:
    path: /version
    port: 8881
  periodSeconds: 10

readinessProbe:
  httpGet:
    path: /version
    port: 8881
  periodSeconds: 5
```

## Performance Tuning

### Database Connection Pooling

```ini
# verifier.conf
[cloud_verifier]
database_pool_sz_ovfl = 20,10  # pool_size, max_overflow
```

### Worker Threads

```ini
# verifier.conf
[cloud_verifier]
num_workers = 4  # per instance
```

## Security

### Multi-Instance Security

- ✅ TLS/mTLS for all communication
- ✅ Database encryption (SSL/TLS)
- ✅ Certificate management per instance
- ✅ Network segmentation support

## Summary

**Keylime is NOT monolithic** - it's a modern microservices architecture:

✅ **3 independent services** (Verifier, Registrar, Agent)
✅ **Stateless design** (database-backed)
✅ **Horizontally scalable** (multiple replicas)
✅ **Container-ready** (Docker images)
✅ **Cloud-native** (Kubernetes support)
✅ **Production-ready** (HA, load balancing)

## Documentation

For detailed architecture analysis, see:
- `docs/architecture_deployment.rst` (comprehensive guide)
- Build docs: `cd docs && ./build_docs.sh`
- View: `docs/_build/html/architecture_deployment.html`

## Quick Start

### Development (Single Instance)

```bash
# Using Docker Compose
docker-compose up
```

### Production (Multi-Instance)

```bash
# Using Kubernetes
kubectl apply -f keylime-deployment.yaml
kubectl scale deployment keylime-verifier --replicas=3
kubectl scale deployment keylime-registrar --replicas=2
```

### Check Scaling

```bash
# Kubernetes
kubectl get pods -l app=keylime-verifier
kubectl get hpa keylime-verifier-hpa

# Docker Swarm
docker service scale keylime_verifier=3
```
