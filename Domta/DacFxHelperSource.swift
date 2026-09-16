//
//  DacFxHelperSource.swift
//  Domta
//

import Foundation

/// source ของ helper .NET ที่ Domta เขียนลง Application Support แล้วรันด้วย `dotnet run <file>.cs`
///
/// เก็บเป็น string ในโค้ด Swift แทนไฟล์ resource เพราะ project ใช้ synchronized group —
/// ไฟล์ .cs ในโฟลเดอร์ Domta/ จะถูก Xcode ตีความไม่แน่นอน ส่วน string ฝังไม่ต้องแตะ project.pbxproj
///
/// ทำไมต้องมี helper: `sqlpackage` กรอง object รายตัวไม่ได้ และเส้นทาง `.scmp` ของมันทิ้ง exclusion
/// ที่ "ถูกบล็อกโดย dependency" ไปเงียบ ๆ (ลองแล้ว: exclude 88 รายการ เหลือ included 52) ในขณะที่
/// `SchemaComparisonResult.Exclude()` ใน DacFx API ทำซ้ำจนหมดได้ และตอน GenerateScript จะลาก
/// dependency ที่ object ที่เลือกต้องใช้มาเอง (drop/create FK ของตารางอื่น, schema, table ที่ถูกอ้าง)
///
/// เวอร์ชันอยู่ในบรรทัด `// Domta DacFx helper — vN` ข้างใน — เปลี่ยนเลขทุกครั้งที่แก้ source
/// เพราะ `dotnet run` cache build ตาม path + เนื้อหาไฟล์ และ Domta เขียนทับไฟล์เมื่อเนื้อหาไม่ตรง
enum DacFxHelperSource {
    static let fileName = "DomtaDacFx.cs"

    static let text: String = #"""
#:package Microsoft.SqlServer.DacFx@170.*
#:property PublishAot=false
#:property JsonSerializerIsReflectionEnabledByDefault=true
// Domta DacFx helper — v3
//
// Runs the DacFx schema-compare API in-process so Domta can generate a deployment script
// for a *subset* of objects while DacFx keeps every dependency the subset needs
// (foreign keys on other tables, schemas, referenced tables, module refreshes).
//
// usage: dotnet run DomtaDacFx.cs -- <request.json>
// The request names two .dacpac files, the compare options, the objects to include
// (lower-cased "schema.name" keys) and where to write the script + the result JSON.
// Mode "definitions" skips the comparison and returns each named object's CREATE script
// from both files instead — the Comparison Details view when a side is a .dacpac file.
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.SqlServer.Dac;
using Microsoft.SqlServer.Dac.Compare;
using Microsoft.SqlServer.Dac.Model;

var json = new JsonSerializerOptions { PropertyNamingPolicy = JsonNamingPolicy.CamelCase, PropertyNameCaseInsensitive = true, WriteIndented = true };

if (args.Length < 1)
{
    Console.Error.WriteLine("usage: DomtaDacFx.cs <request.json>");
    return 2;
}

Request request;
try
{
    request = JsonSerializer.Deserialize<Request>(File.ReadAllText(args[0]), json)
        ?? throw new InvalidOperationException("request is empty");
}
catch (Exception ex)
{
    Console.Error.WriteLine($"cannot read request: {ex.Message}");
    return 2;
}

var response = new Response();

try
{
    if (string.Equals(request.Mode, "definitions", StringComparison.OrdinalIgnoreCase))
    {
        var wanted = new HashSet<string>((request.IncludedObjects ?? new List<string>()).Select(k => k.ToLowerInvariant()));

        Console.WriteLine("Reading source dacpac...");
        var sourceScripts = ScriptObjects(request.SourceDacpac, wanted);
        Console.WriteLine("Reading target dacpac...");
        var targetScripts = ScriptObjects(request.TargetDacpac, wanted);

        foreach (var key in wanted)
        {
            var hasSource = sourceScripts.TryGetValue(key, out var sourceScript);
            var hasTarget = targetScripts.TryGetValue(key, out var targetScript);
            if (!hasSource && !hasTarget) continue;
            response.Definitions.Add(new DefinitionInfo { Key = key, Source = sourceScript, Target = targetScript });
        }

        response.Success = true;
        Finish();
        return 0;
    }

    var source = new SchemaCompareDacpacEndpoint(request.SourceDacpac);
    var target = new SchemaCompareDacpacEndpoint(request.TargetDacpac);
    var comparison = new SchemaComparison(source, target);

    var o = comparison.Options;
    o.DropObjectsNotInSource = request.Options.DropObjectsNotInSource;
    o.BlockOnPossibleDataLoss = request.Options.BlockOnPossibleDataLoss;
    o.IgnorePermissions = request.Options.IgnorePermissions;
    o.IgnoreUserSettingsObjects = request.Options.IgnoreUserSettingsObjects;
    o.IgnoreExtendedProperties = request.Options.IgnoreExtendedProperties;
    o.IgnoreWhitespace = request.Options.IgnoreWhitespace;
    o.IgnoreComments = request.Options.IgnoreComments;
    o.AllowIncompatiblePlatform = true;
    o.ScriptDatabaseOptions = false;
    o.CommentOutSetVarDeclarations = false;

    var excludeTypes = new List<ObjectType>();
    foreach (var name in request.Options.ExcludeObjectTypes ?? new List<string>())
    {
        if (Enum.TryParse<ObjectType>(name, true, out var type)) excludeTypes.Add(type);
        else response.Warnings.Add($"unknown object type '{name}' ignored");
    }
    o.ExcludeObjectTypes = excludeTypes.ToArray();

    Console.WriteLine("Comparing dacpacs...");
    var result = comparison.Compare();

    if (!result.IsValid)
    {
        response.Success = false;
        response.Message = "DacFx reported the comparison as invalid: " +
            string.Join(" | ", result.GetErrors().Select(e => e.Message));
        Finish();
        return 1;
    }

    var all = result.Differences.ToList();
    response.DifferenceCount = all.Count;

    var keep = new HashSet<string>((request.IncludedObjects ?? new List<string>()).Select(k => k.ToLowerInvariant()));
    var pending = all.Where(d => !keep.Contains(Key(d))).ToList();

    // Exclude() refuses while an *included* difference still depends on the object, so a
    // single pass leaves "blocked" entries behind. Re-run until nothing more can be excluded.
    for (var pass = 0; pending.Count > 0 && pass < 25; pass++)
    {
        var still = new List<SchemaDifference>();
        foreach (var difference in pending)
        {
            if (!result.Exclude(difference)) still.Add(difference);
        }
        Console.WriteLine($"exclude pass {pass + 1}: excluded {pending.Count - still.Count}, blocked {still.Count}");
        if (still.Count == pending.Count) break;
        pending = still;
    }

    foreach (var difference in pending.Where(d => d.Included))
    {
        response.ForcedIncluded.Add(Describe(difference));
    }

    foreach (var difference in all.Where(d => d.Included))
    {
        response.Included.Add(Key(difference));
    }
    response.ExcludedCount = all.Count(d => !d.Included);

    // DacFx refuses to script a result with nothing included ("script generation is not
    // possible for this comparison result") — an empty selection is a valid answer, not an error.
    if (response.Included.Count == 0)
    {
        File.WriteAllText(request.OutputScript, "-- No objects selected: nothing to deploy.\n");
        response.Success = true;
        Finish();
        return 0;
    }

    Console.WriteLine($"Generating script for {response.Included.Count} object(s)...");
    var generated = result.GenerateScript(string.IsNullOrWhiteSpace(request.TargetDatabaseName) ? "Target" : request.TargetDatabaseName);

    if (!generated.Success)
    {
        response.Success = false;
        response.Message = string.IsNullOrWhiteSpace(generated.Message) ? "DacFx could not generate the script" : generated.Message;
        Finish();
        return 1;
    }

    File.WriteAllText(request.OutputScript, generated.Script ?? string.Empty);
    response.Success = true;
    response.Message = generated.Message ?? string.Empty;
}
catch (Exception ex)
{
    response.Success = false;
    response.Message = ex.Message;
}

Finish();
return response.Success ? 0 : 1;

void Finish()
{
    File.WriteAllText(request.OutputResult, JsonSerializer.Serialize(response, json));
}

static string Key(SchemaDifference difference)
{
    var obj = difference.SourceObject ?? difference.TargetObject;
    var key = obj == null ? string.Empty : KeyOf(obj);
    return key.Length > 0 ? key : difference.Name?.ToLowerInvariant() ?? string.Empty;
}

static string KeyOf(TSqlObject obj)
{
    var parts = obj.Name?.Parts;
    return parts == null || parts.Count == 0 ? string.Empty : string.Join(".", parts).ToLowerInvariant();
}

// CREATE script of every top-level object named in `wanted`. A table's own script already
// inlines its constraints, but indexes and triggers are separate children — append them so an
// index-only change still shows up. Children are sorted so both files list them in the same order.
static Dictionary<string, string> ScriptObjects(string dacpacPath, HashSet<string> wanted)
{
    var scripts = new Dictionary<string, string>();
    using var model = TSqlModel.LoadFromDacpac(dacpacPath, new ModelLoadOptions(DacSchemaModelStorageType.Memory, false));

    foreach (var obj in model.GetObjects(DacQueryScopes.UserDefined))
    {
        var key = KeyOf(obj);
        if (key.Length == 0 || !wanted.Contains(key) || scripts.ContainsKey(key)) continue;
        if (!obj.TryGetScript(out var script) || string.IsNullOrWhiteSpace(script)) continue;

        var parts = new List<string> { script.Trim() };
        if (obj.ObjectType == Table.TypeClass || obj.ObjectType == View.TypeClass)
        {
            var children = obj.GetChildren(DacQueryScopes.UserDefined)
                .Where(child => child.ObjectType != Column.TypeClass)
                .OrderBy(child => child.ObjectType.Name, StringComparer.Ordinal)
                .ThenBy(child => child.Name?.ToString() ?? string.Empty, StringComparer.OrdinalIgnoreCase);

            foreach (var child in children)
            {
                if (child.TryGetScript(out var childScript) && !string.IsNullOrWhiteSpace(childScript))
                {
                    parts.Add(childScript.Trim());
                }
            }
        }

        scripts[key] = string.Join("\n\n", parts) + "\n";
    }

    return scripts;
}

static ObjectInfo Describe(SchemaDifference difference)
{
    var obj = difference.SourceObject ?? difference.TargetObject;
    return new ObjectInfo
    {
        Key = Key(difference),
        Type = obj?.ObjectType?.Name ?? difference.Name ?? string.Empty,
        Action = difference.UpdateAction.ToString()
    };
}

class Request
{
    public string? Mode { get; set; }
    public string SourceDacpac { get; set; } = string.Empty;
    public string TargetDacpac { get; set; } = string.Empty;
    public string? TargetDatabaseName { get; set; }
    public CompareOptions Options { get; set; } = new();
    public List<string>? IncludedObjects { get; set; }
    public string OutputScript { get; set; } = string.Empty;
    public string OutputResult { get; set; } = string.Empty;
}

class CompareOptions
{
    public bool DropObjectsNotInSource { get; set; }
    public bool BlockOnPossibleDataLoss { get; set; }
    public bool IgnorePermissions { get; set; } = true;
    public bool IgnoreUserSettingsObjects { get; set; } = true;
    public bool IgnoreExtendedProperties { get; set; } = true;
    public bool IgnoreWhitespace { get; set; } = true;
    public bool IgnoreComments { get; set; } = true;
    public List<string>? ExcludeObjectTypes { get; set; }
}

class ObjectInfo
{
    public string Key { get; set; } = string.Empty;
    public string Type { get; set; } = string.Empty;
    public string Action { get; set; } = string.Empty;
}

class DefinitionInfo
{
    public string Key { get; set; } = string.Empty;
    public string? Source { get; set; }
    public string? Target { get; set; }
}

class Response
{
    public bool Success { get; set; }
    public string Message { get; set; } = string.Empty;
    public int DifferenceCount { get; set; }
    public int ExcludedCount { get; set; }
    public List<string> Included { get; set; } = new();
    public List<ObjectInfo> ForcedIncluded { get; set; } = new();
    public List<string> Warnings { get; set; } = new();
    public List<DefinitionInfo> Definitions { get; set; } = new();
}
"""#
}
