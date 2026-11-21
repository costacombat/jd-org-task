# jd-org

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

## Needs

- Emacs 28.1 or later, with Org 9.6 or later.
- jd from jd-nnn on `PATH` (its development shell has it), with a system
  whose JDex is Org: `jdex = { app = "org", path = "jdex.org" }` in its
  `system.ncl`, or `jd init <dir> --jdex org`.

## Setup

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
#+TODO: TODO NEXT WAITING | DONE CANCELLED
```

## Commands

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

## PARA and GTD

Both are Org, on top of the JD outline, and neither changes a number:

- **PARA** is a tag: `:para_project:`, `:para_area:`, `:para_resource:`
  (`jd-org-para-tags`). Moving an entry between buckets is changing its
  tag.
- **GTD** is TODO keywords on headings: `NEXT`, `WAITING`, `TODO`
  (`jd-org-gtd-keywords`).

`jd-org-agenda` shows one block per keyword and per bucket. To add the
views to your own agenda (`C-c a j p`, `j g`, `j a`):

```elisp
(setq org-agenda-custom-commands
      (append org-agenda-custom-commands (jd-org-agenda-commands)))
```

## From Elisp

For your own commands, and for agents driving Emacs:

| Function | Returns |
| --- | --- |
| `(jd-org-call "new" "id" "11" "Car")` | jd's `--json` result as an alist; signals `jd-org-error` with jd's code and message |
| `(jd-org-new-id "11" "Car" :scope "…")` | the same, refreshing the JDex; keywords fill template tokens |
| `(jd-org-new-wp "11.11" "Renew it")` | the same, for a work package |
| `(jd-org-move PATH "11.11" AS)` | jd's move result |
| `(jd-org-entries)` | every numbered heading: `:id :title :level :marker :path` |
| `(jd-org-jdex-file)` | the JDex file |

## Not here

- **Numbering, checking, scaffolding**: jd and jd-nnn (`jd scaffold`,
  `jd check`).
- **Archiving**: jd has no archive command yet. Org's own
  `org-archive-subtree` moves a heading, but jd won't know the number is
  retired. It belongs in jd-nnn or xD (ADR 0005), not here.
- **Invoicing, ledger, CRM**: Org packages over the same file
  (`org-clock` tables, `ledger-mode`, `org-contacts`).

## Tests

```sh
make test                                   # against test/fake-jd
JD_ORG_REAL_JD=$(command -v jd) make test   # also against jd-nnn's jd
```

The unit tests use `test/fake-jd`, which records its arguments and prints
canned JSON. The `jd-org-real-*` tests run jd-nnn's real jd on a fresh
system with an Org JDex, and are skipped unless `JD_ORG_REAL_JD` is set.
