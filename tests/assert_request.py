"""assert_request.py INDEX key=value ... : check body fields of request INDEX
(0-based, negative from the end) recorded by the mock. key=@absent asserts a
field was not sent."""
import json
import os
import sys

rows = [json.loads(line) for line in open(os.environ["REQUESTS_FILE"]) if line.strip()]
index = int(sys.argv[1])
row = rows[index]
body = row.get("body", {})
ok = True
for pair in sys.argv[2:]:
    key, _, want = pair.partition("=")
    got = body.get(key, "@absent")
    if got != want:
        ok = False
        print(f"request[{index}].{key}: want {want!r}, got {got!r}")
print(json.dumps(row, indent=2))
sys.exit(0 if ok else 1)
