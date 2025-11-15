# Architecture Deep Dive

## Overview

This document explains the architectural decisions and technical details of the multi-server SparkConnect deployment on EMR.

## Core Components

### 1. SparkConnect Servers

**Role**: Act as Spark drivers that accept gRPC connections from clients

**Key Characteristics**:
- Each server is a separate JVM process
- Runs in YARN client mode (driver runs on the node, executors distributed)
- Stateful - maintains session context per client connection
- Isolated - server failure doesn't affect other servers

**Process Architecture**:
```
SparkConnect Server Process
├── gRPC Server (port 15002)
│   ├── Receives proto buffers (unresolved logical plans)
│   └── Streams results as Arrow batches
├── Spark Driver
│   ├── Catalyst Optimizer
│   ├── DAG Scheduler
│   ├── Task Scheduler
│   └── YARN ApplicationMaster client
└── Session Manager
    ├── DataFrame cache
    ├── Temp views
    └── Configuration
```

### 2. Load Balancer (HAProxy)

**Role**: Distribute client connections across available servers

**Why HAProxy?**:
- Native TCP load balancing (gRPC requirement)
- Sticky session support (critical for stateful sessions)
- Built-in health checks
- Low latency overhead
- Production-proven for high-throughput workloads

**Alternatives Considered**:
- **AWS ALB**: Poor gRPC support in TCP mode
- **AWS NLB**: Works but less flexible health checks
- **Envoy**: Better gRPC support but higher complexity
- **Nginx**: Requires commercial version for advanced features

**Chosen**: HAProxy for balance of features and simplicity

### 3. YARN Capacity Scheduler

**Role**: Isolate resources between drivers and executors

**Queue Design**:
```
root (100%)
├── default (70%)
│   └── Used by: Executor containers
└── sparkconnect (30%)
    └── Used by: Driver processes (SparkConnect servers)
```

**Why Separate Queues?**:
Without isolation, this happens:
```
Scenario: 10 users, each running heavy jobs
- 10 drivers need: 10 × 4GB = 40GB
- 100 executors need: 100 × 4GB = 400GB
Total demand: 440GB on cluster with 320GB
Result: Resource deadlock - neither drivers nor executors can start
```

With queue isolation:
```
sparkconnect queue: 96GB (30% of 320GB)
- Reserves space for 24 drivers (96GB / 4GB each)
- Prevents executors from consuming driver resources

default queue: 224GB (70% of 320GB)
- Dedicated to executor allocation
- Can't starve drivers
```

## Data Flow

### Client Request Lifecycle

```
1. Client creates SparkSession
   spark = SparkSession.builder.remote("sc://lb:15002").getOrCreate()
   
2. TCP connection established
   Client → HAProxy → SparkConnect Server
   
3. Session initialization
   - Server generates session ID
   - HAProxy sets sticky cookie (source IP table)
   - Client stores session context
   
4. Query submission
   df = spark.sql("SELECT * FROM table WHERE x > 10")
   
5. Logical plan creation (client-side)
   Client translates SQL to unresolved logical plan
   
6. Plan serialization
   Logical plan → Protocol Buffer → gRPC message
   
7. Server receives and analyzes
   - Unresolved plan → Resolved plan (catalog lookup)
   - Resolved plan → Optimized plan (Catalyst rules)
   - Optimized plan → Physical plan (execution strategy)
   
8. YARN resource request
   Driver requests executors from YARN ResourceManager
   
9. Task execution
   - Physical plan split into stages
   - Stages split into tasks
   - Tasks scheduled on executors
   
10. Result streaming
    - Executors return row batches
    - Driver aggregates results
    - Results encoded as Arrow record batches
    - Streamed back to client via gRPC
    
11. Client materializes results
    df.show() triggers action, receives Arrow batches
```

### Session Stickiness Mechanism

**Problem**: Load balancer might route different requests to different servers

**Impact**: 
```python
# Request 1 goes to Server A
df = spark.sql("SELECT * FROM table")

# Request 2 goes to Server B (different server!)
df.show()  # ERROR: df doesn't exist on Server B
```

**Solution**: HAProxy sticky tables

```
When client connects:
1. HAProxy records: source_ip → server mapping
2. Stores in stick-table with 2h expiration
3. All subsequent requests from that IP → same server

Example:
Client IP 192.168.1.100 → Server 1 (first connection)
  All traffic from 192.168.1.100 → Server 1 (for next 2 hours)
```

**Limitation**: Client IP change breaks stickiness
- VPN reconnect
- Network switch (laptop moves wifi → ethernet)
- NAT gateway change

**Mitigation**: Client retry logic handles reconnection

## Resource Management

### Memory Breakdown Per SparkConnect Server

```
Server JVM Process (example: 8GB host)
├── Driver Heap: 4GB (configured via spark.driver.memory)
│   ├── Catalyst optimizer working memory
│   ├── Task scheduler metadata
│   ├── Broadcast variable storage
│   └── User application objects
├── Off-heap: 1GB (spark.driver.memoryOverhead)
│   ├── Native library memory (e.g., Arrow)
│   └── Thread stacks
└── OS/Other processes: 3GB
```

**Sizing Formula**:
```
driver_memory = expected_broadcast_size + result_set_size + overhead
Minimum: 2GB
Recommended: 4-8GB
Large analytics: 16-32GB
```

### YARN Container Allocation

**Driver Container** (on SparkConnect server node):
```
Container Request:
- Memory: spark.driver.memory + spark.driver.memoryOverhead
- Cores: spark.driver.cores
- Queue: sparkconnect
- Priority: HIGH
```

**Executor Containers** (distributed across cluster):
```
Container Request:
- Memory: spark.executor.memory + spark.executor.memoryOverhead
- Cores: spark.executor.cores
- Queue: default
- Priority: NORMAL
```

## High Availability & Fault Tolerance

### Server Failure Scenarios

**Scenario 1: Server Process Crash**
```
Impact: Active sessions on that server lost
Detection: HAProxy health check fails (3 consecutive failures)
Recovery: 
  1. HAProxy marks server as DOWN
  2. New connections routed to healthy servers
  3. Systemd restarts crashed server (RestartSec=10s)
  4. Server comes back up, marked UP after 2 successful health checks
  5. Accepts new connections
```

**Scenario 2: Node Failure**
```
Impact: Server and all its sessions lost
Detection: HAProxy can't connect to server
Recovery:
  1. HAProxy marks server DOWN
  2. Remaining servers handle all traffic
  3. Manual intervention needed to replace node
```

**Scenario 3: Network Partition**
```
Impact: Clients can't reach load balancer
Detection: Client connection timeout
Recovery: Client retry logic attempts reconnection
```

### Graceful Shutdown

**For maintenance/upgrades**:

```bash
# 1. Drain server (HAProxy admin socket)
echo "disable server sparkconnect_servers/sc1" | \
  socat stdio /var/lib/haproxy/stats

# 2. Wait for active sessions to complete
# Monitor: HAProxy stats → Sessions: Current
# Wait until: Current sessions = 0

# 3. Stop server
sudo systemctl stop sparkconnect

# 4. Perform maintenance/upgrade

# 5. Start server
sudo systemctl start sparkconnect

# 6. Re-enable in HAProxy
echo "enable server sparkconnect_servers/sc1" | \
  socat stdio /var/lib/haproxy/stats
```

## Scaling Strategies

### Horizontal Scaling (Add Servers)

**When to scale up**:
- Average concurrent sessions > (server_count × 5)
- Memory pressure on existing servers (>80% used)
- Query queue latency increasing

**How to add a server**:
```bash
# 1. Provision new node
aws emr modify-instance-groups --add-node

# 2. Deploy SparkConnect
./scripts/deploy-server.sh new-node-ip

# 3. Update HAProxy config
# Add: server sc4 new-node-ip:15002 check

# 4. Reload HAProxy
sudo systemctl reload haproxy

# 5. Verify
curl http://primary-node:9000/stats
```

### Vertical Scaling (Increase Server Resources)

**When to scale up**:
- Drivers hitting OOM despite low session count
- Large broadcast joins failing
- Working with big DataFrames in memory

**How to increase resources**:
```bash
# Update start-server.sh
SPARK_DRIVER_MEMORY=8g  # was 4g
SPARK_DRIVER_CORES=4    # was 2

# Restart server
sudo systemctl restart sparkconnect
```

### Auto-Scaling (Future Enhancement)

**Metrics-based scaling**:
```
Scale up trigger:
  - Active sessions per server > 10 (5min average)
  - Driver memory usage > 80%
  
Scale down trigger:
  - Active sessions per server < 3 (15min average)
  - Minimum 2 servers maintained
```

**Implementation**: EMR Managed Scaling + Custom CloudWatch metrics

## Performance Optimization

### Network Optimization

**gRPC Tuning**:
```bash
# In start-server.sh, add:
--conf spark.connect.grpc.maxInboundMessageSize=134217728  # 128MB
--conf spark.connect.grpc.maxOutboundMessageSize=134217728 # 128MB
```

**Arrow Batch Size**:
```bash
--conf spark.sql.execution.arrow.maxRecordsPerBatch=10000
```

### Query Performance

**Partition Tuning**:
```bash
# Adjust based on cluster size
--conf spark.sql.shuffle.partitions=200  # Default
# For large cluster: 400-800
# For small cluster: 100-150
```

**Broadcast Join Threshold**:
```bash
--conf spark.sql.autoBroadcastJoinThreshold=104857600  # 100MB
# Increase if sufficient driver memory available
```

### Memory Management

**Avoid OOM**:
```python
# Limit result set size
df.limit(10000).toPandas()  # Good
df.toPandas()  # Bad - entire dataset to driver

# Use repartition for large writes
df.repartition(200).write.parquet("s3://bucket/data")
```

## Security Considerations

### Current Implementation

**No built-in authentication**:
- SparkConnect protocol doesn't include auth
- HAProxy passes connections transparently
- Relies on network security (VPC, security groups)

### Production Hardening

**Option 1: VPN/Private Network**
```
Clients → VPN → EMR VPC → Load Balancer → Servers
- Simplest approach
- Leverages existing VPN infrastructure
```

**Option 2: Authenticating Proxy**
```
Clients → OAuth Proxy → HAProxy → Servers
Example: oauth2-proxy with Google/Okta
```

**Option 3: mTLS**
```
Configure HAProxy for mutual TLS:
- Client presents certificate
- Server validates certificate
- Encrypted transport
```

**Recommended for production**: VPN + Security Groups

## Monitoring & Observability

### Key Metrics

**Per Server**:
- Active sessions count
- Driver JVM heap usage
- Driver GC time
- YARN container state
- gRPC connection count

**Cluster Level**:
- Total active sessions
- Queue capacity utilization (sparkconnect vs default)
- HAProxy connection distribution
- Health check failure rate

**Client Experience**:
- Connection latency
- Query execution time
- Result streaming throughput

### Logging

**Server logs**:
```bash
# Application logs
sudo journalctl -u sparkconnect -f

# Spark event logs
hdfs dfs -ls /var/log/spark/apps/

# YARN logs
yarn logs -applicationId application_xxx
```

**HAProxy logs**:
```bash
sudo tail -f /var/log/haproxy.log
```

## Comparison: SparkConnect vs Classic Spark

| Aspect | Classic Spark | SparkConnect |
|--------|---------------|--------------|
| **Driver Location** | Client JVM | Server JVM |
| **Client Weight** | Full Spark + dependencies | Thin client (~10MB) |
| **Network** | Direct YARN connection | gRPC to server |
| **Failure Isolation** | Client crash = driver crash | Clients isolated from driver |
| **Version Coupling** | Client = Server version | Client != Server version OK |
| **RDD Support** | Yes | No (DataFrame only) |
| **Use Case** | Batch jobs, spark-submit | Interactive, notebooks, IDEs |

## Future Enhancements

### Roadmap

**Short-term** (1-3 months):
- [ ] CloudWatch integration for metrics
- [ ] Grafana dashboard templates
- [ ] Auto-scaling based on session metrics
- [ ] Health check improvements (gRPC-native)

**Medium-term** (3-6 months):
- [ ] Session migration (experimental)
- [ ] Multi-AZ deployment support
- [ ] Terraform/CloudFormation templates
- [ ] Cost optimization analysis tools

**Long-term** (6-12 months):
- [ ] Kubernetes deployment option
- [ ] Built-in authentication layer
- [ ] Query result caching
- [ ] Connection pooling optimization

## References

- [SparkConnect Official Docs](https://spark.apache.org/docs/latest/spark-connect-overview.html)
- [YARN Capacity Scheduler Guide](https://hadoop.apache.org/docs/stable/hadoop-yarn/hadoop-yarn-site/CapacityScheduler.html)
- [HAProxy Configuration Manual](http://www.haproxy.org/download/2.4/doc/configuration.txt)
- [gRPC Performance Best Practices](https://grpc.io/docs/guides/performance/)