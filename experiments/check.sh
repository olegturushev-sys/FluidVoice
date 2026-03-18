#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

echo "=== FluidVoice Build Pre-Check ==="

ISSUES=0

# Check trailing whitespace
if grep -r '[[:space:]]$' Sources/ --include='*.swift' 2>/dev/null | head -1 | grep -q .; then
    echo "✗ Trailing whitespace found"
    ISSUES=$((ISSUES + 1))
else
    echo "✓ No trailing whitespace"
fi

# Check for optional binding on non-optional speakerSegments
if grep -r 'if let.*speakerSegments' Sources/ 2>/dev/null | grep -q .; then
    echo "✗ Optional binding on non-optional speakerSegments"
    ISSUES=$((ISSUES + 1))
else
    echo "✓ No bad optional binding"
fi

# Check for self-import
if grep -r '^import FluidVoice' Sources/ 2>/dev/null | grep -q .; then
    echo "✗ Self-import of FluidVoice"
    ISSUES=$((ISSUES + 1))
else
    echo "✓ No self-import"
fi

# Check deprecated onChange (old format without underscore)
if grep -rn '\.onChange(of:.*) { [a-zA-Z_][a-zA-Z0-9_]* in' Sources/ 2>/dev/null | grep -v '_, ' | head -3; then
    echo "⚠ Found deprecated onChange format (missing underscore)"
    ISSUES=$((ISSUES + 1))
else
    echo "✓ No deprecated onChange"
fi

echo ""
echo "METRIC issues_found=$ISSUES"

if [ $ISSUES -eq 0 ]; then
    echo "✓ Pre-check passed"
    exit 0
else
    echo "✗ Issues found"
    exit 1
fi
