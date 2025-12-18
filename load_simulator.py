#!/usr/bin/env python3

import requests
import time
from concurrent.futures import ThreadPoolExecutor

# --- Configuration ---
# IP of your Nginx load balancer (127.0.0.1 is the localhost address for your host machine)
TARGET_IP = "127.0.0.1"
URL = f"http://{TARGET_IP}"

# Increase this number to generate a heavier load on the VM
REQUESTS_PER_SECOND = 200 

# How long the test should run in seconds
DURATION_SECONDS = 120 

def send_request(url):
    """Sends a single HTTP request and prints the response."""
    try:
        response = requests.get(url, timeout=5)
        # The response text will show which VM (e.g., netBridge1) handled the request
        print(f"Status: {response.status_code}, Response: {response.text.strip()}")
    except requests.exceptions.RequestException as e:
        print(f"Request failed: {e}")

# --- Main Execution ---
if __name__ == "__main__":
    print(f"Starting load test on {URL} for {DURATION_SECONDS} seconds...")
    print(f"Generating {REQUESTS_PER_SECOND} requests per second.")

    # Use a thread pool to send requests concurrently
    with ThreadPoolExecutor(max_workers=REQUESTS_PER_SECOND) as executor:
        start_time = time.time()
        while time.time() - start_time < DURATION_SECONDS:
            # Submit a batch of requests
            for _ in range(REQUESTS_PER_SECOND):
                executor.submit(send_request, URL)
            
            # Wait 1 second before sending the next batch to maintain the rate
            time.sleep(1)

    print("Load test finished.")
