#!/bin/bash
# Install git hooks

echo "📦 Installing git hooks..."

# Make hooks executable
chmod +x .githooks/pre-push

# Configure git to use our hooks directory
git config core.hooksPath .githooks

echo "✅ Git hooks installed successfully!"
