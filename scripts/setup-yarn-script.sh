#!/bin/bash
# setup-yarn.sh - Configure YARN capacity scheduler for SparkConnect

set -e

# Load configuration
source config/cluster.env

echo "Configuring YARN capacity scheduler for cluster $CLUSTER_ID..."

# Create capacity scheduler configuration
cat > /tmp/capacity-scheduler.json << EOF
{
  "Classification": "capacity-scheduler",
  "Properties": {
    "yarn.scheduler.capacity.root.queues": "default,sparkconnect",
    "yarn.scheduler.capacity.root.default.capacity": "${YARN_DEFAULT_QUEUE_CAPACITY}",
    "yarn.scheduler.capacity.root.default.user-limit-factor": "1",
    "yarn.scheduler.capacity.root.default.maximum-capacity": "100",
    "yarn.scheduler.capacity.root.default.state": "RUNNING",
    "yarn.scheduler.capacity.root.default.acl_submit_applications": "*",
    "yarn.scheduler.capacity.root.sparkconnect.capacity": "${YARN_SPARKCONNECT_QUEUE_CAPACITY}",
    "yarn.scheduler.capacity.root.sparkconnect.user-limit-factor": "1",
    "yarn.scheduler.capacity.root.sparkconnect.maximum-capacity": "40",
    "yarn.scheduler.capacity.root.sparkconnect.state": "RUNNING",
    "yarn.scheduler.capacity.root.sparkconnect.acl_submit_applications": "*",
    "yarn.scheduler.capacity.root.sparkconnect.maximum-applications": "100"
  }
}
EOF

echo "Generated YARN configuration:"
cat /tmp/capacity-scheduler.json
echo ""

# For EMR, you need to modify this using AWS CLI reconfiguration
echo "To apply this configuration to your EMR cluster, run:"
echo ""
echo "aws emr modify-instance-groups \\"
echo "  --cluster-id $CLUSTER_ID \\"
echo "  --region $CLUSTER_REGION \\"
echo "  --configurations file:///tmp/capacity-scheduler.json"
echo ""

# Check if user wants to apply now
read -p "Apply configuration now? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "Applying YARN configuration..."
    
    aws emr modify-cluster-attributes \
      --cluster-id "$CLUSTER_ID" \
      --region "$CLUSTER_REGION" \
      --configurations file:///tmp/capacity-scheduler.json
    
    echo "✓ YARN configuration updated"
    echo "Note: YARN ResourceManager needs to be restarted for changes to take effect"
    echo ""
    echo "To restart YARN ResourceManager, SSH to primary node and run:"
    echo "  sudo systemctl restart hadoop-yarn-resourcemanager"
else
    echo "Configuration not applied. Run the AWS CLI command above manually."
fi

# Clean up
rm -f /tmp/capacity-scheduler.json