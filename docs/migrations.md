# Migrations

A migration repairs state that an older release left behind, such as a retired key in
`settings.json` or an orphaned default. It ships in exactly one stable release and is then deleted,
so the codebase never carries a history of its past formats.

## Invariants

- **Every migration lives in `Tinycast/Migrations/`**, one file and one `<Subject>Migration` type
  each. Its call sites name that type, so deleting the file fails the build at every one of them.
- **One stable release, then gone.** `Scripts/check-migrations.sh` fails `lint.sh` and the Release
  workflow once a stable tag (`vX.Y.Z`) contains the commit that added the file. Beta tags do not
  count: the beta channel runs it on the way to that stable release.
- **Missing it must be harmless.** A user who skips that release never runs it, so a migration only
  tidies. A value a later release depends on is never left to one.
- **Idempotent and silent.** It runs on every launch of its release, does nothing when there is
  nothing to repair, and reports nothing.
- **Every live migration has a row below.** The check fails for a file the table does not name.

## Adding one

Write the type in `Migrations/` and call it from `AppCore.start()` before anything reads the state it
repairs. Cover it with a harness of its own, so deleting it removes a whole file, one `run-tests.sh` entry and
one row in [testing.md](testing.md). Then add its row here.

## Deleting one

When the check fails, delete everything the row lists, then the row.

## Live migrations

| Migration | Repairs | Delete with it |
| --- | --- | --- |
| `DictationShortcutsMigration` | Moves the single Dictation shortcut to the hold or toggle binding according to its saved mode. Recognizes the retired keys when reading settings.json. | Calls in `AppCore.start()` and `SettingsFileFormat.parse()`, the `dictation-shortcuts-migration-test` harness and its runner and testing table entries, and the migration source entries in the other settings file harnesses. |
| `DictationDestinationMigration` | Drops the retired Dictation destination, live insertion and count-based history preferences and skips their old settings.json keys. | References in `AppCore.start()` and `SettingsFileFormat.parse()`, the `dictation-destination-migration-test` harness and its runner and testing table entries, and the migration source entries in the other settings file harnesses. |
| `DictationVolumeMigration` | Restores output volume left lowered by an older build when it still matches the saved fade step. | Call in `AppCore.start()` and the `dictation-volume-migration-test` harness and its runner and testing table entries. |
