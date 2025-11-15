#!/usr/bin/env python3
"""
client-connection.py - Example SparkConnect client with retry logic
Usage: python3 client-connection.py <loadbalancer-host> <port>
"""

import sys
import time
from pyspark.sql import SparkSession


def create_spark_session(host, port, max_retries=3):
    """Create SparkSession with retry logic."""
    remote_url = f"sc://{host}:{port}"
    
    for attempt in range(max_retries):
        try:
            print(f"Connecting to SparkConnect at {remote_url}...")
            spark = SparkSession.builder \
                .remote(remote_url) \
                .appName("SparkConnect-Example") \
                .getOrCreate()
            
            print(f"✓ Successfully connected to {remote_url}")
            return spark
            
        except Exception as e:
            if attempt < max_retries - 1:
                wait_time = 2 ** attempt
                print(f"Connection failed: {e}")
                print(f"Retrying in {wait_time}s... (attempt {attempt + 1}/{max_retries})")
                time.sleep(wait_time)
            else:
                print(f"✗ Failed to connect after {max_retries} attempts")
                raise


def run_test_queries(spark):
    """Run simple test queries to verify connection."""
    print("\n" + "="*60)
    print("Running Test Queries")
    print("="*60 + "\n")
    
    # Test 1: Simple SQL
    print("Test 1: Simple SQL query")
    df1 = spark.sql("SELECT 'Hello from SparkConnect!' as message")
    df1.show()
    
    # Test 2: DataFrame operations
    print("\nTest 2: DataFrame operations")
    data = [(1, "Alice", 100), (2, "Bob", 200), (3, "Charlie", 150)]
    df2 = spark.createDataFrame(data, ["id", "name", "amount"])
    df2.show()
    
    # Test 3: Aggregation
    print("\nTest 3: Aggregation")
    df3 = df2.groupBy().sum("amount")
    df3.show()
    
    # Test 4: Filtering
    print("\nTest 4: Filtering")
    df4 = df2.filter(df2.amount > 125)
    df4.show()
    
    print("\n✓ All test queries completed successfully!")


def get_session_info(spark):
    """Display session information."""
    print("\n" + "="*60)
    print("Session Information")
    print("="*60)
    print(f"Spark Version: {spark.version}")
    print(f"Application ID: {spark.sparkContext.applicationId}")
    print(f"Application Name: {spark.sparkContext.appName}")
    print("="*60 + "\n")


def main():
    if len(sys.argv) != 3:
        print("Usage: python3 client-connection.py <loadbalancer-host> <port>")
        print("Example: python3 client-connection.py primary-node.emr.internal 15002")
        sys.exit(1)
    
    host = sys.argv[1]
    try:
        port = int(sys.argv[2])
    except ValueError:
        print(f"Invalid port: {sys.argv[2]}")
        sys.exit(1)
    
    try:
        # Create SparkSession
        spark = create_spark_session(host, port)
        
        # Get session info
        get_session_info(spark)
        
        # Run test queries
        run_test_queries(spark)
        
        # Stop session
        print("\nStopping SparkSession...")
        spark.stop()
        print("✓ Session stopped successfully")
        
    except KeyboardInterrupt:
        print("\n\nInterrupted by user")
        sys.exit(130)
    except Exception as e:
        print(f"\n✗ Error: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()