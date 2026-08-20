#!/usr/bin/env python3
"""A regression suite for HEARING, built from Yoni's own reported errors.

THE GAP THIS CLOSES. Every automated test in this project checks that cleanup
does not change his words. None of them check whether the engine HEARD him —
and every real complaint he has had is the second kind: "rented" heard as
"wrench", "or all" as "All", "branch" as "bridge", "intervene" as "interven
results". Those corrections were being said once in conversation and then lost.

Now each one becomes a permanent case: the actual audio, plus what he actually
said. Any change — a bigger model, biasing on, a vocabulary entry — can be
scored against the errors that really happened to him, instead of against
sentences somebody invented.

  Scripts/truth.py add <audio.caf> "what I actually said"
  Scripts/truth.py list
  Scripts/truth.py check [--model VARIANT] [--bias]

Stored outside the repo: it is verbatim speech.
"""
import json, os, subprocess, sys, argparse, shutil

STORE = os.path.expanduser("~/Library/Application Support/VoiceFlow/voice-truth")
INDEX = os.path.join(STORE, "index.jsonl")
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
B,G,Y,R,D,O = "\033[1m","\033[32m","\033[33m","\033[31m","\033[2m","\033[0m"

def norm(t):
    import re
    return re.sub(r"\s+"," ", re.sub(r"[^\w\s']"," ", (t or "").lower())).strip()

def load():
    if not os.path.exists(INDEX): return []
    return [json.loads(l) for l in open(INDEX) if l.strip()]

def add(audio, said):
    os.makedirs(STORE, exist_ok=True)
    if not os.path.exists(audio): sys.exit(f"no such audio: {audio}")
    name = os.path.basename(audio)
    kept = os.path.join(STORE, name)
    if os.path.abspath(audio) != os.path.abspath(kept): shutil.copy2(audio, kept)
    with open(INDEX, "a") as f:
        f.write(json.dumps({"audio": name, "said": said}, ensure_ascii=False) + "\n")
    print(f"recorded: {name}\n  truth: {said}")

def check(model, bias):
    cases = load()
    if not cases: sys.exit("no truth cases yet — add one with 'truth.py add'")
    cmd = ["swift","run","-c","release","--package-path",ROOT,"VoiceFlowBench",
           "--audio"] + [os.path.join(STORE, c["audio"]) for c in cases]
    if model: cmd += ["--model", model]
    if bias:
        ents = [l.strip() for l in open(os.path.join(ROOT,"docs","wer-entities.txt")) if l.strip()]
        cmd += ["--bias"] + ents + ["-whisperPromptBiasingEnabled","YES"]
    out = subprocess.run(cmd, capture_output=True, text=True)
    heard = [l for l in out.stdout.split("\n") if l.strip() != ""]
    # The bench sorts by filename; match that ordering.
    order = sorted(range(len(cases)), key=lambda i: cases[i]["audio"])
    if len(heard) != len(cases):
        sys.exit(f"expected {len(cases)} transcripts, got {len(heard)} — cannot pair safely")
    label = model or "current model"
    if bias: label += " + biasing"
    print(f"\n{B}Your own reported errors, re-tested against {label}{O}\n")
    fixed = broken = 0
    for slot, idx in enumerate(order):
        c = cases[idx]
        got, want = heard[slot], c["said"]
        ok = norm(got) == norm(want)
        if ok: fixed += 1
        else: broken += 1
        print(f"  {(G+'RIGHT'+O) if ok else (R+'WRONG'+O)}")
        print(f"    you said : {want}")
        print(f"    it heard : {got}\n")
    print(f"{B}{fixed} of {len(cases)} now correct.{O}")
    if broken: print(f"{D}The wrong ones are the real backlog — not invented test cases.{O}")
    print()

if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd")
    a = sub.add_parser("add"); a.add_argument("audio"); a.add_argument("said")
    sub.add_parser("list")
    c = sub.add_parser("check"); c.add_argument("--model"); c.add_argument("--bias", action="store_true")
    args = ap.parse_args()
    if args.cmd == "add": add(args.audio, args.said)
    elif args.cmd == "list":
        for c in load(): print(f"  {c['audio']}\n    {c['said']}")
    elif args.cmd == "check": check(args.model, args.bias)
    else: ap.print_help()
