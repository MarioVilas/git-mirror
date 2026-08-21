# git-mirror

A small Bash script that keeps a library of third-party git repositories up to
date, for offline research and reference.

You clone whatever repositories you care about into a directory of your
choosing, in whatever structure you like. `pull.sh` walks that directory and
brings every repository it finds back in line with its origin — all branches,
all tags, full history — reporting exactly what it did to each one.

It was written to maintain a reference archive: a local copy of upstream
projects that can be searched, diffed and read without network access. A
concrete example of the kind of question it exists to answer: *"how did the
JSON output of `testssl.sh` change across every published release?"* — which
needs every tag of that project sitting on local disk.

## The one rule that explains everything

> **Respect how a repository was created. Disregard whatever has since been
> written into it.**

These repositories are **mirrors, not workspaces**. The script assumes you do
not author changes in them and have no push access to their origins. So:

- **Topology is preserved.** How you cloned a repository — shallow, single
  branch, partial, bare — is a deliberate decision. The script detects it,
  keeps it, and reports it on every run. It will never "upgrade" a shallow
  clone to a full one behind your back.
- **Content drift is destroyed.** Local commits, uncommitted modifications and
  branches that do not exist upstream are discarded, because in a mirror they
  can only be the result of something writing where it should not have. They
  are reported loudly rather than silently swallowed, so you find out that it
  happened.

If you want a repository you can edit, do not put it in this library.

## Quick start

```sh
./pull.sh              # update every repository below this script's directory
./pull.sh -n           # dry run: show what would be touched, change nothing
./pull.sh -j 8         # eight repositories in parallel (default 4)
./pull.sh -q           # only anomalies, failures and the summary
./pull.sh security     # restrict to one subtree
./pull.sh -h           # help
```

With no argument, the root is **the directory containing `pull.sh`**. Any
directory layout works; the script finds repositories by searching, not by
convention. The layout this was built for looks like:

```
ref/
├── pull.sh          # update every mirror
├── export.sh        # write a manifest of what is here
├── common.sh        # discovery and shape detection, shared by both
├── security/
│   ├── testssl.sh/
│   └── wpscan/
├── web_servers/
│   ├── nginx/
│   └── httpd/
└── operating_systems/
    └── linux/
```

## What it reports

```
ok       security/wpscan  [full]
updated  security/testssl.sh  [full]  c25a0ad..1283aff
updated  operating_systems/linux  [shallow single-branch]  9f2ac41..be1d7c3
ok       archive/netscape.git  [bare]
skipped  security/badssl.com  (another git process is running here)
skipped  documentation/unpacked-tarball  (not a git repository)
failed   docs/broken
!  security/testssl.sh  discarded 2 local commit(s)
82 repos: 3 updated, 78 up to date, 1 skipped, 0 failed; 1 other directory skipped
```

| Prefix | Meaning |
|---|---|
| `ok` | Already current; nothing changed |
| `updated` | Advanced, with the old and new commit shown |
| `skipped` | Deliberately left alone this run, with the reason |
| `failed` | Something went wrong; git's own output follows on stderr |
| `!` | **Anomaly** — something was found that a mirror should not contain, and was discarded |

The bracketed field is the clone's shape. Exit status is `0` unless at least
one repository failed; skips are not failures. Output is buffered per
repository and printed in discovery order, so parallel runs never interleave.

## How it works

For each repository with a working tree:

1. **Fetch** — `git fetch --prune --prune-tags --tags origin`, using the
   clone's own configured refspec. Brings in every branch it tracks and every
   tag, and drops refs deleted upstream.
2. **Mirror local branches** — local branches are force-updated to their
   upstream counterparts. The refspecs are *derived from what the clone
   tracks*, so a single-branch clone never has extra branches conjured into
   existence.
3. **Decide which branch to sit on** — the current one if it still exists
   upstream; otherwise origin's default branch. This recovers a detached HEAD,
   a branch deleted upstream, and an upstream default-branch rename.
4. **Report anomalies** — local commits, uncommitted changes, local-only
   branches.
5. **Reset** — `git reset --hard origin/<branch>`, discarding whatever drift
   was reported.

For a **bare** repository the whole job is the fetch. There is no working tree,
so there is no reset, no HEAD repair and no anomaly checking — a bare mirror's
`refs/heads/*` are the mirror itself, not rogue local branches.

## Clone shapes

Detected automatically and reported in brackets:

| Shape | Meaning |
|---|---|
| `full` | Ordinary clone: all branches, all tags, complete history |
| `shallow` | Truncated history (`--depth`). Kept shallow; never unshallowed |
| `single-branch` | Tracks one branch (`--single-branch`, implied by `--depth`) |
| `partial` | Blobs fetched on demand (`--filter=blob:none`) |
| `bare` | No working tree (`--bare`, `--mirror`) |
| `no-remote` | No `origin` configured — will fail |

Shapes combine: `--depth 1` normally reports `shallow single-branch`.

## What is left alone

- **Untracked files** are preserved — *unless* upstream has a file at the same
  path, in which case the reset overwrites it. `git reset --hard` clobbers a
  conflicting untracked file without complaint, which is precisely the
  behaviour wanted here.
- **The root directory itself**, even when it is a git repository. The script
  lives in a repo of its own; that repo is never treated as a mirror.
- **Repositories busy with another git process** — a lock file, a pack being
  received, or a HEAD that does not resolve (an unfinished clone). These are
  skipped, because a half-applied update is worse than none: an `index.lock`
  does not stop a `fetch`, so without this guard a busy repository would get
  its refs moved and then fail on the reset.
- **Directories that are not repositories** — reported as `skipped` so that a
  repository which loses its `.git` cannot silently drop out of the sweep.
- **Anything inside a repository.** Discovery stops at each repository rather
  than descending through its working tree. A clone sitting inside another
  repo's checkout is that repo's content, not a mirror of its own — and it
  means a project whose test suite ships `.git` fixtures (git itself, among
  others) cannot produce dozens of bogus repositories. It is also what makes
  the scan fast: descending meant visiting ~190,000 directories to find
  nothing.

## Exporting a manifest

`export.sh` writes a tab-separated inventory of the library to stdout. It is
strictly read-only.

```sh
./export.sh > mirrors.tsv
./export.sh security          # just one subtree
```

**Exactly one ROOT may be given.** `./export.sh */` is an error, not a silent
export of whichever directory the glob happened to list last — pass their
common parent instead. `pull.sh` behaves the same way.

Both scripts print progress to **stderr when it is a terminal**, so you can see
that they are alive; when output is redirected or piped, stderr stays empty and
the manifest is the only thing produced.

```
# path	url	shape	branch	depth	filter
security/testssl.sh	https://github.com/testssl/testssl.sh	full
operating_systems/linux	https://github.com/torvalds/linux	shallow single-branch	master	1
archive/netscape.git	https://example.org/netscape.git	bare
```

The manifest records **shape as well as origin**, because recreating a
deliberately shallow mirror as a full clone would silently change what the
library contains. `branch` is filled in for single-branch clones, `depth` for
shallow ones, `filter` for partial ones.

Rows are sorted by path and there is **no timestamp**, so re-exporting an
unchanged library produces a byte-identical file — the manifest can be
committed and its diffs mean something.

A repository that cannot be represented — no `origin`, or a path containing a
tab or newline — is reported on stderr, left out, and makes the exit status
non-zero, so a partial manifest is never mistaken for a complete one.

### Why TSV

Because it needs no escaping. `IFS=$'\t' read -r path url shape` is a complete
and *correct* parser, whereas naive CSV parsing in shell silently corrupts any
field containing a comma — truncating the URL and shifting every column after
it. JSON and YAML are worse still: neither can be parsed in Bash without a
dependency such as `jq`.

The trade is that a field cannot contain a tab or newline. That is why export
refuses such a repository rather than writing a corrupt row.

Nothing is lost in convertibility — spreadsheets import TSV directly, and
standard tools handle the rest:

```sh
# TSV -> CSV (quoting only the fields that need it)
awk -F'\t' 'BEGIN{OFS=","} {for(i=1;i<=NF;i++) if($i ~ /[",]/) {gsub(/"/,"\"\"",$i); $i="\"" $i "\""} print}' mirrors.tsv

# TSV -> JSON
awk -F'\t' 'BEGIN{print "["} !/^#/{printf "%s  {\"path\":\"%s\",\"url\":\"%s\",\"shape\":\"%s\"}", (n++?",\n":""), $1,$2,$3} END{print "\n]"}' mirrors.tsv
```

## Assumptions

1. The remote is called **`origin`**. A repository cloned with `-o something`
   will fail loudly.
2. You do not commit work in these repositories, and cannot push to their
   origins.
3. Authentication is non-interactive. Anything prompting for a password will
   hang; use SSH keys, a credential helper, or public HTTPS URLs.
4. Every repository below the root is a mirror. **The script does not
   distinguish your own projects from mirrors** — see the next section.
5. GNU `find` (uses `-printf`), `git` ≥ 2.29 (negative refspecs), Bash ≥ 4.3
   (`wait -n`). Developed on Linux with git 2.43 and Bash 5.2.
6. **The scripts are not standalone.** `pull.sh` and `export.sh` both source
   `common.sh` from their own directory; keep the files together. Each exits
   with a clear error if it cannot find it.

## Limitations

- **Submodules are not handled.** A repository containing submodules is
  mirrored, but its submodule *contents* are not: you get the gitlink, not the
  code. Nothing is corrupted, the archive is just incomplete for that project.
- **Shallow and partial clones are, by design, incomplete.** See below.
- There is no import command yet: `export.sh` records what you have, but
  recreating a library elsewhere from a manifest is still manual. You create
  the repositories yourself with `git clone`.
- **The manifest records repositories, not the library.** A TSV is one row per
  repository, so there is nowhere to put anything that is not a per-repository
  field: the directory structure you chose, and any notes you keep about what
  the repositories are and why you cloned them. Restoring from `mirrors.tsv`
  gets the code back and loses the filing system. *TODO: an export mode that
  writes an archive — the manifest plus each directory's `README.md`, paths
  intact — so a library can be moved or backed up whole. Deliberately not the
  default: the flat TSV is the thing you commit and diff.*

## Welp, I shot myself in the foot

Ways to hurt yourself, in rough order of likelihood.

### Pointing it at a directory that contains your own work

This is the big one. **Every repository below the root is treated as a
disposable mirror.** Run it over a directory holding a project you are actually
working on and that project will be hard-reset to `origin`: local commits gone,
uncommitted changes gone.

The root itself is protected, but nothing *below* it is. So this is safe:

```sh
cd ~/ref && ./pull.sh          # ~/ref is the root, and is skipped
```

and this is not:

```sh
./pull.sh ~                    # every project in your home directory is a "mirror"
```

**Use `-n` first whenever you point it somewhere new.** The dry run lists every
repository it would touch and changes nothing.

### Cloning shallow to save time, then relying on history

`git clone --depth 1` is tempting for something like the Linux kernel. The
result is reported as `[shallow]` and stays that way forever — the script will
not silently unshallow it. Tag *contents* usually remain readable, because
fetching tags drags their commits in, but the connecting history does not
exist: `git log v1.0..v2.0` will quietly show far less than it should, and
blame and bisect are unreliable.

If you want a research archive, clone in full. If you deliberately want a
cheap, shallow mirror, that is respected — just know which one you have. The
shape in the report tells you.

### Using `--filter=blob:none` for a big repository

A partial clone reports `[partial]` and keeps working, but file contents are
fetched from the remote *on demand*. The archive is therefore not
self-contained: it behaves fine while you are online and stalls or fails when
you are not. For an offline reference library this usually defeats the purpose.

### Assuming a deliberate checkout will survive

If you `git checkout v3.2rc4` in a mirror to inspect an old release and walk
away, the next run re-attaches HEAD to the default branch and moves it to the
tip. That is intentional — a detached HEAD is far more often an accident than a
decision — but it does mean a mirror is not a place to park a checkout.

Worse, if you *commit* while detached, that commit belongs to no branch. It is
reported (`discarded N local commit(s)`) and then unreferenced. It remains
recoverable from `git reflog` or `git fsck --unreachable` until git's garbage
collector expires it, typically 30 days — so if you see that line and it
matters, act promptly.

### Expecting `git clone --mirror` to be the obvious choice

The project is called git-mirror, so reaching for `git clone --mirror` is
natural. It works and is supported — but a `--mirror` clone is **bare**, with
no working tree, so you cannot read or grep the files. For a reference library
you almost certainly want an ordinary clone.

### Losing an untracked file

Untracked files are normally preserved. But if upstream adds a file at the same
path as one of yours, yours is overwritten without warning. Do not keep notes
inside a mirror; keep them somewhere the script does not manage.

## Tests

```sh
./pull_test.sh                   # pull.sh
./export_test.sh                 # export.sh
FILTER=shallow ./pull_test.sh    # only tests whose name contains "shallow"
```

Both suites build throwaway fixtures — bare "upstream" repositories plus clones
of every supported shape — under `$TMPDIR`, sharing `test_common.sh`. They
never touch a real repository. Every behaviour documented above has a test,
including the destructive ones.

One test is worth knowing about: `never_operates_on_the_current_directory`. An
early version emitted an empty path for a library containing no worktree repos,
and `git -C ""` silently means *the current directory* — so `pull.sh` hard-reset
whatever repository you happened to be standing in. That test exists so it
cannot come back.

## License

MIT. See `LICENSE`.
