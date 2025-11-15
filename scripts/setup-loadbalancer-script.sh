#!/bin/bash
# setup-loadbalancer.sh - Configure HAProxy on primary node

set -e

# Load configuration
source config/cluster.env

echo "Setting up HAProxy on $PRIMARY_NODE..."

# Install HAProxy
ssh -i "$SSH_KEY_PATH" ${SSH_USER}@${PRIMARY_NODE} "sudo yum install -y haproxy"

# Generate HAProxy configuration
cat > /tmp/haproxy.cfg << EOF
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

listen stats
    bind *:${HAPROXY_STATS_PORT}
    mode http
    stats enable
    stats uri /stats
    stats refresh 30s
    stats auth ${HAPROXY_STATS_USER}:${HAPROXY_STATS_PASS}

frontend sparkconnect_frontend
    bind *:${SPARKCONNECT_PORT}
    mode tcp
    default_backend sparkconnect_servers

backend sparkconnect_servers
    mode tcp
    balance roundrobin
    
    stick-table type ip size 100k expire ${HAPROXY_STICKY_TABLE_EXPIRE}
    stick on src
    
    option tcp-check
    tcp-check connect port ${SPARKCONNECT_PORT}
EOF

# Add server entries
IFS=',' read -ra NODE_IPS <<< "$SPARKCONNECT_NODE_IPS"
counter=1
for ip in "${NODE_IPS[@]}"; do
    echo "    server sc${counter} ${ip}:${SPARKCONNECT_PORT} check inter ${HAPROXY_HEALTH_CHECK_INTERVAL} fall 3 rise 2" >> /tmp/haproxy.cfg
    ((counter++))
done

# Copy configuration to primary node
scp -i "$SSH_KEY_PATH" /tmp/haproxy.cfg ${SSH_USER}@${PRIMARY_NODE}:/tmp/
ssh -i "$SSH_KEY_PATH" ${SSH_USER}@${PRIMARY_NODE} << 'ENDSSH'
sudo mv /tmp/haproxy.cfg /etc/haproxy/haproxy.cfg
sudo systemctl enable haproxy
sudo systemctl restart haproxy
ENDSSH

echo "Waiting for HAProxy to start..."
sleep 5

# Verify HAProxy is running
if ssh -i "$SSH_KEY_PATH" ${SSH_USER}@${PRIMARY_NODE} "sudo systemctl is-active haproxy" > /dev/null; then
    echo "✓ HAProxy configured and running on $PRIMARY_NODE"
    echo ""
    echo "Access HAProxy stats at: http://${PRIMARY_NODE}:${HAPROXY_STATS_PORT}/stats"
    echo "Credentials: ${HAPROXY_STATS_USER}/${HAPROXY_STATS_PASS}"
else
    echo "✗ Failed to start HAProxy"
    exit 1
fi

# Clean up
rm -f /tmp/haproxy.cfg