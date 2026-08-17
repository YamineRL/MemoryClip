# Contributing

Issues are the most useful thing you can send: a bug with the steps that reproduce it, or
a case where MemoryClip does the wrong thing with a clip. Pull requests are welcome too,
with the condition below.

## The condition

MemoryClip is licensed under [FSL-1.1-ALv2](LICENSE), which withholds competing use and
converts each version to Apache-2.0 two years after its release. Both halves of that only
work while one person holds the copyright to all of it: a licence can only be granted by
the owner, and a contribution I do not own is one I cannot put under those terms — or
under different terms later, if the licence ever needs to change again.

**So: by opening a pull request you assign copyright in your contribution to YamineRL**,
and receive back a licence to use your own work for any purpose, without restriction. Say
so in the pull request. If you would rather not, open an issue describing the change
instead and it can be written separately.

## Before you open one

- `swift test` passes — the suite is fast and covers most of the behaviour.
- `swiftformat --lint .` reports nothing; the rules are in `.swiftformat`.
- Comments explain why, never what. The code says what it does; a comment earns its place
  by recording the reasoning a later reader would otherwise have to reconstruct.
