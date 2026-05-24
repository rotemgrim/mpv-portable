# Optional: purge LFS objects from history

The current change stops *new* commits from adding to LFS, but every old
commit on `master` still references LFS pointers. Those LFS objects keep
counting toward your GitHub LFS **storage** quota until they're removed.
LFS *bandwidth* is no longer an issue (HEAD has no LFS files, so clones
and CI runs don't fetch anything).

If you want to fully free the storage, you have to rewrite history. This
is destructive: every collaborator will need to re-clone, and any open
PRs / forks will break. For a solo personal repo it's usually fine.

## Option A: nuke and recreate (simplest)

If you don't need the commit history:

1. Save anything you want to keep from the working tree.
2. On GitHub, **Settings → Danger zone → Delete this repository**.
3. Recreate the empty repo with the same name.
4. Locally:
   ```powershell
   Remove-Item -Recurse -Force .git
   git init
   git lfs uninstall --local
   git add .
   git commit -m "Initial commit (binaries shipped via payload release)"
   git branch -M master
   git remote add origin git@github.com:<owner>/<repo>.git
   git push -u origin master
   ```
5. Run `tools/build-payload.ps1` to upload the binary payload to the new
   `payload` release.

## Option B: keep history, drop LFS objects (git-filter-repo)

Keeps every commit message and authorship; rewrites the trees so LFS
pointer files are gone.

1. Install [`git-filter-repo`](https://github.com/newren/git-filter-repo)
   (`pip install git-filter-repo` works).
2. Make a fresh mirror clone:
   ```powershell
   git clone --mirror git@github.com:<owner>/<repo>.git repo.git
   cd repo.git
   ```
3. Drop every path that ever lived in LFS. The list below mirrors the
   old `.gitattributes` LFS filters:
   ```powershell
   git filter-repo --invert-paths `
     --path-glob '*.exe' `
     --path-glob '*.dll' `
     --path-glob '*.pyd' `
     --path-glob '*.onnx' `
     --path-glob '*.zip' `
     --path-glob '*.otf' `
     --path-glob '*.ttf'
   ```
4. Force-push:
   ```powershell
   git push --force --all
   git push --force --tags
   ```
5. On GitHub, ask support (or use the API) to expire old LFS objects, or
   just wait for the periodic GC. Storage will drop once the unreferenced
   objects are pruned.

## Option C: do nothing

LFS storage stays elevated but bandwidth is free. If you're under the
1 GB storage cap by enough margin (or you don't mind the warning email),
this is fine.
