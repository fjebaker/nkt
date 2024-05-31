# nkt

_A(nother) note taking solution for terminal enthusiasts._

nkt is a command line tool for helping you track and build your notes, todo
lists, habits, and more. nkt mixes a number of different note-taking idioms,
with inspiration from applications like [Dendron](https://www.dendron.so/),
[jrnl](https://github.com/jrnl-org/jrnl),
[vim-wiki](https://github.com/vimwiki/vimwiki) and methods such as the
incremental note-taking method, "Dont break the chain" and
[Zettelkasten](https://en.wikipedia.org/wiki/Zettelkasten).

Features:
- Bring your own `$EDITOR`
- Bring your own reader / renderer
- Bring your own document format (Markdown, LaTeX, typst, RST, ...)
- _Everything_ stored as plain text and JSON, so easy to migrate if you end up hating it
- Support for journals, tasklists, notes, and chains
- Tag things to help search your notes

## Description

The design of nkt is centered around making it easy to get information into
your notes, and making it quick and simple to find that information again.
Principally, nkt provides four different ways to record information:

- Journal

  A journal is a collection of _days_, each of which is a collection of
  _entries_. The journal is the standard way to quickly jot something down you
  might want to remember; the command is designed to be short and sweet and to
  get out of the way quickly so you can continue on with what you were doing.

  Every entry in the journal is timestamped, and can be tagged using in-place tags
  or using post-fix tags. See [Tags](#Tags).

- Notes

  Notes are (longer form) textual notes that are kept in _directories_. Notes
  have dot-hierarchical names, so you don't have a directory called `music` and
  another one called `composers` into which you put `Bach.md`, but rather you
  have `music.composers.Bach.md`.

  Each note can be compiled with a text compiler into a rendered note for easy
  reading and navigation. See [Rendering](#Rendering).

- Tasks

  A task is kept in a _tasklist_, and represents a todo-item. Tasks can be
  given due dates (see [Semantic time](#Semantic-time)), have importance assigned
  to them, be tagged in various ways, and even have notes and descriptions
  attached to them.

- Chains

  Chains are for building habits. A chain is given a task or habit you are
  trying to build and then it can be checked off each day you complete that tasks.

## Usage

To setup `nkt`, use the `init` command.
```
$ nkt help init

Extended help for 'init':

(Re)Initialize the home directory structure.

You can override where the home directory is with the `NKT_ROOT_DIR`
environment variable. Be sure to export it in your shell rc or profile file to
make the change permanent.

Initializing will create a number of defaults: a directory "notes", a journal
"diary", a tasklist "todo".

These can be changed later if desired. You must always have some defaults
defined so that nkt knows where to put things if you don't tell it otherwise.


Arguments:

    [--reinit]                Only create missing files and write missing
                                configuration options.
    [--force]                 Force initializtion. Danger: this will overwrite *all*
                                topology files.
```

And that's it! You're all setup.

### Shell completion

nkt brings shell completion so you can use Tab to complete command line
arguments, note names, even select specific entries from journals.

There is shell completion for the following shells:

- zsh:

  Generate the completions file
  ```
  nkt completion > _nkt
  ```
  Then move the `_nkt` file into your zsh completion path (e.g. `~/.zsh_completions/`).

- Sorry, I only really use `zsh` at the moment and writing completion files is not a hobby of mine.

## Reference

General help:
```
$ nkt help

Quick command reference:
 - config      View and modify the configuration of nkt
 - compile     Compile a note into various formats.
 - chains      View and interact with habitual chains.
 - edit        Edit a note or item in the editor.
 - find        Find in notes.
 - help        Print this help message or help for other commands.
 - import      Import a note.
 - init        (Re)Initialize the home directory structure.
 - list        List collections and other information in various ways.
 - log         Quickly log something to a journal from the command line
 - new         Create a new tag or collection.
 - migrate     Migrate differing versions of nkt's topology
 - read        Read notes, task details, and journals.
 - remove      Remove items, tags, or entire collections themselves.
 - rename      Move or rename a note, directory, journal, or tasklist.
 - task        Add a task to a specified task list.
 - select      Select an item or collection.
 - set         Modify attributes of entries, notes, chains, or tasks.
 - sync        Sync root directory to remote git repository
 - completion  Shell completion helper
```

Extended help for a specific command may also be obtained:

```
$ nkt help list
Extended help for list:

Aliases: ls

List notes in various ways to the terminal.
  nkt list
     <what>                list the notes in a directory, journal, or tasks. this option may
                             also be `all` to list everything. To list all tasklists use
                             `tasks` (default: all)
     -n/--limit int        maximum number of entries to list (default: 25)
     --all                 list all entries (ignores `--limit`)
     --modified            sort by last modified (default)
     --created             sort by date created
     --alphabetical        sort by date created
     --pretty/--nopretty   pretty format the output, or don't (default
                           is to pretty format)

When the `<what>` is a task list, the additional options are
     --due                 list in order of when something is due (default)
     --importance          list in order of importance
     --done                list also those tasks marked as done
     --archived            list also archived tasks
     --details             also print details of the tasks
```

### Tags

### Text compilers

### Semantic time

## Installation

Grab one of the binaries from the [release]() for your architecture:

- Linux Aarch64 (musl)
- Linux x86_64 (musl)
- MacOS M1
- MacOS Intel
- I don't know how to Windows

### From source

Clone this GitHub repository, and have [Zig]() installed. nkt tracks the master
branch of zig so the latest release should work, but just the definitive
version can be found in the `.zigversion` file in this repository.

```bash
git clone https://github.com/fjebaker/nkt \
    && cd nkt \
    && zig build -Doptimize=ReleaseSafe
```

## Known issues

- Datetimes are ruining my life.

---

Dependencies:
- [frmdstryr/zig-datetime](https://github.com/frmdstryr/zig-datetime)
