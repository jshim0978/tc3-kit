"""TEST ONLY — furiosa-llm CLI 흉내: `serve <artifact> --served-model-name N --devices D --host H --port P`."""
import os
import sys
from importlib.metadata import version


def main():
    a = sys.argv[1:]
    if not a or a[0] in ("--version", "version"):
        print(f"furiosa-llm {version('furiosa-llm')} (tc3 test stub)")
        return 0
    if a[0] != "serve":
        print(f"stub furiosa-llm: unsupported: {a}", file=sys.stderr)
        return 2
    a = a[1:]
    art, name, port, i = (a[0] if a else ""), "", "8000", 1
    while i < len(a):
        k = a[i]
        if k not in ("--served-model-name", "--devices", "--host", "--port") or i + 1 >= len(a):
            print(f"stub furiosa-llm: unknown option {k}", file=sys.stderr)
            return 2
        if k == "--served-model-name":
            name = a[i + 1]
        elif k == "--port":
            port = a[i + 1]
        i += 2
    if not os.path.isdir(art):
        print(f"ERROR artifact not found: {art}", file=sys.stderr)
        return 1
    print(f"INFO furiosa-llm serve (stub package) artifact={art} name={name} port={port}", flush=True)
    srv = os.path.join(os.path.dirname(__file__), "_fake_server.py")
    os.execv(sys.executable, [sys.executable, srv, "--port", port, "--model", name, "--startup-delay", "2"])
    return 0


if __name__ == "__main__":
    sys.exit(main())
