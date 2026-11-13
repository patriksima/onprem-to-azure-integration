"""Fail if two module calls use the same deployment name.

Nested deployments share one namespace per resource group, so `module x { name: 'sql' }` in main.bicep and
`module y { name: 'sql' }` inside modules/sql.bicep overwrite each other at deploy time. Neither `bicep build`
nor `bicep lint` catches it, so this check does.
"""
import collections, glob, re, sys

pattern = re.compile(
    r"^module\s+(\w+)\s+'[^']+'\s*=\s*(?:\[[^\]]*\]|if\s*\([^)]*\))?\s*\{\s*\n\s*name:\s*([^\n]+)",
    re.M | re.S,
)
seen = collections.defaultdict(list)
for path in ["infra/main.bicep", *sorted(glob.glob("infra/modules/*.bicep"))]:
    for match in pattern.finditer(open(path, encoding="utf-8").read()):
        seen[match.group(2).strip()].append(f"{path}:{match.group(1)}")

collisions = {name: users for name, users in seen.items() if len(users) > 1}
for name, users in collisions.items():
    print(f"::error::Deployment name {name} is used by {', '.join(users)}")
print(f"{len(seen)} deployment names checked, {len(collisions)} collision(s)")
sys.exit(1 if collisions else 0)
