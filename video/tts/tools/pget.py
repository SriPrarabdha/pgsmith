"""Parallel ranged download (resumable): pget.py URL OUT [connections]"""
import os, sys, threading, time, urllib.request
TOKEN = os.environ.get("HF_TOKEN") or os.environ.get("HUGGING_FACE_HUB_TOKEN") or ""
AUTH = {"Authorization": f"Bearer {TOKEN}"} if TOKEN else {}
url, out = sys.argv[1], sys.argv[2]
n = int(sys.argv[3]) if len(sys.argv) > 3 else 8
import time
for attempt in range(60):  # the network here drops DNS now and then
    try:
        req = urllib.request.Request(url, method="HEAD")
        with urllib.request.urlopen(req, timeout=60) as r:
            size = int(r.headers["Content-Length"]); final = r.geturl()
        break
    except Exception as e:
        print("head retry", e, flush=True); time.sleep(5)
part = size // n + 1
if not os.path.exists(out) or os.path.getsize(out) != size:
    with open(out, "ab") as f: f.truncate(size)
done_path = out + ".done"
done = set(open(done_path).read().split()) if os.path.exists(done_path) else set()
lock = threading.Lock()
def work(i):
    a, b = i * part, min(size, (i + 1) * part) - 1
    if str(i) in done or a > b: return
    for attempt in range(30):
        try:
            rq = urllib.request.Request(final if attempt < 3 else url, headers={"Range": f"bytes={a}-{b}"})
            with urllib.request.urlopen(rq, timeout=60) as r, open(out, "r+b") as f:
                f.seek(a)
                while True:
                    chunk = r.read(1 << 20)
                    if not chunk: break
                    f.write(chunk); a += len(chunk)
            if a > b:
                with lock, open(done_path, "a") as d: d.write(f"{i}\n")
                return
        except Exception as e:
            print("retry", i, e, flush=True); time.sleep(3); time.sleep(3)
ts = [threading.Thread(target=work, args=(i,)) for i in range(n)]
[t.start() for t in ts]; [t.join() for t in ts]
print("ok", out, size)
