# Contributing

## Branches

- `main` is always a working build. It only moves forward by fast-forwarding to `dev`.
- `dev` is where finished work lands.
- Feature branches (`feat/…`, `fix/…`, `docs/…`) branch off `dev` and are rebased onto it before merging.

History stays linear: no merge commits, no force-pushes to `main` or `dev`. Both branches are protected to enforce that.

```bash
git switch dev && git pull                # pull rebases by default
git switch -c feat/my-change
# ...commit...
git rebase dev                            # before opening a PR, and whenever dev moves
gh pr create --base dev                   # merge with "Rebase and merge"
```

Releasing `dev` to `main` is a fast-forward push, so the commits on both branches stay identical:

```bash
git switch dev && git pull
git push origin dev:main
```

If that push is rejected, `main` has something `dev` doesn't; rebase `dev` onto it first.
