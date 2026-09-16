# Domta

Domta is a macOS SwiftUI app for comparing two SQL Server or Azure SQL databases and generating a script for the target database. It has two modes:

- **Data Compare** — compares row data in tables whose schema and primary key match, then generates an INSERT/UPDATE/DELETE sync script. Uses `sqlcmd`.
- **Schema Compare** — compares the structure of tables, views, stored procedures and functions, then generates a deployment script. Either side can be a live database or a `.dacpac` file. Uses `sqlpackage`.

## Before You Start

You need:

- macOS
- Xcode
- Microsoft `sqlcmd`
- Microsoft `sqlpackage` (Schema Compare mode only)
- .NET SDK 10 or later (Schema Compare mode — runs the DacFx helper that scripts the objects you tick)
- Source and target database access (Schema Compare can use a `.dacpac` file for either side instead)
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
(`~/.dotnet/tools`, `/usr/local/bin`, `/opt/homebrew/bin`), and for `dotnet` on your `PATH`,
`/usr/local/share/dotnet` and `~/.dotnet`. Check with:

```bash
dotnet --version   # 10.x or later
```

The first time you generate a script for selected objects, the helper restores the
`Microsoft.SqlServer.DacFx` package from NuGet (needs network access, about 10 seconds).
Later runs reuse the cached build and take a couple of seconds.

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

6. For each side, pick **Database** (connection string) or **DACPAC File** and choose
   the `.dacpac` with *Choose File...*. Any combination works: database → database,
   dacpac → database, database → dacpac or dacpac → dacpac.
7. Open Schema Compare. Adjust which object types to include under Options, then
   press Compare.
8. The results grid lists one row per object — `Type`, `Source Name`, a checkbox,
   `Action` (Add / Change / Delete) and `Target Name` — laid out like the Schema
   Compare view in the VS Code mssql extension. Tick or untick individual objects,
   or use the checkbox in the header to toggle everything the filter shows.
9. Click a row to see its Comparison Details underneath: a summary of the
   constraints and indexes involved, then the source and target definitions side
   by side with SQL syntax highlighting (or switch to a unified diff).
10. Generate the deployment script. It defaults to the objects you ticked; switch to
   Full script to see everything `sqlpackage` produced. The Format switch defaults to
   **Plain T-SQL**, which you can paste straight into a normal query editor; pick
   **SQLCMD** only if you run the file with `sqlcmd -i`. Copy or save it and review it
   before running it on the target.

## What It Does

Data Compare:

- Finds tables with matching schema and primary keys
- Detects inserts, updates, and deletes
- Generates SQL to sync target data to source data

Schema Compare:

- Extracts each side that is a database to a temporary `.dacpac` file
  (`sqlpackage /Action:Extract`); a side you chose as a `.dacpac` file is used in place
- Compares the two files and reads the deployment report
  (`sqlpackage /Action:Script /SourceFile /TargetFile` with `/DeployReportPath`)
- Rolls the differences up to one row per object, so an index or constraint change
  shows up on its parent table rather than as a row of its own
- Marks each row as Add (only in source), Change (different) or Delete (only in target)
- Loads each object's definition from both sides through `sqlcmd` and shows them
  side by side, line by line — tables are rendered from their columns, keys and
  indexes; views, procedures and functions come from `sys.sql_modules`.
  When either side is a `.dacpac` file, both definitions come from the DacFx helper
  instead (the object's `CREATE` script from each file, plus the table's indexes and
  triggers), so the two columns share the same formatting
- Generates the T-SQL deployment script that makes the target match the source

Compare options map straight onto `sqlpackage` properties, including
`DropObjectsNotInSource`, `IgnoreWhitespace`, `IgnoreComments`, `IgnorePermissions`,
`IgnoreUserSettingsObjects`, `IgnoreExtendedProperties` and `BlockOnPossibleDataLoss`.

### How the checkboxes filter the script

The `sqlpackage` command line filters a deployment by object *type* only — it has no
way to include or exclude individual objects. Its `.scmp` input does carry per-object
exclusions, but `sqlpackage` applies them in a single pass and silently drops every
exclusion that is blocked by a dependency at that moment (tested: 88 exclusions in,
52 objects still included). So Domta does what the VS Code mssql extension does and
drives the DacFx API itself:

1. Object types you turn off under Options never reach the comparison at all
   (`/p:ExcludeObjectTypes`).
2. When you open the script page, Domta writes a small .NET helper
   (`~/Library/Application Support/Domta/DacFxHelper/DomtaDacFx.cs`, source embedded in
   `DacFxHelperSource.swift`) and runs it with `dotnet run`. The helper compares the two
   `.dacpac` files with `Microsoft.SqlServer.Dac.Compare`, calls `Exclude()` on every object
   you did not tick — repeating until nothing more can be excluded, because DacFx refuses
   to exclude an object that an included object still depends on — and then lets DacFx
   generate the script.

Because DacFx builds the deployment plan itself, the script keeps everything the ticked
objects need: foreign keys on *other* tables are dropped before a rebuild and re-created
after it, schemas and referenced tables are created first, and dependent modules are
refreshed. Objects that DacFx had to keep even though you did not tick them are listed on
the script page so you can see why the script is bigger than the selection.

If `dotnet` is missing or the helper fails, Domta falls back to splitting the full
`sqlpackage` script into its `PRINT N'...'` sections and dropping the ones that belong
only to unticked objects. That fallback is fail-open (never truncates a statement) but it
is blind to dependencies, and the page says so.

### Plain T-SQL vs SQLCMD

Everything DacFx generates is a **SQLCMD script**: it starts with `:setvar DatabaseName`,
`:on error exit`, and a batch that runs `SET NOEXEC ON` unless SQLCMD mode is enabled.
Pasted into a normal query window (VS Code mssql, Azure Data Studio without SQLCMD mode,
SSMS) that fails with `Incorrect syntax near ':'` — or worse, runs to the end without
doing anything. Domta therefore shows **Plain T-SQL** by default: the `:setvar` values are
substituted into the script (`$(DatabaseName)` becomes the real name), the directives and
the SQLCMD detection batch are removed, and the batches are otherwise untouched. Switch
to **SQLCMD** to get the original text for `sqlcmd -i file.sql`.

## Important

- `sqlcmd` must be available in your `PATH`; Schema Compare also needs `sqlpackage`
- The app does not execute the generated script for you
- Review the script carefully before using it, especially in production,
  especially the `DROP` and `ALTER TABLE` statements a schema deployment can contain
- Passwords are passed to `sqlcmd` through `SQLCMDPASSWORD` and to `sqlpackage`
  through a 0600 response file, so they do not show up in the process list
- Schema Compare writes the extracted `.dacpac` files and scripts into a private temp
  directory; it is deleted when you compare again or leave Schema Compare, and the OS
  purges it otherwise. A `.dacpac` you choose yourself is read where it is — never
  copied, changed or deleted — so referenced dacpacs next to it (such as `master.dacpac`
  in a SQL project's `bin` folder) still resolve
