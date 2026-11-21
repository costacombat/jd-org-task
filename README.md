# jd-org-task

Tools for running a [Johnny.Decimal](https://johnnydecimal.com) system
whose JDex is one plain Org file. Both leave the file as ordinary Org, so
your own Emacs, phone apps and Org packages read it as usual.

| Tool | For | Where |
| --- | --- | --- |
| [`ot`](#ot) | adding, listing and filing tasks from the shell, through a small Emacs | `bin/ot`, `lisp/ot.el` |
| [`jd-org`](#jd-org) | creating IDs and work packages and moving files from inside Emacs, through jd-nnn's `jd` | `jd-org.el` |

## ot

Org tasks from the shell. `ot` adds, lists and changes TODO headings in an
Org file through a small Emacs, so the file stays plain Org that your own
Emacs, phone apps and other tools read as usual.

```console
$ ot add Renew it --under 11.11 --due fri
97c0ac26  TODO   <2026-11-20 Fri>  11.11       Renew it
$ ot add Book flights --under W0011 --state NEXT
$ ot ls
97c0ac26  TODO   <2026-11-20 Fri>  11.11       Renew it
51b0cce4  NEXT                     W0011       Book flights
$ ot done 97c0
$ ot ls --json | jq '.[].title'
"Book flights"
```

It was made for a [Johnny.Decimal](https://johnnydecimal.com) JDex kept in
Org, so `--under` takes a heading's number, but it works on any Org file.

### Commands

| Command | What it does |
| --- | --- |
| `ot add TITLE... [--in WHERE \| --under ID] [--due WHEN] [--state STATE]` | add a task to an inbox, or file it under a heading |
| `ot ls [--under ID] [--state STATE] [--all]` | list open tasks (or one state, or all) |
| `ot inbox [WHERE]` | what's waiting in the inboxes, broadest first |
| `ot move TASK --in WHERE \| --under ID` | move a task to an inbox, or file it |
| `ot set TASK STATE` | change a task's state |
| `ot done TASK` | mark it done |
| `ot where TASK` | print `FILE:LINE` |
| `ot open TASK` | open it in your editor (`$OT_EDITOR`, else `emacsclient -n`) |
| `ot daemon` / `ot stop` | run ot's Emacs in the foreground / stop it |

`--file FILE` and `--json` work with any command.

- **`ID`** names a heading by its `CUSTOM_ID`, or by the number its title
  starts with. For example, use `11.11` for an ID, or `W0011` for a work
  package. `W0011~11.11` also checks that the work package belongs to 11.11.
- **`TASK`** is the start of a task's id, as `ot ls` prints it. Each task
  gets an Org `ID` property (a UUID) when it's added, so its id doesn't
  change when you edit or move it.
- **`WHEN`** is anything Org's date prompt reads, such as `fri`, `+2w` or
  `2026-12-01`.
- **States** are the file's own `#+TODO:` line. Without one, `ot` uses
  `TODO NEXT WAIT | DONE CANCELLED`. Add that line to the file so your own
  Emacs agrees:

  ```org
  #+TODO: TODO NEXT WAIT | DONE CANCELLED
  ```

### Inboxes

Every level of a Johnny.Decimal system has an inbox, and a task goes to
the narrowest one that fits. The system, area and category ones are the
standard zeros. IDs and work packages have no slot below them, so theirs
use extend-the-end: a `+ Inbox` sibling, made on first use.

| `--in` | Inbox | In the Org file |
| --- | --- | --- |
| `system` (or `00`) | `00.01` | the system's inbox |
| `10-19` | `10.01` | the area's, in its management category |
| `11` | `11.01` | the category's |
| `11.11` | `11.11+ Inbox` | a heading right after `11.11 …` |
| `W0011` | `W0011+ Inbox` | a heading right after the work package |

```org
*** 11.11 Passport
*** 11.11+ Inbox
:PROPERTIES:
:CUSTOM_ID: 11.11+Inbox
:END:
**** TODO Ask about the photo size
```

Some rules:

- A work package with a `+` sibling takes the space form. The first time
  `W0011~11.11 Trip` gets an inbox, `ot` renames it to `W0011 11.11 Trip`.
- With `OT_ROOT` set to the system's root folder, `ot` does the same on
  disk: it makes `11.11+ Inbox/` next to `11.11 Passport/`, and renames the
  work package's folder.
- With no `--in` or `--under`, `ot add` uses the inbox for the folder
  you're in. Inside `11 Me/11.11 Passport` that's 11.11's, and inside
  `11 Me` it's 11.01. Otherwise it uses `$OT_INBOX`, else `00.01`, else a
  plain `* Inbox` heading for files that aren't a JDex. `OT_CONTEXT=0`
  turns the folder rule off.
- `ot inbox 11` lists category 11's inboxes and everything below them,
  including the work packages filed under 11's IDs. `ot inbox` with no
  argument lists every inbox.
- `ot move TASK --under 11.11` files a task out of its inbox (Org's
  refile), and `--in` moves it to a narrower inbox. The task keeps its id.

### How it runs

Each command runs a small Emacs started with `-Q`, which loads Org and
`ot.el` but never your own config. `ot` tries these in order:

1. **A daemon on `$OT_SOCKET`** (named `ot` by default). If none is running,
   `ot` starts one, and it keeps running after that. Each command then
   takes a few milliseconds, and the daemon uses about 70 MB of memory.
2. **`emacs -Q --batch`**, if no daemon can be used, or if `OT_DAEMON=0` is
   set. This takes about 0.3 s per command.

The daemon reloads the file whenever it changed on disk and saves after
every change, so it's safe to edit the same file in your own Emacs.

| Variable | Default | Meaning |
| --- | --- | --- |
| `OT_FILE` | `~/org/tasks.org` | the Org file |
| `OT_INBOX` | | the default inbox when the folder gives none: a `--in` value, or a heading's title |
| `OT_CONTEXT` | `1` | `0` to not pick the inbox from the current folder |
| `OT_ROOT` | | the Johnny.Decimal root on disk, so `+ Inbox` folders are made and work packages renamed there too |
| `OT_SOCKET` | `ot` | the daemon's socket: a name, or an absolute path |
| `OT_DAEMON` | `auto` | `0` to always use `--batch` |
| `OT_EDITOR` | `emacsclient -n` | what `ot open` runs, with `+LINE FILE` |

### Install

```sh
nix profile install github:bahiamovementcenter/jd-org-task   # or the overlay: pkgs.ot
```

#### As a service

On NixOS 25.11 or later, a
[modular service](https://nixos.org/manual/nixos/unstable/#modular-services)
can keep the daemon running from boot:

```nix
{ pkgs, ... }:
{
  system.services.ot = {
    imports = [ pkgs.ot.services.default ];
    ot.user = "ash"; # the user whose files it edits
  };
  environment.sessionVariables.OT_SOCKET = "/run/ot/server";
}
```

Modular services are new and still changing, and NixOS has only system
services so far, which is why the module needs `ot.user` and a fixed socket
path. When per-user services and other service managers (such as launchd
on macOS) support modular services, the same module should work there.
Without the service, `ot` starts its own daemon, so the service is optional.

### Development

```sh
nix develop
nix flake check   # tests/test.sh in real Emacs, with --batch and a daemon;
                  # shellcheck; the service's systemd unit
nix fmt
```

`lisp/ot.el` holds the logic. `bin/ot` only chooses daemon or batch, and
passes the arguments along.

## jd-org

Run a [Johnny.Decimal](https://johnnydecimal.com) system from Emacs, with
its JDex in one Org file.

[jd-nnn](https://github.com/indeterminate-systems/jd-nnn)'s `jd` does
the work: it picks the next number, creates the folder, writes the Org
heading with its `CUSTOM_ID`, and journals moves. `jd-org` never decides
a number or a place. It runs `jd … --json`, refreshes the Org buffer, and
puts you on the heading jd wrote.

The JDex stays a plain Org file, so agenda, capture, refile, clocking,
properties, tables, babel, export, `org-ql` and any other Org package work
on it as they do on any Org file. That's the "API" for running the
business: Org's own, plus the few commands below that go through jd.

### Needs

- Emacs 28.1 or later, with Org 9.6 or later.
- jd from jd-nnn on `PATH` (its development shell has it), with a system
  whose JDex is Org: `jdex = { app = "org", path = "jdex.org" }` in its
  `system.ncl`, or `jd init <dir> --jdex org`.

### Setup

```elisp
(use-package jd-org
  :load-path "~/src/jd-org-task"
  :custom
  ;; Only if jd isn't already pointed at your system by JD_CONFIG
  (jd-org-environment '("JD_CONFIG=/home/me/business/.jd/config.json"))
  :config
  (jd-org-mode 1)
  (add-to-list 'org-capture-templates
               '("j" "Into a JD ID" entry (function jd-org-capture-goto)
                 "* TODO %?\n%U")))
```

`jd-org` finds the JDex file the way jd does (`jd paths config`, then the
default system's `jdex.path`). Set `jd-org-file` to override it, and
`jd-org-system` to use a system other than jd's default.

Put the GTD keywords at the top of the JDex so Org knows them:

```org
#+TODO: TODO NEXT WAIT | DONE CANCELLED
```

### Commands

`jd-org-mode` puts them under `C-c j`:

| Key | Command | Runs |
| --- | --- | --- |
| `n` | `jd-org-new-id` | `jd new id CATEGORY TITLE`, then goes to the heading |
| `w` | `jd-org-new-wp` | `jd new wp ID TITLE`, then goes to the heading |
| `m` | `jd-org-move` | `jd move PATH ID` (from Dired, the file at point) |
| `u` | `jd-org-undo-move` | `jd undo move` |
| `g` | `jd-org-goto` | goes to an area, category, ID or work package |
| `f` | `jd-org-open-folder` | `jd ID`, then opens that folder in Dired |
| `a` | `jd-org-agenda` | the PARA and GTD views below |

Before jd writes the JDex, `jd-org` offers to save the buffer if it has
unsaved edits, and stops if you say no, so jd never writes under an edit
of yours. Afterwards it reverts the buffer to show what jd wrote.

### PARA and GTD

Both are Org, on top of the JD outline, and neither changes a number:

- **PARA** is a tag: `:para_project:`, `:para_area:`, `:para_resource:`
  (`jd-org-para-tags`). Moving an entry between buckets is changing its
  tag.
- **GTD** is TODO keywords on headings: `NEXT`, `WAIT`, `TODO` (the same keywords `ot` uses)
  (`jd-org-gtd-keywords`).

`jd-org-agenda` shows one block per keyword and per bucket. To add the
views to your own agenda (`C-c a j p`, `j g`, `j a`):

```elisp
(setq org-agenda-custom-commands
      (append org-agenda-custom-commands (jd-org-agenda-commands)))
```

### From Elisp

For your own commands, and for agents driving Emacs:

| Function | Returns |
| --- | --- |
| `(jd-org-call "new" "id" "11" "Car")` | jd's `--json` result as an alist; signals `jd-org-error` with jd's code and message |
| `(jd-org-new-id "11" "Car" :scope "…")` | the same, refreshing the JDex; keywords fill template tokens |
| `(jd-org-new-wp "11.11" "Renew it")` | the same, for a work package |
| `(jd-org-move PATH "11.11" AS)` | jd's move result |
| `(jd-org-entries)` | every numbered heading: `:id :title :level :marker :path` |
| `(jd-org-jdex-file)` | the JDex file |

### Not here

- **Numbering, checking, scaffolding**: jd and jd-nnn (`jd scaffold`,
  `jd check`).
- **Archiving**: jd has no archive command yet. Org's own
  `org-archive-subtree` moves a heading, but jd won't know the number is
  retired. It belongs in jd-nnn or xD (ADR 0005), not here.
- **Invoicing, ledger, CRM**: Org packages over the same file
  (`org-clock` tables, `ledger-mode`, `org-contacts`).

### Tests

```sh
make test                                   # against test/fake-jd
JD_ORG_REAL_JD=$(command -v jd) make test   # also against jd-nnn's jd
```

The unit tests use `test/fake-jd`, which records its arguments and prints
canned JSON. The `jd-org-real-*` tests run jd-nnn's real jd on a fresh
system with an Org JDex, and are skipped unless `JD_ORG_REAL_JD` is set.

## Licence

Copyright © 2026 Ash. Licensed under the
[GNU Affero General Public License v3.0 only](LICENSE) (`AGPL-3.0-only`).
