#!/bin/bash
# deploy-server.sh - Deploy SparkConnect server to a specific node
# Usage: ./deploy-server.sh <node-hostname-or-ip>

set -e

NODE=$1
if [ -z "$NODE" ]; then
    echo "Usage: ./deploy-server.sh <node-hostname-or-ip>"
    exit 1
fi

# Load configuration
source config/cluster.env

echo "Deploying SparkConnect server to $NODE..."

# Create directory structure
ssh -i "$SSH_KEY_PATH" ${SSH_USER}@${NODE} "sudo mkdir -p /opt/sparkconnect"

# Copy startup script
cat > /tmp/start-server.sh << 'EOF'
#!/bin/bash
export SPARK_HOME=/usr/lib/spark
export JAVA_HOME=/usr/lib/jvm/java-11-amazon-corretto

export SPARK_CONNECT_SERVER_PORT=${SPARKCONNECT_PORT}

$SPARK_HOME/sbin/start-connect-server.sh \
  --packages org.apache.spark:spark-connect_2.12:3.5.1 \
  --master yarn \
  --deploy-mode client \
  --conf spark.driver.bindAddress=$(hostname -i) \
  --conf spark.driver.port=${SPARKCONNECT_PORT} \
  --conf spark.yarn.queue=sparkconnect \
  --conf spark.driver.memory=${DRIVER_MEMORY} \
  --conf spark.driver.cores=${DRIVER_CORES} \
  --conf spark.executor.memory=${EXECUTOR_MEMORY} \
  --conf spark.executor.cores=${EXECUTOR_CORES} \
  --conf spark.dynamicAllocation.enabled=true \
  --conf spark.dynamicAllocation.minExecutors=0 \
  --conf spark.dynamicAllocation.maxExecutors=${MAX_EXECUTORS} \
  --conf spark.sql.shuffle.partitions=200
EOF

# Substitute environment variables
sed -i "s/\${SPARKCONNECT_PORT}/${SPARKCONNECT_PORT}/g" /tmp/start-server.sh
sed -i "s/\${DRIVER_MEMORY}/${DRIVER_MEMORY}/g" /tmp/start-server.sh
sed -i "s/\${DRIVER_CORES}/${DRIVER_CORES}/g" /tmp/start-server.sh
sed -i "s/\${EXECUTOR_MEMORY}/${EXECUTOR_MEMORY}/g" /tmp/start-server.sh
sed -i "s/\${EXECUTOR_CORES}/${EXECUTOR_CORES}/g" /tmp/start-server.sh
sed -i "s/\${MAX_EXECUTORS}/${MAX_EXECUTORS}/g" /tmp/start-server.sh

scp -i "$SSH_KEY_PATH" /tmp/start-server.sh ${SSH_USER}@${NODE}:/tmp/
ssh -i "$SSH_KEY_PATH" ${SSH_USER}@${NODE} "sudo mv /tmp/start-server.sh /opt/sparkconnect/ && sudo chmod +x /opt/sparkconnect/start-server.sh"

# Create systemd service
cat > /tmp/sparkconnect.service << 'EOF'
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
EOF

scp -i "$SSH_KEY_PATH" /tmp/sparkconnect.service ${SSH_USER}@${NODE}:/tmp/
ssh -i "$SSH_KEY_PATH" ${SSH_USER}@${NODE} << 'ENDSSH'
sudo mv /tmp/sparkconnect.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable sparkconnect
sudo systemctl start sparkconnect
ENDSSH

echo "Waiting for server to start..."
sleep 15

# Check if server is running
if ssh -i "$SSH_KEY_PATH" ${SSH_USER}@${NODE} "sudo systemctl is-active sparkconnect" > /dev/null; then
    echo "✓ SparkConnect server deployed and running on $NODE"
else
    echo "✗ Failed to start SparkConnect server on $NODE"
    echo "Check logs with: ssh $NODE 'sudo journalctl -u sparkconnect -n 50'"
    exit 1
fi

# Clean up temp files
rm -f /tmp/start-server.sh /tmp/sparkconnect.service