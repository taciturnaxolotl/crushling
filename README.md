# crushling

so cuuuuute 💖

The canonical repo for this is hosted on tangled over at [`https://tangled.org/dunkirk.sh/crushling`](https://tangled.org/dunkirk.sh/crushling)

A Slack bridge that runs one `crush server` per Slack thread, each in its own gVisor sandbox. Each agent dials back to the bridge over a tunnel and uses Charm Hyper through the bridge's metered inference proxy, so the org's key (`CRUSHLING_HYPER_KEY`, required) never enters a sandbox. Settings are in the table at the top of `src/crushling.gleam`; `docs/status.md` covers running it, and `docs/sandbox.md` the sandbox host and image (which needs a crush with `--dial`).

<p align="center">
    <img src="https://raw.githubusercontent.com/taciturnaxolotl/carriage/main/.github/images/line-break.svg" />
</p>

<p align="center">
    <i><code>&copy; 2026-present <a href="https://dunkirk.sh">Kieran Klukas</a></code></i>
</p>

<p align="center">
    <a href="https://tangled.org/dunkirk.sh/crushling/blob/main/LICENSE.md"><img src="https://img.shields.io/static/v1.svg?style=for-the-badge&label=License&message=MIT&logoColor=d9e0ee&colorA=363a4f&colorB=b7bdf8"/></a>
</p>
