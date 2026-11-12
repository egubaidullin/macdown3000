#!/bin/bash

# MacDown 3000 Development Environment Setup Script
# This script automates the setup process for developers

set -e  # Exit on error

echo "======================================"
echo "MacDown 3000 Development Setup"
echo "======================================"
echo ""

# Check if we're in the right directory
if [ ! -f "MacDown 3000.xcodeproj/project.pbxproj" ]; then
    echo "Error: This script must be run from the MacDown 3000 project root directory"
    exit 1
fi

# Step 1: Initialize git submodules
echo "[1/4] Initializing git submodules..."
git submodule update --init --recursive
echo "✓ Submodules initialized"
echo ""

# Step 2: Install Ruby dependencies
echo "[2/4] Installing Ruby dependencies with Bundler..."
# Gemfile.lock pins bundler 2.7.2, which the system Ruby 2.6 that ships with
# macOS cannot provide. Homebrew's Ruby (3.x) can.
if ! command -v ruby &> /dev/null; then
    echo "Error: Ruby not found. Install it with: brew install ruby"
    exit 1
fi
RUBY_MAJOR=$(ruby -e 'print RUBY_VERSION.split(".").first')
if [ "$RUBY_MAJOR" -lt 3 ]; then
    echo "Error: Ruby $RUBY_VERSION is too old for the pinned Bundler."
    echo "Install Homebrew Ruby and put it first on PATH:"
    echo "  brew install ruby"
    echo "  export PATH=\"/opt/homebrew/opt/ruby/bin:\$PATH\""
    exit 1
fi
if ! command -v bundle &> /dev/null; then
    echo "Error: Bundler is not installed. Please install it with: gem install bundler -v 2.7.2"
    exit 1
fi
bundle install
echo "✓ Ruby dependencies installed"
echo ""

# Step 3: Install CocoaPods dependencies
echo "[3/4] Installing CocoaPods dependencies..."
bundle exec pod install
echo "✓ CocoaPods dependencies installed"
echo ""

# Step 4: Build peg-markdown-highlight
echo "[4/4] Building peg-markdown-highlight..."
make -C Dependency/peg-markdown-highlight
echo "✓ peg-markdown-highlight built successfully"
echo ""

echo "======================================"
echo "✓ Setup complete!"
echo "======================================"
echo ""
echo "Next steps:"
echo "  1. Open \"MacDown 3000.xcworkspace\" in Xcode"
echo "  2. Select the MacDown scheme"
echo "  3. Build and run (Cmd+R)"
echo ""
echo "To build and test from the terminal (no signing certificate needed):"
echo "  xcodebuild build -workspace \"MacDown 3000.xcworkspace\" -scheme MacDown \\"
echo "    -configuration Debug -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO"
echo "  xcodebuild test -workspace \"MacDown 3000.xcworkspace\" -scheme MacDown \\"
echo "    -configuration Debug -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO"
echo ""
