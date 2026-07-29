#!/usr/bin/env python3
# Canonical implementations of the deterministic computations the codebase-scribe
# skill prompts used to describe in prose. The --help text of each subcommand is
# the definition of record: prompts reference it instead of restating the rules,
# so it must stay complete and exact.
import argparse
import difflib
import math
import os
import re
import subprocess
import sys

SKIP_DIRS = {".git", "node_modules", "vendor", "dist", "_output", "__pycache__", ".build"}
STUB_MARKER = "*Stub — will be populated"
HEADING_RE = re.compile(r"^(#{1,6})[ \t]+(.*)$")
SCAN_RE = re.compile(r"^[ \t]*scan:[ \t]*(.*)$")
SHA_RE = re.compile(r"[0-9a-f]{7,40}")

SHARED_RULES = """\
SHARED PARSING RULES (identical to the doc-validate.sh hook)

  Encoding: files are read as UTF-8 with a leading byte-order mark tolerated and
  discarded, and one trailing carriage return is stripped from every line, so a
  CRLF file parses exactly like the same file with LF endings.

  Frontmatter: when line 1 is exactly "---", every line from there through the
  next line that is exactly "---" is frontmatter; everything after that closing
  line is the "body". A file that opens a frontmatter block and never closes it
  has an empty body. A file whose line 1 is not exactly "---" is body from line
  1 onward.

  Fences: a body line that starts at column 0 with "```" or "~~~" toggles fenced
  state, and only the marker that opened a fence closes it -- a "```" line
  inside a "~~~" block is fenced content, and a "~~~" line inside a "```" block
  likewise. Fenced lines, and the fence marker lines themselves, are invisible
  to heading, section and stub-marker detection, but they still count as body
  content for the purpose of deciding whether a body is empty.

  Headings: a heading is an unfenced body line matching one to six "#"
  characters followed by at least one space or tab, then the heading text. The
  heading text is everything after that separator, with trailing whitespace
  removed; a trailing "#" closing sequence is NOT stripped.

  Slug (GitHub-flavored): lowercase the text, keep only alphanumerics (any
  Unicode alphanumeric character), spaces and hyphens, then turn every space
  into a hyphen. Runs of hyphens are NOT collapsed and leading/trailing hyphens
  are NOT trimmed, so "Patterns & Conventions" slugs to "patterns--conventions"
  -- the "&" is dropped and both spaces that surrounded it become hyphens.

EXIT CODES

  0  success
  3  operational error (file missing or unreadable, git not runnable); the
     reason is written to stderr and nothing is written to stdout.

  validate-sha additionally uses exit codes 1 and 2 to carry its verdict; see
  "scribe-lib.py validate-sha --help".
"""

SECTIONS_HELP = """\
Print the fence-aware headings of FILE, one per line, as three tab-separated
fields:

    <level><TAB><slug><TAB><heading text>

Headings inside frontmatter or inside a fenced block are not printed. Only
levels 2 and 3 are ever printed; a level-1 heading is never printed and never
resets level-3 parent scoping.

  --level 2    (default) print only "##" headings
  --level 3    print only "###" headings
  --level all  print both, in document order

A level-2 slug is the slug of its own heading text. A level-3 slug is
parent-scoped: the slug of the nearest preceding level-2 heading, then "/",
then the slug of its own heading text. A level-3 heading with no preceding
level-2 heading anywhere above it uses its own slug alone, with no "/".

The <heading text> field is the heading with the leading "#" characters and the
separating whitespace removed; it is printed verbatim otherwise, so it may
contain characters the slug drops.

A file with no qualifying headings prints nothing and exits 0.
"""

SLUG_HELP = """\
Print the GitHub-flavored slug of TEXT.

The text is lowercased; every character that is not a Unicode alphanumeric, a
space or a hyphen is dropped; every remaining space becomes a hyphen. Hyphen
runs are not collapsed and leading/trailing hyphens are not trimmed.

    scribe-lib.py slug "Patterns & Conventions"   ->  patterns--conventions
    scribe-lib.py slug "Key Entry Points"         ->  key-entry-points

TEXT is taken as a single argument, so quote it. This is the same function the
sections subcommand applies to heading text; nothing here is parent-scoped.
"""

TIER_HELP = """\
Print the maturity tier of FILE: exactly the word "stub" or the word "mature".

The tier is "stub" when EITHER of these holds:

  * the body (everything after the frontmatter block) contains zero non-blank
    lines -- a line consisting only of whitespace is blank, and a fence marker
    line is not blank, so a body that is nothing but an empty code fence is NOT
    a stub by this rule; or
  * at least one UNFENCED body line begins, at column 0, with the exact prefix
    "*Stub — will be populated" (that is an em dash, U+2014). A line that merely
    mentions the marker mid-sentence does not match, and the same marker quoted
    inside a "```" or "~~~" fence does not match either.

Otherwise the tier is "mature".
"""

VALIDATE_SHA_HELP = """\
Validate a scan SHA against the git repository in the current working directory.
Prints exactly one word on stdout and encodes the same verdict in the exit code:

    null           exit 2   SHA is the empty string or the literal text "null"
    shape          exit 1   SHA does not match ^[0-9a-f]{7,40}$ (lowercase hex,
                            7 to 40 characters, whole string; no uppercase, no
                            surrounding whitespace)
    unresolvable   exit 1   shape is fine but `git cat-file -e SHA` fails, so no
                            object with that name exists in this repository
    unreachable    exit 1   the object exists but `git merge-base --is-ancestor
                            SHA HEAD` fails, so it is not an ancestor of HEAD
    valid          exit 0   the object exists and is an ancestor of HEAD

The checks run in that order and stop at the first failure. Both git commands
run in the current working directory, so the caller chooses the repository by
choosing where it runs this. If git itself cannot be executed the command
reports the error on stderr and exits 3 instead.
"""

HUMAN_INPUT_HELP = """\
Print an integer 0-100: the percentage of FILE's fence-aware level-2 sections
that the caller named in --slugs.

    score = round( (matched / total) * 100 )

where "total" is the number of fence-aware "##" headings in FILE, and "matched"
is the number of DISTINCT values in --slugs that equal the slug of one of those
headings. Values are compared literally against the slugs, so pass slugs (as
printed by the sections or slug subcommand), not raw heading text. Duplicates in
--slugs count once; a value matching no section contributes nothing and is not
an error.

--slugs takes one comma-separated argument. Surrounding whitespace is stripped
from each value and empty values are discarded, so --slugs "" is valid and
scores 0.

When FILE has zero "##" sections the score is 0 (no division is attempted).

Rounding is half-up: an exact .5 rounds away from zero, so 1 of 8 sections
scores 13, not 12.
"""

COMPLETENESS_HELP = """\
Print an integer 0-100: the percentage of watched source subdirectories that
FILE mentions.

The population is the union of the depth-1 subdirectories of every WATCH_PATH.
A WATCH_PATH that does not exist, or that is a file rather than a directory,
contributes nothing and is not an error. Subdirectories are identified by their
path relative to the current working directory, so the same directory reached
through two WATCH_PATH spellings is counted once. Subdirectories named .git,
node_modules, vendor, dist, _output, __pycache__ or .build are excluded from
the population, and directories with those names are also skipped while
descending, so files beneath them never count as evidence.

A subdirectory is "covered" when at least one file anywhere beneath it
(recursively) has its path -- taken relative to the current working directory
and written with forward slashes -- appearing as a substring of FILE's body.
FILE's frontmatter is excluded from that search; fenced blocks are NOT excluded,
because a path cited inside a code fence is still a citation.

    score = round( (covered / total) * 100 )

When the population is empty the score is 0. Rounding is half-up.
"""

CLASSIFY_HELP = """\
Classify the change between a snapshot of a topic file and its current content.
Prints exactly one of: major_rewrite, new_draft, claim_change, section_change,
large_diff, minor_mechanical.

The rules are applied IN THIS ORDER and the first one that matches wins; no
later rule is evaluated:

  a. --snapshot S does not exist                            -> major_rewrite
  b. S is zero bytes                                        -> new_draft
     otherwise read "scan" from S's frontmatter: the first line inside the
     frontmatter block matching optional whitespace, then "scan:", then the
     value. The value is stripped of surrounding whitespace and then of one
     pair of matching surrounding quotes. A value that is empty, the literal
     "null" or the literal "~" -- and a snapshot with no frontmatter or no
     scan key at all -- counts as null      -> null gives    new_draft
  c. changed lines > 50% of FILE's total line count         -> major_rewrite
     "changed lines" is the number of insertion plus deletion lines in a
     unified diff of S against FILE (Python difflib, whole files including
     frontmatter). The rule is skipped when FILE has zero lines.
  d. --snapshot-claims and --current-claims differ          -> claim_change
     compared as line lists with trailing whitespace stripped from each line;
     blank lines are significant; a missing file reads as an empty list.
  e. FILE's fence-aware "##" heading TEXTS, in document order, differ from the
     lines of --snapshot-headings                           -> section_change
     the snapshot headings have trailing whitespace stripped and blank lines
     dropped; a missing file reads as an empty list. Heading text is compared,
     not slugs, so a reworded heading is a section change.
  f. changed lines > --threshold N                          -> large_diff
  g. none of the above                                      -> minor_mechanical

Because the order is strict, a change that alters both claims and headings is
reported as claim_change, and a snapshot with a null scan is new_draft however
small the diff is.
"""


def die(message):
    sys.stderr.write("scribe-lib: %s\n" % message)
    raise SystemExit(3)


def read_lines(path):
    try:
        with open(path, encoding="utf-8-sig") as handle:
            text = handle.read()
    except OSError as exc:
        die(str(exc))
    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    return [line[:-1] if line.endswith("\r") else line for line in lines]


def read_lines_or_empty(path):
    if not os.path.exists(path):
        return []
    return read_lines(path)


def body_lines(lines):
    if lines and lines[0] == "---":
        for index in range(1, len(lines)):
            if lines[index] == "---":
                return lines[index + 1:]
        return []
    return lines


# Yields (line, fenced) over the body. `fenced` is true for fence marker lines
# themselves as well as for their contents, which is what makes a marker
# invisible to heading detection while still counting as body content.
def scan_body(lines):
    fence = None
    for line in body_lines(lines):
        if line.startswith("```") or line.startswith("~~~"):
            mark = line[:3]
            if fence is None:
                fence = mark
            elif mark == fence:
                fence = None
            yield line, True
        else:
            yield line, fence is not None


def slug(text):
    kept = [c for c in text.lower() if c.isalnum() or c in " -"]
    return "".join(kept).replace(" ", "-")


def headings(lines):
    found = []
    parent = None
    for line, fenced in scan_body(lines):
        if fenced:
            continue
        match = HEADING_RE.match(line)
        if not match:
            continue
        level = len(match.group(1))
        text = match.group(2).rstrip()
        if level == 2:
            parent = slug(text)
            found.append((2, parent, text))
        elif level == 3:
            own = slug(text)
            found.append((3, own if parent is None else parent + "/" + own, text))
    return found


def percent(part, total):
    return int(math.floor(part * 100.0 / total + 0.5))


def changed_line_count(old, new):
    count = 0
    for line in difflib.unified_diff(old, new, lineterm=""):
        if line.startswith("+++") or line.startswith("---"):
            continue
        if line.startswith("+") or line.startswith("-"):
            count += 1
    return count


def frontmatter_scan(lines):
    if not lines or lines[0] != "---":
        return None
    for line in lines[1:]:
        if line == "---":
            return None
        match = SCAN_RE.match(line)
        if not match:
            continue
        value = match.group(1).strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1].strip()
        return None if value in ("", "null", "~") else value
    return None


def rel_posix(path):
    return os.path.relpath(path, os.getcwd()).replace(os.sep, "/")


def run_git(args):
    try:
        return subprocess.call(
            ["git"] + args,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except OSError as exc:
        die("could not run git: %s" % exc)


def cmd_sections(args):
    wanted = {"2": (2,), "3": (3,), "all": (2, 3)}[args.level]
    for level, name, text in headings(read_lines(args.file)):
        if level in wanted:
            print("%d\t%s\t%s" % (level, name, text))
    return 0


def cmd_slug(args):
    print(slug(args.text))
    return 0


def cmd_tier(args):
    nonblank = False
    marker = False
    for line, fenced in scan_body(read_lines(args.file)):
        if line.strip():
            nonblank = True
        if not fenced and line.startswith(STUB_MARKER):
            marker = True
    print("stub" if (not nonblank or marker) else "mature")
    return 0


def cmd_validate_sha(args):
    sha = args.sha
    if sha == "" or sha == "null":
        print("null")
        return 2
    if not SHA_RE.fullmatch(sha):
        print("shape")
        return 1
    if run_git(["cat-file", "-e", sha]) != 0:
        print("unresolvable")
        return 1
    if run_git(["merge-base", "--is-ancestor", sha, "HEAD"]) != 0:
        print("unreachable")
        return 1
    print("valid")
    return 0


def cmd_human_input(args):
    level2 = [h for h in headings(read_lines(args.file)) if h[0] == 2]
    if not level2:
        print(0)
        return 0
    existing = {h[1] for h in level2}
    given = {value.strip() for value in args.slugs.split(",")} - {""}
    print(percent(len(given & existing), len(level2)))
    return 0


def cmd_completeness(args):
    body = "\n".join(body_lines(read_lines(args.file)))
    subdirs = {}
    for watch in args.watch_path:
        if not os.path.isdir(watch):
            continue
        try:
            names = os.listdir(watch)
        except OSError as exc:
            die(str(exc))
        for name in names:
            if name in SKIP_DIRS:
                continue
            full = os.path.join(watch, name)
            if os.path.isdir(full):
                subdirs[rel_posix(full)] = full
    if not subdirs:
        print(0)
        return 0
    covered = 0
    for full in subdirs.values():
        if _mentions_any_file(full, body):
            covered += 1
    print(percent(covered, len(subdirs)))
    return 0


def _mentions_any_file(root, body):
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for name in filenames:
            if rel_posix(os.path.join(dirpath, name)) in body:
                return True
    return False


def cmd_classify(args):
    print(_classification(args))
    return 0


def _classification(args):
    if not os.path.exists(args.snapshot):
        return "major_rewrite"
    if os.path.getsize(args.snapshot) == 0:
        return "new_draft"

    snapshot = read_lines(args.snapshot)
    if frontmatter_scan(snapshot) is None:
        return "new_draft"

    current = read_lines(args.file)
    changed = changed_line_count(snapshot, current)
    if current and changed * 2 > len(current):
        return "major_rewrite"

    old_claims = [l.rstrip() for l in read_lines_or_empty(args.snapshot_claims)]
    new_claims = [l.rstrip() for l in read_lines_or_empty(args.current_claims)]
    if old_claims != new_claims:
        return "claim_change"

    old_headings = [l.rstrip() for l in read_lines_or_empty(args.snapshot_headings) if l.strip()]
    if [h[2] for h in headings(current) if h[0] == 2] != old_headings:
        return "section_change"

    if changed > args.threshold:
        return "large_diff"
    return "minor_mechanical"


def build_parser():
    parser = argparse.ArgumentParser(
        prog="scribe-lib.py",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        description="Deterministic helpers for the codebase-scribe skills. Each "
                    "subcommand's --help is the canonical definition of what it "
                    "computes.",
        epilog=SHARED_RULES,
    )
    sub = parser.add_subparsers(dest="command", metavar="SUBCOMMAND")
    sub.required = True

    def add(name, help_text, description):
        return sub.add_parser(
            name,
            help=help_text,
            description=description,
            formatter_class=argparse.RawDescriptionHelpFormatter,
            epilog=SHARED_RULES,
        )

    p = add("sections", "list fence-aware headings as level/slug/text", SECTIONS_HELP)
    p.add_argument("file", metavar="FILE")
    p.add_argument("--level", choices=["2", "3", "all"], default="2")
    p.set_defaults(func=cmd_sections)

    p = add("slug", "print the GitHub-flavored slug of TEXT", SLUG_HELP)
    p.add_argument("text", metavar="TEXT")
    p.set_defaults(func=cmd_slug)

    p = add("tier", "print stub or mature for a topic file", TIER_HELP)
    p.add_argument("file", metavar="FILE")
    p.set_defaults(func=cmd_tier)

    p = add("validate-sha", "check a scan SHA against the repo in CWD", VALIDATE_SHA_HELP)
    p.add_argument("sha", metavar="SHA")
    p.set_defaults(func=cmd_validate_sha)

    p = add("human-input", "score SME-touched sections 0-100", HUMAN_INPUT_HELP)
    p.add_argument("file", metavar="FILE")
    p.add_argument("--slugs", required=True, metavar="CSV")
    p.set_defaults(func=cmd_human_input)

    p = add("completeness", "score watched subdirectory coverage 0-100", COMPLETENESS_HELP)
    p.add_argument("file", metavar="FILE")
    p.add_argument("watch_path", metavar="WATCH_PATH", nargs="+")
    p.set_defaults(func=cmd_completeness)

    p = add("classify", "classify the change between a snapshot and FILE", CLASSIFY_HELP)
    p.add_argument("file", metavar="FILE")
    p.add_argument("--snapshot", required=True, metavar="S")
    p.add_argument("--snapshot-claims", required=True, metavar="SC")
    p.add_argument("--current-claims", required=True, metavar="CC")
    p.add_argument("--snapshot-headings", required=True, metavar="SH")
    p.add_argument("--threshold", required=True, type=int, metavar="N")
    p.set_defaults(func=cmd_classify)

    return parser


def main():
    # Callers capture stdout from bash on Windows, where the default text layer
    # would emit CRLF (poisoning "$(...)" captures) and encode with the console
    # codepage (raising UnicodeEncodeError on a non-ASCII heading).
    sys.stdout.reconfigure(encoding="utf-8", newline="\n")
    args = build_parser().parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
