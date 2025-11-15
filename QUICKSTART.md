# Quick Start Reference

**Get up and running in 15 minutes.**

## Prerequisites Checklist

- [ ] EMR cluster running (Spark 3.4+)
- [ ] SSH access to EMR nodes
- [ ] 3+ nodes available for SparkConnect servers
- [ ] AWS CLI configured

## Installation Steps

### 1. Clone and Configure (2 minutes)

```bash
git clone git@github.com:knkarthik01/emr-spark-connect.git
cd emr-spark-connect
cp config/cluster.env.example config/cluster.env
```

**Edit `config/cluster.env`** with your cluster details:
```bash
CLUSTER_ID="j-XXXXXXXXXXXXX"              # Your EMR cluster ID
PRIMARY_NODE="ip-10-0-1-50.ec2.internal"  # Primary node hostname
SPARKCONNECT_NODES="node1,node2,node3"    # Comma-separated server nodes
```

### 2. Run Setup (10 minutes)

```bash
./scripts/setup-all.sh
```

This will:
1. Configure YARN queues
2. Deploy SparkConnect servers
3. Setup HAProxy load balancer
4. Run health checks
5. Test connection

### 3. Connect from Client (1 minute)

```python
from pyspark.sql import SparkSession

spark = SparkSession.builder \
    .remote("sc://your-primary-node:15002") \
    .getOrCreate()

# Test it
spark.sql("SELECT 'Hello SparkConnect!' as message").show()
```

## Common Commands

### Check Server Status
```bash
# On any SparkConnect server node
sudo systemctl status sparkconnect
sudo journalctl -u sparkconnect -n 50
```

### Check HAProxy Stats
```
http://your-primary-node:9000/stats
```

### Restart a Server
```bash
ssh your-server-node
sudo systemctl restart sparkconnect
```

### Add a New Server
```bash
./scripts/deploy-server.sh new-node-hostname
# Then update HAProxy config and reload
```

## Troubleshooting Quick Fixes

### Connection Refused
```bash
# Check server is running
nc -zv server-node 15002

# Check HAProxy
sudo systemctl status haproxy
```

### Session Lost
- Check HAProxy sticky sessions are configured
- Verify client IP hasn't changed
- Review HAProxy stats for connection distribution

### Out of Memory
- Increase `DRIVER_MEMORY` in `config/cluster.env`
- Redeploy server: `./scripts/deploy-server.sh node-hostname`

## Configuration Quick Reference

| Setting | Default | When to Change |
|---------|---------|----------------|
| `DRIVER_MEMORY` | 4g | Heavy queries, large DataFrames |
| `MAX_EXECUTORS` | 10 | Limit resource usage per user |
| `YARN_SPARKCONNECT_QUEUE_CAPACITY` | 30 | Adjust based on workload ratio |
| `HAPROXY_STICKY_TABLE_EXPIRE` | 2h | Longer for persistent sessions |

## Monitoring Checklist

Daily checks:
- [ ] HAProxy stats dashboard
- [ ] Active session count per server
- [ ] YARN queue utilization
- [ ] Server health status

Weekly checks:
- [ ] Memory usage trends
- [ ] Connection failure rate
- [ ] Average query execution time
- [ ] Resource utilization patterns

## Getting Help

1. **Check logs first**: `sudo journalctl -u sparkconnect -f`
2. **Review architecture docs**: `docs/architecture.md`
3. **Search issues**: https://github.com/knkarthik01/emr-spark-connect/issues
4. **Open new issue** with:
   - EMR version
   - Spark version
   - Error logs
   - Configuration (sanitized)

## Useful Links

- [Full Documentation](README.md)
- [Architecture Details](docs/architecture.md)
- [SparkConnect Official Docs](https://spark.apache.org/docs/latest/spark-connect-overview.html)
- [HAProxy Documentation](http://www.haproxy.org/)