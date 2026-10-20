# Contributing to Bridgeplay

Thanks for helping. Bridgeplay is a small, free project, so a short, focused pull request
is the easiest to review. An imperfect PR is still welcome: say what is unfinished and I can
help.

1. **Open an issue first** for anything large, and check closed issues and PRs so work is not
   duplicated. Game reports use the "Game report" template.
2. **Write the PR description yourself.** Translation is fine; plain human text is easier to
   review than generated text.
3. **Keep comments short and useful.** Comment where the code is hard to follow, not where it
   is obvious.
4. **Think through the hard parts.** Code that runs inside Steam, the run script, lsteamclient,
   Wine patches and game saves interact in subtle ways. Consider multiple Steam accounts,
   libraries, macOS users and file systems.
5. **Run the checks** your change touches before opening the PR (`make scriptcheck`,
   `make buildcheck`, `make app`; see [docs/DEVELOPING.md](docs/DEVELOPING.md)).

By contributing you agree that your contribution is licensed under the GPL-3.0, like the rest
of Bridgeplay (see [LICENSE](LICENSE) and [NOTICE](NOTICE)). Changes that belong upstream
are better sent to [NotProton](https://github.com/NotProtonNot/NotProton).

Report problems at https://github.com/raymondchins/Bridgeplay/issues.
