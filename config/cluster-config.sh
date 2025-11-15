# cluster.env.example
# Copy this file to cluster.env and configure for your EMR cluster

# EMR Cluster Configuration
CLUSTER_ID="j-XXXXXXXXXXXXX"
CLUSTER_REGION="us-east-1"

# Primary Node (where HAProxy will run)
PRIMARY_NODE="ip-10-0-1-50.ec2.internal"
PRIMARY_NODE_IP="10.0.1.50"

# SparkConnect Server Nodes (comma-separated)
# These should be core nodes or on-demand task nodes
SPARKCONNECT_NODES="ip-10-0-1-100.ec2.internal,ip-10-0-2-100.ec2.internal,ip-10-0-3-100.ec2.internal"
SPARKCONNECT_NODE_IPS="10.0.1.100,10.0.2.100,10.0.3.100"

# SparkConnect Configuration
SPARKCONNECT_PORT=15002
DRIVER_MEMORY="4g"
DRIVER_CORES=2
EXECUTOR_MEMORY="4g"
EXECUTOR_CORES=2
MAX_EXECUTORS=10

# YARN Configuration
YARN_SPARKCONNECT_QUEUE_CAPACITY=30
YARN_DEFAULT_QUEUE_CAPACITY=70

# HAProxy Configuration
HAPROXY_STATS_PORT=9000
HAPROXY_STATS_USER="admin"
HAPROXY_STATS_PASS="changeme"
HAPROXY_HEALTH_CHECK_INTERVAL="30s"
HAPROXY_STICKY_TABLE_EXPIRE="2h"

# SSH Configuration
SSH_USER="hadoop"
SSH_KEY_PATH="~/.ssh/emr-key.pem"

# Monitoring (optional)
ENABLE_CLOUDWATCH_METRICS=true
ENABLE_PROMETHEUS=false
PROMETHEUS_PORT=9090