# Release notes

One file per released version, named after it (`0.1.md`), written for the people who use the
addon: what is new, what changed, what to watch out for.

How we keep them:

1. **While working**, add a line to [`unreleased.md`](unreleased.md) for each thing done. Short,
   in plain words, with the reason if it is not obvious. These are notes for the notes.
2. **Only when the version is bumped**, write that version's file from `unreleased.md`, then
   empty `unreleased.md`. No release notes are written for work that has not been released.
3. **Versions are semantic**: major.minor.patch (`0.2.1`). Patch for fixes and small additions,
   minor for new features, major when saved data or habits break.
4. **Bumping** means changing the number in three places together: `ns.VERSION` in
   `CraftGraph/Core.lua`, `## Version` in `CraftGraph/CraftGraph.toc` (the offline checks compare
   the two) and the first line of `CraftGraph/README.txt`. Then build the zip and publish it as a
   GitHub release tagged `v<version>`; that tag is what the update check reads.

Released versions:
- [0.3.0](0.3.0.md)
- [0.2.1](0.2.1.md)
- [0.2](0.2.md)
- [0.1](0.1.md)
