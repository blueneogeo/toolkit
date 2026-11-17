# /// script
# dependencies = ["pyjwt[crypto]", "requests"]
# ///
"""Read-only: list the team's bundle ids, their capabilities and profiles."""
import sys, time, jwt, requests

key_id, issuer, key_path = sys.argv[1:4]
prefixes = sys.argv[4:]
token = jwt.encode(
    {"iss": issuer, "iat": int(time.time()), "exp": int(time.time()) + 600, "aud": "appstoreconnect-v1"},
    open(key_path).read(), algorithm="ES256", headers={"kid": key_id},
)
api = requests.Session()
api.headers["Authorization"] = f"Bearer {token}"
base = "https://api.appstoreconnect.apple.com/v1"

def get(path, **params):
    r = api.get(base + path, params=params)
    r.raise_for_status()
    return r.json()

bundles = get("/bundleIds", limit=200)["data"]
for b in sorted(bundles, key=lambda b: b["attributes"]["identifier"]):
    ident = b["attributes"]["identifier"]
    if prefixes and not any(ident.startswith(p) for p in prefixes):
        continue
    caps = get(f"/bundleIds/{b['id']}/bundleIdCapabilities")["data"]
    names = sorted(c["attributes"]["capabilityType"] for c in caps)
    print(f"{ident}  ({b['attributes']['name']})")
    print("  capabilities: " + ", ".join(names))
    for c in caps:
        settings = c["attributes"].get("settings") or []
        for s in settings:
            opts = [o.get("key") for o in s.get("options") or [] if o.get("enabled")]
            if opts:
                print(f"    {c['attributes']['capabilityType']} {s.get('key')}: {', '.join(opts)}")
    profiles = get(f"/bundleIds/{b['id']}/profiles")["data"]
    for p in profiles:
        a = p["attributes"]
        print(f"  profile: {a['name']}  {a['profileType']}  {a['profileState']}  expires {a['expirationDate'][:10]}")
