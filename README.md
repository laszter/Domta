# Domta

Domta is a macOS SwiftUI app for comparing data between two SQL Server or Azure SQL databases and generating a sync script for the target database.

## Before You Start

You need:

- macOS
- Xcode
- Microsoft `sqlcmd`
- Source and target database access
- SQL Authentication connection strings

Install `sqlcmd` with Homebrew:

```bash
brew install sqlcmd
sqlcmd -?
```

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
5. Load comparable tables.
6. Compare selected tables.
7. Copy and review the generated SQL script before running it on the target.

## What It Does

- Finds tables with matching schema and primary keys
- Detects inserts, updates, and deletes
- Generates SQL to sync target data to source data

## Important

- `sqlcmd` must be available in your `PATH`
- The app does not execute the generated script for you
- Review the script carefully before using it, especially in production
