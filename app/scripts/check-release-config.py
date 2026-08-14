#!/usr/bin/env python3
"""Validate-time release-config consistency check.

Asserts a deploy target's auth configuration cannot be internally inconsistent.
Reads the *rendered* bundle (`databricks bundle validate -t <target> -o json`),
so it sees the real resolved values the deploy would use — including the
`app_user_api_scopes` *list*, which cannot be threaded into the
contract_assertions notebook (DAB will not serialize a complex variable into a
string base_parameter). The notebook covers the scalar-only invariants (#2, #4)
as an always-run pipeline gate; this script is the complete four-invariant gate —
run it before deploying a release.

Invariants:
  #1  app_auth_mode == "obo"  iff  app_user_api_scopes is non-empty
  #2  obo mode                =>  viewer_grantee is non-empty
  #3  sp mode                 =>  app_user_api_scopes is empty
  #4  target "internal"       =>  app_auth_mode == "obo"
  #5  apply_data_asset_tags == "true"  iff  data_asset_tags is non-empty

It also cross-checks that the app resource's rendered `user_api_scopes` equals
the `app_user_api_scopes` variable value (guards a future mis-wire of the field).

Usage:
  python3 app/scripts/check-release-config.py                 # checks external + internal + dev
  python3 app/scripts/check-release-config.py external internal dev
  DATABRICKS_PROFILE=myprofile python3 app/scripts/check-release-config.py internal
"""
import json
import os
import subprocess
import sys

DEFAULT_TARGETS = ["external", "internal", "dev"]


def render(target: str, profile: str) -> dict:
    """Return the rendered bundle JSON for a target, or exit on failure."""
    proc = subprocess.run(
        ["databricks", "bundle", "validate", "-t", target, "--profile", profile, "-o", "json"],
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        sys.stderr.write(f"bundle validate -t {target} failed:\n{proc.stderr}\n")
        sys.exit(2)
    return json.loads(proc.stdout)


def var(d: dict, name: str):
    return d.get("variables", {}).get(name, {}).get("value")


def check_target(target: str, profile: str) -> list:
    """Return a list of failure strings (empty = all invariants hold)."""
    d = render(target, profile)
    mode = (var(d, "app_auth_mode") or "").strip().lower()
    scopes = var(d, "app_user_api_scopes") or []
    grantee = (var(d, "viewer_grantee") or "").strip()
    apply_tags = (var(d, "apply_data_asset_tags") or "").strip().lower()
    data_tags = var(d, "data_asset_tags") or {}
    rendered_app_scopes = (
        d.get("resources", {}).get("apps", {}).get("customer_360", {}).get("user_api_scopes")
    )

    non_empty = len(scopes) > 0
    fails = []

    # #1 — mode and scopes must agree.
    if (mode == "obo") != non_empty:
        fails.append(
            f"#1 mode/scopes disagree: app_auth_mode={mode!r} but "
            f"app_user_api_scopes={scopes!r} (obo iff non-empty)"
        )
    # #2 — obo requires a grantee.
    if mode == "obo" and not grantee:
        fails.append(f"#2 obo mode with empty viewer_grantee")
    # #3 — sp forbids scopes.
    if mode == "sp" and non_empty:
        fails.append(f"#3 sp mode with non-empty scopes {scopes!r}")
    # #4 — internal is obo by policy.
    if target == "internal" and mode != "obo":
        fails.append(f"#4 target 'internal' must be obo (got {mode!r})")
    # #5 — the scalar tag flag (threaded into the tagging notebooks) must agree
    #      with the declarative data_asset_tags map (used by the resource tags:
    #      fields). They are two encodings of one intent; drift would tag data
    #      assets the governed workspace rejects, or skip tags where they belong.
    if (apply_tags == "true") != (len(data_tags) > 0):
        fails.append(
            f"#5 apply_data_asset_tags={apply_tags!r} disagrees with "
            f"data_asset_tags={data_tags!r} (true iff non-empty)"
        )
    # cross-check the field is actually wired to the variable.
    if rendered_app_scopes is not None and list(rendered_app_scopes) != list(scopes):
        fails.append(
            f"app.user_api_scopes ({rendered_app_scopes!r}) != var app_user_api_scopes ({scopes!r})"
        )

    return fails


def main() -> int:
    targets = sys.argv[1:] or DEFAULT_TARGETS
    profile = os.environ.get("DATABRICKS_PROFILE", "DEFAULT")
    any_fail = False
    for target in targets:
        fails = check_target(target, profile)
        if fails:
            any_fail = True
            print(f"FAIL  {target}")
            for f in fails:
                print(f"        {f}")
        else:
            print(f"PASS  {target}")
    if any_fail:
        print("\nRelease-config check FAILED.")
        return 1
    print("\nAll release-config invariants hold.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
