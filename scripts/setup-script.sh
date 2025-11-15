#!/bin/bash
# setup-all.sh - Automated SparkConnect Multi-Server Setup for EMR
# 
# Usage: ./setup-all.sh
# Prerequisites: 
#   - EMR cluster running
#   - SSH access to all nodes
#   - config/cluster.env configured

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Load configuration
if [ ! -f "config/cluster.env" ]; then
    echo -e "${RED}Error: config/cluster.env not found${NC}"
    echo "Copy config/cluster.env.example and configure your cluster details"
    exit 1
fi

source config/cluster.env

# Validate configuration
if [ -z "$CLUSTER_ID" ] || [ -z "$PRIMARY_NODE" ] || [ -z "$SPARKCONNECT_NODES" ]; then
    echo -e "${RED}Error: Missing required configuration${NC}"
    echo "Check config/cluster.env for required variables"
    exit 1
fi

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}SparkConnect Multi-Server Setup${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "Cluster ID: $CLUSTER_ID"
echo "Primary Node: $PRIMARY_NODE"
echo "SparkConnect Nodes: $SPARKCONNECT_NODES"
echo ""

# Step 1: Configure YARN
echo -e "${YELLOW}Step 1: Configuring YARN capacity scheduler...${NC}"
./scripts/setup-yarn.sh
echo -e "${GREEN}✓ YARN configured${NC}"
echo ""

# Step 2: Deploy SparkConnect servers
echo -e "${YELLOW}Step 2: Deploying SparkConnect servers...${NC}"
IFS=',' read -ra NODES <<< "$SPARKCONNECT_NODES"
for node in "${NODES[@]}"; do
    echo "  Deploying to $node..."
    ./scripts/deploy-server.sh "$node"
done
echo -e "${GREEN}✓ SparkConnect servers deployed${NC}"
echo ""

# Step 3: Setup load balancer
echo -e "${YELLOW}Step 3: Setting up load balancer on primary node...${NC}"
./scripts/setup-loadbalancer.sh
echo -e "${GREEN}✓ Load balancer configured${NC}"
echo ""

# Step 4: Health check
echo -e "${YELLOW}Step 4: Running health checks...${NC}"
sleep 10  # Wait for servers to start

all_healthy=true
for node in "${NODES[@]}"; do
    if python3 scripts/health-check.py "$node" 15002; then
        echo -e "  ${GREEN}✓${NC} $node is healthy"
    else
        echo -e "  ${RED}✗${NC} $node is not responding"
        all_healthy=false
    fi
done

if [ "$all_healthy" = true ]; then
    echo -e "${GREEN}✓ All servers healthy${NC}"
else
    echo -e "${RED}⚠ Some servers are not healthy. Check logs.${NC}"
fi
echo ""

# Step 5: Test connection
echo -e "${YELLOW}Step 5: Testing client connection...${NC}"
python3 examples/client-connection.py "$PRIMARY_NODE" 15002
echo -e "${GREEN}✓ Client connection successful${NC}"
echo ""

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Setup Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "Next steps:"
echo "  1. Update clients to connect to: sc://${PRIMARY_NODE}:15002"
echo "  2. Monitor HAProxy stats at: http://${PRIMARY_NODE}:9000/stats"
echo "  3. Check server logs: sudo journalctl -u sparkconnect -f"
echo ""
echo "Documentation: https://github.com/yourusername/sparkconnect-emr-scaling"