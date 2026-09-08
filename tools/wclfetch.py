#!/usr/bin/env python3
"""tools/wclfetch.py <report> <fightID> [--host fresh]

Pulls one fight out of Warcraft Logs and writes the RAW event streams to
.logs/wcl/<report>-<fight>.json. Nothing is interpreted here -- this file only
downloads, so that a conversion bug can be re-run without spending API points.

Credentials come from .logs/wcl.json (gitignored); the bearer token is cached in
.logs/wcl.token and refreshed when it expires.

NOTE on classResources: the key names in these logs do NOT mean what they say.
Verified against three actors and four TBC spells whose costs are known:
    amount -> the actor's MAX mana        (constant all fight)
    type   -> the actor's CURRENT mana     (tracks like a mana bar)
    max    -> the CAST's mana cost         (Rejuv R13 415, Lifebloom 220, ...)
Read them at face value and every mana number downstream is silently wrong.
"""
import base64, json, os, subprocess, sys, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CREDS = os.path.join(ROOT, ".logs", "wcl.json")
TOKEN = os.path.join(ROOT, ".logs", "wcl.token")


def _curl(args, timeout=90):
    r = subprocess.run(["curl", "-s", "--max-time", str(timeout)] + args,
                       capture_output=True, text=True)
    if r.returncode != 0:
        raise SystemExit("curl failed: " + r.stderr[:300])
    return r.stdout


def token(force=False):
    if not force and os.path.exists(TOKEN):
        tok = open(TOKEN).read().strip()
        if tok:
            return tok
    c = json.load(open(CREDS))
    out = _curl(["-X", "POST", c["token_url"],
                 "-u", "%s:%s" % (c["client_id"], c["client_secret"]),
                 "-d", "grant_type=client_credentials"])
    d = json.loads(out)
    if "access_token" not in d:
        raise SystemExit("token refused: " + json.dumps(d)[:300])
    open(TOKEN, "w").write(d["access_token"])
    os.chmod(TOKEN, 0o600)
    return d["access_token"]


def gql(query, host="fresh", _retry=True):
    out = _curl(["-H", "Authorization: Bearer " + token(),
                 "-H", "Content-Type: application/json", "-X", "POST",
                 "https://%s.warcraftlogs.com/api/v2/client" % host,
                 "-d", json.dumps({"query": query})])
    try:
        d = json.loads(out)
    except json.JSONDecodeError:
        if _retry and ("Unauthenticated" in out or "401" in out[:80]):
            token(force=True)
            return gql(query, host, False)
        raise SystemExit("bad response: " + out[:300])
    if "errors" in d:
        msg = json.dumps(d["errors"])[:400]
        if _retry and "authenticat" in msg.lower():
            token(force=True)
            return gql(query, host, False)
        raise SystemExit("GraphQL: " + msg)
    return d["data"]


def events(code, fight, data_type, host, extra=""):
    """Every page of one event stream for one fight."""
    out, cursor = [], None
    while True:
        start = "" if cursor is None else ", startTime: %d" % cursor
        d = gql('{ reportData { report(code: "%s") { events(fightIDs: [%d], '
                'dataType: %s, limit: 10000, includeResources: true%s%s) '
                '{ data nextPageTimestamp } } } }'
                % (code, fight, data_type, extra, start), host)
        ev = d["reportData"]["report"]["events"]
        out.extend(ev["data"])
        cursor = ev.get("nextPageTimestamp")
        if not cursor:
            return out


def main():
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    code, fight = sys.argv[1], int(sys.argv[2])
    host = "fresh"
    if "--host" in sys.argv:
        host = sys.argv[sys.argv.index("--host") + 1]

    meta = gql('{ reportData { report(code: "%s") { title startTime owner { name } '
               'region { slug } '
               'fights(fightIDs: [%d]) { id name encounterID startTime endTime kill '
               'friendlyPlayers difficulty size } '
               'masterData { actors { id name type subType server } '
               'abilities { gameID name type } } } } }' % (code, fight), host)
    rep = meta["reportData"]["report"]
    if not rep["fights"]:
        raise SystemExit("no fight %d in %s" % (fight, code))

    blob = {"code": code, "fightID": fight, "host": host,
            "title": rep["title"], "reportStart": rep["startTime"],
            "owner": (rep["owner"] or {}).get("name"),
            "fight": rep["fights"][0],
            "actors": rep["masterData"]["actors"],
            "abilities": rep["masterData"]["abilities"]}

    for name, dt in (("damage", "DamageTaken"), ("healing", "Healing"),
                     ("casts", "Casts"), ("deaths", "Deaths"),
                     ("resources", "Resources")):
        ev = events(code, fight, dt, host)
        blob[name] = ev
        print("  %-10s %6d events" % (name, len(ev)), flush=True)

    path = os.path.join(ROOT, ".logs", "wcl", "%s-%d.json" % (code, fight))
    json.dump(blob, open(path, "w"))
    print("wrote %s (%.1f MB)" % (path, os.path.getsize(path) / 1e6))


if __name__ == "__main__":
    main()
