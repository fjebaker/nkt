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
  reading and navigation. See [Text compilers](#Text-compilers).

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

## Getting started

Before we look at how to put information _in_ to nkt, let's quickly talk about
a few ways of getting information _out_ of nkt. For any successful note taking
application, it's important to know how to find things again.

Most nkt commands that interact with something in your knowledge base use a
selector to do so. The selector can be a pretty general statement, and has some
semantic additions built in; for example:

- A number, like `1`, `4`, `7` means "n days ago". `1` will select yesterday. `0` is today.
- A date `2024-01-07` (in `YYYY-MM-DD`) will also select a specific day.
- A qualified number like `t1` or `t8` will select a specific task (we'll get
  onto those later).
- A name `art.pre-raphaelite` or `maths` will select an item by name. This
  could be the name of a note or the title of a task.

You can test what a selection will do using the `select` command. All of these
can be made more granular by including, say, a `--journal work` flag to
indicate you want to select `2` days ago in the `work` journal.

To select a specific entry, you need to choose both a day and pass a `--time
HH:MM:SS` flag. This is where shell completion comes in handy, as you can do
`nkt select 0 --time <TAB>` and a list of times will come up to select from.

Often, though, you don't know where something is stored, you just know it's
somewhere. That's where `find` comes in useful as a fuzzy text finder. It's
worth just having a look at `help find` to see what you can do with it, and
also to know that it's aliased to `f` so you can just do `nkt f` when you're in
a rush.

The other commands you will likely end up using the most are `log`, `read`, and
`edit`. So let's introduce the stars of the show:

- `log` is used to add a new entry to a journal. It's there so when you need to
  quickly jot down an idea or a thought it's there for you. Log stores a
  timestamp for every entry so you can flick back through them easily.

- `read` is used to read different things. Without any arguments read will just
  print the last `n` entries from you journal, interweaved with any status
  changes in your tasklists. You can also use it to read specific notes, which
  will just get printed directly to your terminal.

- `edit` is used to add new notes into a directory or to modify existing
  information. `edit` will only create a new note if you tell it to, to avoid
  accidentally adding notes you didn't mean to.

  You can also use edit to modify an entry by selecting it by its timestamp on
  a certain day.

  If given no arguments, `edit` will go interactive (like `find`) and let you
  fuzzy search through the names of your notes. See `help edit` for more details.

This is probably enough to get going. Have a look at [Tags](#tags) to learn
more about organising your notes effectively, and [Text
compilers](#Text-compilers) to learn how to produce rendered versions of your
notes.

## Configuration

Most things are pretty self evident regarding what they do. Check the
`~/.nkt/topology.json` to see the configuration, and edit this file as you
please.

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

Extended help for 'list':

List collections and other information in various ways.

Aliases: ls

Arguments:

    [--sort how]              How to sort the item lists. Possible values are
                                'alphabetical', 'modified' or 'created'. Defaults to created.
    [what]                    Can be 'tags', 'compilers', or when directory is
                                selected, can be used to subselect hiearchies
    [--directory name]        Name of the directory to list.
    [--journal name]          Name of the journal to list.
    [--tasklist name]         Name of the tasklist to list.
    [--hash]                  Display the full hashes instead of abbreviations.
    [--done]                  If a tasklist is selected, enables listing tasks marked
                                as 'done'
    [--archived]              If a tasklist is selected, enables listing tasks marked
                                as 'archived'
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
