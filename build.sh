#!/bin/bash
# Build script for CryptoAPI

echo "Building CryptoAPI..."

# Build the executable
v -prod -o cryptoapi main.v

# Check if build was successful
if [ $? -eq 0 ]; then
    echo "Build successful: cryptoapi executable created"
    chmod +x cryptoapi
    echo "Executable permissions set"
else
    echo "Build failed"
    exit 1
fi
