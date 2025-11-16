# Scaling SparkConnect on Amazon EMR on EC2

> Production-ready multi-server SparkConnect architecture for high-concurrency workloads on Amazon EMR

[![Spark](https://img.shields.io/badge/Spark-3.4+-orange.svg)](https://spark.apache.org/)
[![EMR](https://img.shields.io/badge/AWS-EMR-orange.svg)](https://aws.amazon.com/emr/)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)

## 📖 Table of Contents

- [Problem Statement](#problem-statement)
- [Solution Overview](#solution-overview)
- [Architecture](#architecture)
- [Quick Start](#quick-start)
- [Implementation Guide](#implementation-guide)
- [Configuration Reference](#configuration-reference)
- [Troubleshooting](#troubleshooting)
- [FAQ](#faq)

---

## Problem Statement

Many customers today submit Spark applications to Amazon EMR from edge nodes that have YARN and Spark client JARs installed. Interactive and batch jobs are launched via `spark-submit`, and drivers are created wherever the submit command runs (typically edge nodes or EMR primary nodes).

With the introduction of Spark Connect, customers want to move to a thinner, more flexible client model where users connect to a remote Spark server endpoint instead of managing full Spark installations on their laptops or edge nodes. However, the default Spark Connect deployment pattern on EMR creates several challenges:

1. **Single-endpoint bottleneck**

   Spark Connect servers are usually deployed on the EMR primary node. All interactive clients connect to a single endpoint, which leads to:

   - Concentration of drivers and sessions on one node  
   - Memory and CPU pressure on the primary  
   - Reduced reliability and noisy-neighbor issues in multi-tenant environments  

2. **Lack of natural “cluster mode” distribution**

   Spark Connect server processes are not trivially deployed in a way that exposes multiple predictable endpoints for a load balancer. As a result, it is non-trivial to spread Spark Connect servers and associated drivers across worker nodes while still presenting a **single, stable URL** to end users.

3. **Under-utilized worker capacity**

   EMR task nodes (workers) are where most executor work runs, but the driver and Spark Connect server pressure remains centralized on the primary. This limits horizontal scalability for interactive workloads and can cap overall cluster throughput.

### Goal

Design and implement a **multi–Spark Connect server architecture on Amazon EMR** that:

- Runs **multiple Spark Connect servers on EMR task nodes** (workers)
- Exposes a **single endpoint** to clients (via a lightweight load balancer or routing layer on the primary)
- Distributes incoming Spark Connect sessions and drivers across workers (e.g., round-robin)
- Improves **multi-tenant scale, isolation, and resource utilization** compared to a single-server deployment
- Can be demonstrated with a **simple reference architecture, bootstrap scripts, and example clients**

This repository captures the reference architecture, configuration, and demo code for this approach on Amazon EMR.

### Current State: Edge Node with YARN

You're currently running Spark jobs using `spark-submit` from an edge node configured with YARN and Spark JARs. This works fine for batch jobs, but has limitations:

- No built-in remote connectivity for interactive development
- Requires full Spark installation on every client machine
- Poor developer experience (IDE integration, debugging)
- Version coupling between client and cluster

### Migration Goal: SparkConnect

You want to adopt SparkConnect for:
- Remote DataFrame API access from IDEs/notebooks
- Thin client architecture (no local Spark installation needed)
- Better multi-tenant isolation
- Seamless cluster upgrades without client changes

### The Bottleneck

**Running a single SparkConnect server on the EMR primary node doesn't scale:**

```
Problem: All drivers run on one node
┌──────────────────┐
│  Primary Node    │
│  ┌────────────┐  │  ← User 1's Driver (4GB)
│  ┌────────────┐  │  ← User 2's Driver (4GB)
│  ┌────────────┐  │  ← User 3's Driver (4GB)
│  ┌────────────┐  │  ← User N's Driver (4GB)
│  ...             │
│  💥 OOM Error!   │
└──────────────────┘
```

**Issues:**
- Memory contention when multiple users connect
- Single point of failure
- No horizontal scaling path
- One user's OOM can crash all sessions

---

## Solution Overview

Deploy **multiple SparkConnect servers** across dedicated EMR nodes with a load balancer for distribution.

### Key Design Principles

1. **Horizontal Scaling**: Add servers as concurrency increases
2. **Session Affinity**: Clients stick to the same server for session continuity
3. **Resource Isolation**: YARN queue separation prevents driver/executor resource conflicts
4. **High Availability**: Server failures don't affect other sessions

### Architecture at a Glance

```
Clients → Load Balancer → SparkConnect Servers → YARN → Executors
         (HAProxy)        (Distributed Drivers)
```

---

## Architecture

### Component Diagram

```
┌─────────────────────────────────────────────────────────┐
│                    Client Layer                          │
│  Notebooks | IDEs | Scripts | Applications               │
└────────────────────────┬────────────────────────────────┘
                         │ sc://lb.emr.internal:15002
                         ▼
┌─────────────────────────────────────────────────────────┐
│              Load Balancer (Primary Node)                │
│  • HAProxy with source IP sticky sessions                │
│  • Health checks (TCP:15002, interval: 30s)             │
│  • Round-robin distribution                              │
└─────┬────────────┬────────────┬──────────────────────────┘
      │            │            │
      ▼            ▼            ▼
┌──────────┐ ┌──────────┐ ┌──────────┐
│SC Server1│ │SC Server2│ │SC Server3│  (Core/Task Nodes)
│:15002    │ │:15002    │ │:15002    │
│Driver    │ │Driver    │ │Driver    │
│4GB/2core │ │4GB/2core │ │4GB/2core │
└────┬─────┘ └────┬─────┘ └────┬─────┘
     │            │            │
     └────────────┼────────────┘
                  ▼
     ┌──────────────────────────┐
     │   YARN ResourceManager   │
     │                          │
     │ Queue: default (70%)     │
     │ Queue: sparkconnect (30%)│
     └────────┬─────────────────┘
              │
              ▼
     [Executor Pool across cluster]
```

### Request Flow

1. **Client connects** to load balancer endpoint
2. **HAProxy routes** to available SparkConnect server (sticky by source IP)
3. **SparkConnect server** receives gRPC request with unresolved logical plan
4. **Server acts as driver**, analyzes plan and submits to YARN
5. **YARN allocates executors** from cluster capacity
6. **Results stream back** to client via gRPC (Arrow format)

### Critical Design Decisions

#### 1. Session Stickiness (MANDATORY)

SparkConnect is stateful - clients must reconnect to the same server:
- Session maintains DataFrame cache
- Temp views are session-scoped
- Configuration persists per session

**Implementation**: HAProxy sticky tables based on source IP

#### 2. Node Placement Strategy

**Recommended**: Dedicated core nodes or on-demand task nodes
- Avoid Spot instances (termination risk kills active sessions)
- Minimum 3 servers for HA
- Provision based on: `(concurrent_users / 5) rounded up`

#### 3. YARN Resource Isolation

**Problem**: Without isolation, SparkConnect servers and executors compete for same resources

**Solution**: Separate YARN capacity queues
```
sparkconnect queue: 30% capacity (drivers run here)
default queue: 70% capacity (executors run here)
```

---

## Quick Start

### Prerequisites

- EMR 6.x or 7.x with Spark 3.4+
- SSH/SSM access to EMR nodes
- Ability to modify EMR configurations
- Understanding of YARN capacity scheduler

### Installation (10 minutes)

```bash
# 1. Clone this repo
git clone https://github.com/yourusername/sparkconnect-emr-scaling.git
cd sparkconnect-emr-scaling

# 2. Configure your cluster details
cp config/cluster.env.example config/cluster.env
# Edit cluster.env with your EMR cluster ID and node IPs

# 3. Run setup script
./scripts/setup-all.sh
```

This will:
- Configure YARN capacity scheduler
- Deploy SparkConnect servers to designated nodes
- Setup HAProxy on primary node
- Configure systemd services
- Validate installation

### Manual Installation

If you prefer step-by-step control, see [Implementation Guide](#implementation-guide).

---

## Implementation Guide

### Step 1: Provision Infrastructure

**Add dedicated nodes for SparkConnect servers:**

```bash
# Option A: Add core nodes (recommended)
aws emr modify-instance-groups \
  --cluster-id j-XXXXXXXXXXXXX \
  --instance-groups InstanceGroupId=ig-CORE,InstanceCount=5
  # Adds 3 additional core nodes
```

**Node Requirements:**
- Instance type: `m5.xlarge` or larger
- Count: Minimum 3 for HA
- Market: On-demand (not Spot)

### Step 2: Configure YARN Capacity Scheduler

Create or modify `capacity-scheduler.xml`:

```xml
<configuration>
  <!-- Define queues -->
  <property>
    <name>yarn.scheduler.capacity.root.queues</name>
    <value>default,sparkconnect</value>
  </property>
  
  <!-- Default queue for executors -->
  <property>
    <name>yarn.scheduler.capacity.root.default.capacity</name>
    <value>70</value>
  </property>
  
  <!-- SparkConnect queue for drivers -->
  <property>
    <name>yarn.scheduler.capacity.root.sparkconnect.capacity</name>
    <value>30</value>
  </property>
  
  <property>
    <name>yarn.scheduler.capacity.root.sparkconnect.maximum-capacity</name>
    <value>40</value>
  </property>
  
  <!-- Limit applications per queue -->
  <property>
    <name>yarn.scheduler.capacity.root.sparkconnect.maximum-applications</name>
    <value>100</value>
  </property>
</configuration>
```

**Apply via EMR reconfiguration:**
```bash
aws emr modify-instance-groups --cli-input-json file://yarn-config.json
```

### Step 3: Deploy SparkConnect Servers

**On each designated node** (core-node-1, core-node-2, core-node-3):

#### 3.1 Create startup script

```bash
sudo mkdir -p /opt/sparkconnect
sudo vim /opt/sparkconnect/start-server.sh
```

```bash
#!/bin/bash
export SPARK_HOME=/usr/lib/spark
export JAVA_HOME=/usr/lib/jvm/java-11-amazon-corretto

# Server configuration
export SPARK_CONNECT_SERVER_PORT=15002

# Start SparkConnect server
$SPARK_HOME/sbin/start-connect-server.sh \
  --packages org.apache.spark:spark-connect_2.12:3.5.1 \
  --master yarn \
  --deploy-mode client \
  --conf spark.driver.bindAddress=$(hostname -i) \
  --conf spark.driver.port=15002 \
  --conf spark.yarn.queue=sparkconnect \
  --conf spark.driver.memory=4g \
  --conf spark.driver.cores=2 \
  --conf spark.executor.memory=4g \
  --conf spark.executor.cores=2 \
  --conf spark.dynamicAllocation.enabled=true \
  --conf spark.dynamicAllocation.minExecutors=0 \
  --conf spark.dynamicAllocation.maxExecutors=10 \
  --conf spark.sql.shuffle.partitions=200
```

```bash
sudo chmod +x /opt/sparkconnect/start-server.sh
```

#### 3.2 Create systemd service

```bash
sudo vim /etc/systemd/system/sparkconnect.service
```

```ini
[Unit]
Description=SparkConnect Server
After=network.target

[Service]
Type=forking
User=hadoop
Group=hadoop
ExecStart=/opt/sparkconnect/start-server.sh
ExecStop=/usr/lib/spark/sbin/stop-connect-server.sh
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable sparkconnect
sudo systemctl start sparkconnect
sudo systemctl status sparkconnect
```

**Verify server is running:**
```bash
sudo netstat -tlnp | grep 15002
# Should show SparkConnect listening on port 15002
```

### Step 4: Setup Load Balancer (Primary Node)

#### 4.1 Install HAProxy

```bash
sudo yum install -y haproxy
```

#### 4.2 Configure HAProxy

```bash
sudo vim /etc/haproxy/haproxy.cfg
```

```
global
    log /dev/log local0
    maxconn 4096
    user haproxy
    group haproxy
    daemon

defaults
    mode tcp
    log global
    option tcplog
    timeout connect 10s
    timeout client 3600s
    timeout server 3600s

# Statistics dashboard
listen stats
    bind *:9000
    mode http
    stats enable
    stats uri /stats
    stats refresh 30s
    stats auth admin:yourpassword

# SparkConnect frontend
frontend sparkconnect_frontend
    bind *:15002
    mode tcp
    default_backend sparkconnect_servers

# SparkConnect backend pool
backend sparkconnect_servers
    mode tcp
    balance roundrobin
    
    # Sticky sessions based on source IP
    stick-table type ip size 100k expire 2h
    stick on src
    
    # Health checks
    option tcp-check
    tcp-check connect port 15002
    
    # Server definitions (update IPs)
    server sc1 10.0.1.100:15002 check inter 30s fall 3 rise 2
    server sc2 10.0.2.100:15002 check inter 30s fall 3 rise 2
    server sc3 10.0.3.100:15002 check inter 30s fall 3 rise 2
```

#### 4.3 Start HAProxy

```bash
sudo systemctl enable haproxy
sudo systemctl start haproxy
sudo systemctl status haproxy
```

**Access stats dashboard**: `http://primary-node:9000/stats`

### Step 5: Client Configuration

**Update connection code:**

```python
from pyspark.sql import SparkSession

# Old: Direct connection to specific server
# spark = SparkSession.builder.remote("sc://core-node-1:15002").getOrCreate()

# New: Connection via load balancer
spark = SparkSession.builder \
    .remote("sc://primary-node.emr.internal:15002") \
    .getOrCreate()

# Test connection
df = spark.sql("SELECT 1 as test")
df.show()
```

**Add retry logic for production:**

```python
import time
from pyspark.sql import SparkSession

def create_spark_session(lb_host, max_retries=3):
    for attempt in range(max_retries):
        try:
            spark = SparkSession.builder \
                .remote(f"sc://{lb_host}:15002") \
                .getOrCreate()
            return spark
        except Exception as e:
            if attempt < max_retries - 1:
                wait_time = 2 ** attempt
                print(f"Connection failed, retrying in {wait_time}s...")
                time.sleep(wait_time)
            else:
                raise

spark = create_spark_session("primary-node.emr.internal")
```

---

## Configuration Reference

### SparkConnect Server Tuning

| Parameter | Default | Recommended | Notes |
|-----------|---------|-------------|-------|
| `spark.driver.memory` | 1g | 4-8g | Based on expected dataset sizes |
| `spark.driver.cores` | 1 | 2-4 | For parallel query planning |
| `spark.executor.memory` | 1g | 4-16g | Workload dependent |
| `spark.dynamicAllocation.enabled` | false | true | Auto-scale executors |
| `spark.dynamicAllocation.maxExecutors` | ∞ | 10-50 | Prevent runaway jobs |

### YARN Queue Sizing

**Capacity calculation:**
```
Driver queue capacity = (max_concurrent_sessions × avg_driver_memory) / total_cluster_memory
Recommended: 25-35% for sparkconnect queue
```

**Example:**
- Cluster: 10 nodes × 64GB = 640GB total
- Expected sessions: 20 concurrent
- Driver memory: 4GB each
- Required: 20 × 4GB = 80GB
- Queue capacity: 80GB / 640GB = 12.5% → set to 30% for headroom

### HAProxy Tuning

```
timeout client/server: 1h (for long-running queries)
stick-table expire: 2h (session lifetime)
health check interval: 30s
fall threshold: 3 (mark down after 3 failures)
rise threshold: 2 (mark up after 2 successes)
```

---

## Troubleshooting

### Server not starting

**Check logs:**
```bash
sudo journalctl -u sparkconnect -f
```

**Common issues:**
- Port 15002 already in use: `sudo lsof -i :15002`
- YARN queue doesn't exist: Verify capacity-scheduler.xml
- Java heap space: Increase driver memory in start script

### Sessions failing randomly

**Symptom**: Queries succeed sometimes, fail other times

**Cause**: Likely sticky session issue - client connecting to different servers

**Fix**: Verify HAProxy sticky table configuration
```bash
echo "show table sparkconnect_servers" | sudo socat stdio /var/lib/haproxy/stats
```

### Load balancer health checks failing

**Debug:**
```bash
# On primary node, test connectivity to each server
nc -zv 10.0.1.100 15002
nc -zv 10.0.2.100 15002
nc -zv 10.0.3.100 15002
```

**Check server status:**
```bash
# On each SparkConnect server node
sudo systemctl status sparkconnect
sudo netstat -tlnp | grep 15002
```

### Out of memory on SparkConnect server

**Symptoms:**
- `java.lang.OutOfMemoryError` in logs
- Server crashes under load

**Solutions:**
1. Increase driver memory in start script
2. Limit concurrent sessions per server
3. Add more SparkConnect servers to pool

---

## FAQ

### Q: Can I run SparkConnect servers on task nodes?

**A:** Yes, but only on **on-demand task nodes**, not Spot instances. Spot termination will kill active sessions.

### Q: What happens if a SparkConnect server crashes?

**A:** Sessions on that server are lost. Clients must reconnect and resubmit queries. Other servers are unaffected.

### Q: How many servers do I need?

**A:** Start with 3 for HA. Add 1 server per 5-10 concurrent users depending on workload.

### Q: Can I use an ALB instead of HAProxy?

**A:** AWS ALB doesn't support gRPC well in TCP mode. Use Network Load Balancer (NLB) or HAProxy.

### Q: Does this work with Spark 3.4.x?

**A:** Yes, SparkConnect was introduced in 3.4. Use the appropriate version in `--packages`.

### Q: How do I upgrade Spark versions?

**A:** With SparkConnect, you can upgrade the server side independently. Update cluster Spark version and SparkConnect package version in start script. Clients continue working without changes.

---

## Project Structure

```
sparkconnect-emr-scaling/
├── README.md                 # This file
├── docs/
│   ├── architecture.md       # Detailed architecture diagrams
│   ├── troubleshooting.md    # Extended troubleshooting guide
│   └── performance-tuning.md # Performance optimization tips
├── config/
│   ├── cluster.env.example   # Cluster configuration template
│   ├── haproxy.cfg.template  # HAProxy configuration template
│   ├── capacity-scheduler.xml # YARN queue configuration
│   └── spark-defaults.conf   # Spark configuration
├── scripts/
│   ├── setup-all.sh          # Full automated setup
│   ├── setup-yarn.sh         # Configure YARN queues
│   ├── deploy-server.sh      # Deploy SparkConnect server
│   ├── setup-loadbalancer.sh # Configure HAProxy
│   └── health-check.py       # Health monitoring script
├── monitoring/
│   ├── prometheus.yml        # Prometheus configuration
│   ├── grafana-dashboard.json # Grafana dashboard
│   └── cloudwatch-metrics.sh # CloudWatch metrics script
└── examples/
    ├── client-connection.py  # Client connection examples
    └── stress-test.py        # Load testing script
```

---

## Contributing

Contributions welcome! Please:

1. Fork the repo
2. Create a feature branch (`git checkout -b feature/improvement`)
3. Commit changes (`git commit -am 'Add improvement'`)
4. Push to branch (`git push origin feature/improvement`)
5. Open a Pull Request

---

## License

Apache License 2.0 - see [LICENSE](LICENSE) file

---

## Acknowledgments

- Inspired by production challenges scaling SparkConnect on EMR
- Community feedback from Spark users mailing list
- AWS EMR team for documentation and support

---

**Questions?** Open an issue or reach out to the maintainers.
