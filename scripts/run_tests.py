#!/usr/bin/env python3
import subprocess
import re
import datetime
import sys
import os

# Configuration
TEST_CMD = ["zig", "build", "test", "--summary", "all"]
DOC_PATH = "docs/src/development/tests.md"

def run_tests():
    print(f"Running: {' '.join(TEST_CMD)}")
    start_time = datetime.datetime.now()
    result = subprocess.run(TEST_CMD, capture_output=True, text=True)
    end_time = datetime.datetime.now()
    
    print(result.stdout)
    if result.stderr:
        print(result.stderr, file=sys.stderr)
        
    success = (result.returncode == 0)
    duration = (end_time - start_time).total_seconds()
    
    return success, duration, result.stdout

def update_doc(path, success, duration):
    if not os.path.exists(path):
        print(f"Error: Document not found at {path}")
        return

    with open(path, 'r') as f:
        content = f.read()

    # Update Date
    now_str = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    content = re.sub(r"\*\*Generated on\*\*: .*", f"**Generated on**: {now_str}", content)
    
    # Update Status
    if success:
        status_line = f"**Status**: ✅ All Tests Passing (Last Run: {duration:.2f}s)"
    else:
        status_line = f"**Status**: ❌ FAILED (Last Run: {duration:.2f}s)"
        
    content = re.sub(r"\*\*Status\*\*: .*", status_line, content)
    
    # Optional: Update Result column in tables based on global status?
    # Simple approach: If global PASS, set all Result columns to **PASS**
    # If FAIL, we can't easily know which one, so we might leave them or set to CHECK ??
    # For now, let's blindly set them to PASS if success, to keep it fresh.
    
    if success:
        # Regex to replace existing | **PASS** | or | **FAIL** | with | **PASS** |
        # Table row format: | ... | **RESULT** |
        # We look for the last column.
        pass # Too risky to regex replace table without parsing
        
    with open(path, 'w') as f:
        f.write(content)
        
    print(f"Updated {path}")

def main():
    success, duration, output = run_tests()
    update_doc(DOC_PATH, success, duration)
    
    if not success:
        sys.exit(1)

if __name__ == "__main__":
    main()
