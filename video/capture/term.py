"""Run real commands against the demo stack and save what they print, for the video's terminal scenes.

    python video/capture/term.py NAME --sql "SELECT ..."        # psql in the Supabase container
    python video/capture/term.py NAME --sh "flagshift plan ..."  # a shell command (shown as typed)
Each run appends {prompt, command, output, ms} to video/src/data/term/NAME.json (use --reset to start over).
"""
import argparse, json, os, pathlib, subprocess, time

ROOT = pathlib.Path(__file__).resolve().parents[2]
OUT = ROOT / "video/src/data/term"
ap = argparse.ArgumentParser()
ap.add_argument("name")
g = ap.add_mutually_exclusive_group(required=True)
g.add_argument("--sql")
g.add_argument("--sh")
ap.add_argument("--show", help="command text to display instead of the real one")
ap.add_argument("--reset", action="store_true")
ap.add_argument("--psql-flags", default="")
a = ap.parse_args()

env = dict(os.environ, PGSMITH_CONTAINER="pgsmith-appdb-1", PGSMITH_DB="postgres",
           PGSMITH_DSN="postgresql://postgres:pgfs@127.0.0.1:55433/postgres", COLUMNS="200")
for line in (ROOT / "demos/.env").read_text().splitlines():
    k, _, v = line.partition("=")
    env[k] = v
t0 = time.perf_counter()
if a.sql is not None:
    p = subprocess.run(["scripts/psql", *a.psql_flags.split()], input=a.sql, cwd=ROOT, env=env,
                       capture_output=True, text=True)
    prompt, shown = "postgres=#", a.show or a.sql
else:
    p = subprocess.run(["bash", "-c", a.sh], cwd=ROOT, env=env, capture_output=True, text=True)
    prompt, shown = "$", a.show or a.sh
ms = round((time.perf_counter() - t0) * 1000)
out = (p.stdout + p.stderr).rstrip("\n")
f = OUT / f"{a.name}.json"
items = [] if a.reset or not f.exists() else json.loads(f.read_text())
items.append({"prompt": prompt, "command": shown, "output": out, "ms": ms, "exit": p.returncode})
f.write_text(json.dumps(items, indent=1, ensure_ascii=False))
print(out)
print(f"--- {ms} ms, exit {p.returncode} -> {f.relative_to(ROOT)}")
