# Domta

Domta is a macOS SwiftUI app for comparing two SQL Server or Azure SQL databases and generating a script for the target database. It has two modes:

- **Data Compare** — compares row data in tables whose schema and primary key match, then generates an INSERT/UPDATE/DELETE sync script. Uses `sqlcmd`.
- **Schema Compare** — compares the structure of tables, views, stored procedures and functions, then generates a deployment script. Uses `sqlpackage`.

## Before You Start

You need:

- macOS
- Xcode
- Microsoft `sqlcmd`
- Microsoft `sqlpackage` (Schema Compare mode only)
- Source and target database access
- SQL Authentication connection strings

Install `sqlcmd` with Homebrew:

```bash
brew install sqlcmd
sqlcmd -?
```

Install `sqlpackage` with the .NET SDK:

```bash
dotnet tool install --global microsoft.sqlpackage
sqlpackage /version
```

Domta looks for `sqlpackage` on your `PATH` plus the usual install locations
(`~/.dotnet/tools`, `/usr/local/bin`, `/opt/homebrew/bin`).

## Connection String Example

```text
Data Source=your-server.database.windows.net,1433;Database=your-database;User ID=your-username;Password=your-password;Encrypt=True;Trust Server Certificate=True;
```

Notes:

- Only SQL Authentication is supported.
- Integrated Security / Windows Authentication is not supported.
- Do not leave placeholder passwords like `<password>`.

## How To Run

1. Open [Domta.xcodeproj](/Users/earth/Playgrounds/xcode/Domta/Domta.xcodeproj) in Xcode.
2. Run the `Domta` scheme.
3. Paste source and target connection strings.
4. Test both connections.
5. Pick a mode.

### Data Compare

6. Load comparable tables.
7. Compare selected tables.
8. Copy and review the generated SQL script before running it on the target.

### Schema Compare

6. Open Schema Compare. Adjust which object types to include under Options, then
   press Compare.
7. The results grid lists one row per object — `Type`, `Source Name`, a checkbox,
   `Action` (Add / Change / Delete) and `Target Name` — laid out like the Schema
   Compare view in the VS Code mssql extension. Tick or untick individual objects,
   or use the checkbox in the header to toggle everything the filter shows.
8. Click a row to see its Comparison Details underneath: a summary of the
   constraints and indexes involved, then the source and target definitions side
   by side with SQL syntax highlighting (or switch to a unified diff).
9. Generate the deployment script. It defaults to the objects you ticked; switch to
   Full script to see everything `sqlpackage` produced. Copy or save it and review it
   before running it on the target.

## What It Does

Data Compare:

- Finds tables with matching schema and primary keys
- Detects inserts, updates, and deletes
- Generates SQL to sync target data to source data

Schema Compare:

- Extracts the source database to a temporary `.dacpac` (`sqlpackage /Action:Extract`)
- Compares it against the target and reads the deployment report
  (`sqlpackage /Action:Script` with `/DeployReportPath`)
- Rolls the differences up to one row per object, so an index or constraint change
  shows up on its parent table rather than as a row of its own
- Marks each row as Add (only in source), Change (different) or Delete (only in target)
- Loads each object's definition from both sides through `sqlcmd` and shows them
  side by side, line by line — tables are rendered from their columns, keys and
  indexes; views, procedures and functions come from `sys.sql_modules`
- Generates the T-SQL deployment script that makes the target match the source

Compare options map straight onto `sqlpackage` properties, including
`DropObjectsNotInSource`, `IgnoreWhitespace`, `IgnoreComments`, `IgnorePermissions`,
`IgnoreUserSettingsObjects`, `IgnoreExtendedProperties` and `BlockOnPossibleDataLoss`.

### How the checkboxes filter the script

The `sqlpackage` command line filters a deployment by object *type* only — it has no
way to include or exclude individual objects the way the DacFx API behind the VS Code
mssql extension does. Domta gets the same result in two passes:

1. Object types you turn off under Options never reach the comparison at all
   (`/p:ExcludeObjectTypes`).
2. The script `sqlpackage` returns is then split back into its own sections. Every
   operation it emits is a `PRINT N'...'` batch followed by the statements for that
   operation, so a section can be dropped whole without cutting a statement in half.

The split is deliberately fail-open. A section is dropped only when it references
objects Domta recognises **and none of them are ticked**. A section that touches at
least one ticked object, or that Domta cannot attribute to any object at all — the
`SET` options, `:setvar` block, `USE`, and the trailing `PRINT N'Update complete.'` —
is always kept. The worst case is therefore a script with more in it than you asked
for, never a truncated one.

What it cannot do is fix dependencies. If you keep a view but drop the table it reads
from, the script will fail when you run it. The script page shows how many sections
were dropped and warns about this; use the Full script tab to see what was left out.

## Important

- `sqlcmd` must be available in your `PATH`; Schema Compare also needs `sqlpackage`
- The app does not execute the generated script for you
- Review the script carefully before using it, especially in production,
  especially the `DROP` and `ALTER TABLE` statements a schema deployment can contain
- Passwords are passed to `sqlcmd` through `SQLCMDPASSWORD` and to `sqlpackage`
  through a 0600 response file, so they do not show up in the process list
- Schema Compare writes a temporary `.dacpac` and script into a private temp
  directory and deletes it when the compare finishes
