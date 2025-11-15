#!/usr/bin/env python3
"""
health-check.py - Check if SparkConnect server is healthy
Usage: python3 health-check.py <host> <port>
"""

import sys
import socket


def check_tcp_port(host, port, timeout=5):
    """Check if TCP port is open and accepting connections."""
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(timeout)
        result = sock.connect_ex((host, port))
        sock.close()
        return result == 0
    except socket.error as e:
        print(f"Socket error: {e}", file=sys.stderr)
        return False


def check_grpc_health(host, port):
    """
    Check gRPC server health.
    Note: This is a simple TCP check. For production, implement proper gRPC health checks.
    """
    try:
        import grpc
        
        channel = grpc.insecure_channel(f"{host}:{port}")
        grpc.channel_ready_future(channel).result(timeout=5)
        channel.close()
        return True
    except ImportError:
        # Fall back to TCP check if grpc not available
        return check_tcp_port(host, port)
    except Exception as e:
        print(f"gRPC health check failed: {e}", file=sys.stderr)
        return False


def main():
    if len(sys.argv) != 3:
        print("Usage: python3 health-check.py <host> <port>")
        sys.exit(2)
    
    host = sys.argv[1]
    try:
        port = int(sys.argv[2])
    except ValueError:
        print(f"Invalid port: {sys.argv[2]}")
        sys.exit(2)
    
    # Try gRPC health check first, fall back to TCP
    if check_grpc_health(host, port):
        print(f"✓ {host}:{port} is healthy")
        sys.exit(0)
    else:
        print(f"✗ {host}:{port} is not responding")
        sys.exit(1)


if __name__ == "__main__":
    main()