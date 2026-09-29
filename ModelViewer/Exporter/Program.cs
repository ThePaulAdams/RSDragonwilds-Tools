// Exports every static mesh in RuneScape: Dragonwilds' pak files to glTF (.glb) for the Model Viewer,
// and writes models.json, the manifest the viewer loads on its own.
using System.Text.Json;
using CUE4Parse.Compression;
using CUE4Parse.Encryption.Aes;
using CUE4Parse.FileProvider;
using CUE4Parse.MappingsProvider.Usmap;
using CUE4Parse.UE4.Assets.Exports.StaticMesh;
using CUE4Parse.UE4.Assets.Exports.Texture;
using CUE4Parse.UE4.Objects.Core.Misc;
using CUE4Parse.UE4.Assets.Exports.Material;
using CUE4Parse.UE4.Versions;
using CUE4Parse_Conversion;
using CUE4Parse_Conversion.Options;
using CUE4Parse_Conversion.Writers.UEFormat.Enums;

var opt = Options.Parse(args);
if (opt == null) return 1;

Console.WriteLine($"Paks:     {opt.Paks}");
Console.WriteLine($"Mappings: {opt.Usmap ?? "(none)"}");
Console.WriteLine($"Output:   {opt.Out}");

try
{
    var oodle = Path.Combine(AppContext.BaseDirectory, OodleHelper.OodleFileName);
    if (!File.Exists(oodle)) OodleHelper.DownloadOodleDll(ref oodle);
    OodleHelper.Initialize(oodle);
}
catch (Exception e) { Console.WriteLine($"Warning: could not set up Oodle decompression ({e.Message})."); }

var provider = new DefaultFileProvider(opt.Paks, SearchOption.TopDirectoryOnly,
    new VersionContainer(EGame.GAME_UE5_6), StringComparer.OrdinalIgnoreCase);
if (opt.Usmap != null) provider.MappingsContainer = new FileUsmapTypeMappingsProvider(opt.Usmap, StringComparer.OrdinalIgnoreCase);
provider.Initialize();
provider.SubmitKey(new FGuid(), new FAesKey(opt.Aes ?? "0x" + new string('0', 64)));
if (provider.RequiredKeys.Count > 0)
    Console.WriteLine($"{provider.RequiredKeys.Count} archive(s) are encrypted and did not open with the key given (or no key). Pass -Aes 0x...");
provider.PostMount();
Console.WriteLine($"Mounted {provider.MountedVfs.Count} archive(s), {provider.Files.Count} files.");
if (provider.MountedVfs.Count == 0)
{
    Console.WriteLine("Nothing mounted. Check the pak folder, or the archives are encrypted and need -Aes.");
    return 2;
}

// Candidates: packages named SM_* (the game's static mesh naming), optionally limited to path prefixes.
var candidates = provider.Files.Values
    .Where(f => f.Extension.Equals("uasset", StringComparison.OrdinalIgnoreCase))
    .Where(f => opt.AllPackages || f.Name.StartsWith("SM_", StringComparison.OrdinalIgnoreCase))
    .Where(f => opt.Include.Count == 0 || opt.Include.Any(p => f.Path.Contains(p, StringComparison.OrdinalIgnoreCase)))
    .OrderBy(f => f.Path, StringComparer.OrdinalIgnoreCase)
    .ToList();
if (opt.Limit > 0) candidates = candidates.Take(opt.Limit).ToList();
Console.WriteLine($"{candidates.Count} mesh package(s) to check.");

Directory.CreateDirectory(opt.Out);
var manifestPath = Path.Combine(opt.Out, "models.json");
var entries = new Dictionary<string, ModelEntry>(StringComparer.OrdinalIgnoreCase);
if (File.Exists(manifestPath))
{
    try
    {
        foreach (var e in JsonSerializer.Deserialize<Manifest>(File.ReadAllText(manifestPath))?.Models ?? [])
            if (File.Exists(Path.Combine(opt.Out, e.File))) entries[e.ObjectPath] = e;
        Console.WriteLine($"Resuming: {entries.Count} model(s) already exported.");
    }
    catch { }
}

var exportOptions = new ExportOptions(
    EMeshFormat.Gltf2, ENaniteMeshFormat.NoNanite, EMeshQuality.Highest,
    ETexturePlatform.DesktopMobile, ETextureFormat.Png, opt.TextureQuality,
    false, false, EMaterialDepth.TopLayerOnly, !opt.NoTextures, false,
    ESocketFormat.None, EFileCompressionFormat.None);

int done = 0, failed = 0, skipped = 0;
var started = DateTime.Now;
foreach (var batch in candidates.Chunk(100))
{
    var session = new ExportSession((_, _) => { });
    // Keys look like "Engine/Content/.../SM_X.SM_X", the same form the export results report.
    var queued = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
    var materialsOf = new Dictionary<string, List<string?>>(StringComparer.OrdinalIgnoreCase);
    foreach (var file in batch)
    {
        try
        {
            var pkg = provider.LoadPackage(file.Path);
            foreach (var mesh in pkg.GetExports().OfType<UStaticMesh>())
            {
                var key = Path.ChangeExtension(file.Path, null) + "." + mesh.Name;
                materialsOf[key] = mesh.StaticMaterials.Select(m => m.MaterialInterface?.ResolvedObject?.GetPathName()).ToList();
                if (entries.ContainsKey(key)) { skipped++; continue; }
                session.Add(mesh);
                queued.Add(key);
            }
        }
        catch (Exception e)
        {
            failed++;
            if (opt.Verbose || failed <= 5) Console.WriteLine($"  load failed: {file.Path}: {e.Message}");
        }
    }
    var results = queued.Count == 0 ? []
        : await session.RunAsync(opt.Out, exportOptions, null, CancellationToken.None);
    // The session also reports the materials and textures it pulled in; only the meshes count.
    foreach (var r in results.Where(r => queued.Contains(r.ObjectPath)))
    {
        var glb = r.DiskFilePaths?.FirstOrDefault(p => p.EndsWith(".glb", StringComparison.OrdinalIgnoreCase)
                                                    || p.EndsWith(".gltf", StringComparison.OrdinalIgnoreCase));
        if (!r.Success || glb == null)
        {
            failed++;
            if (opt.Verbose || failed <= 5) Console.WriteLine($"  export failed: {r.ObjectPath}: {r.Error?.Message ?? "no glTF written"}");
            continue;
        }
        var rel = Path.GetRelativePath(opt.Out, glb).Replace('\\', '/');
        entries[r.ObjectPath] = new ModelEntry(r.ObjectPath, rel, new FileInfo(glb).Length);
        done++;
    }
    // The .glb files carry material names only, so list each model's textures for the viewer
    // (also fills them in for models exported by an earlier run).
    foreach (var (key, mats) in materialsOf)
        if (entries.TryGetValue(key, out var entry))
            entries[key] = entry with { Materials = mats.Select(ResolveMaterial).ToList() };
    WriteManifest();
    var rate = (done + skipped) / Math.Max((DateTime.Now - started).TotalSeconds, 1);
    Console.WriteLine($"  {done + skipped + failed}/{candidates.Count} checked, {entries.Count} exported, {failed} failed ({rate:F1}/s)");
}
WriteManifest();
var textured = entries.Values.Count(e => e.Materials?.Any(m => m.BaseColor != null) == true);
Console.WriteLine($"Done. {entries.Count} model(s) in {opt.Out}, {textured} with textures linked, {failed} failed.");
return entries.Count > 0 ? 0 : 3;

void WriteManifest()
{
    var m = new Manifest(DateTime.UtcNow.ToString("o"), entries.Values.OrderBy(e => e.ObjectPath).ToList());
    File.WriteAllText(manifestPath, JsonSerializer.Serialize(m, new JsonSerializerOptions { WriteIndented = true, DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull }));
}

// Game path ("/Game/Art/MI_X.MI_X") -> file in the export ("RSDragonwilds/Content/Art/MI_X.json"), or null.
string? ExportedFile(string? gamePath, string ext)
{
    if (string.IsNullOrEmpty(gamePath)) return null;
    var p = gamePath.TrimStart('/');
    var dot = p.LastIndexOf('.');
    if (dot > p.LastIndexOf('/')) p = p[..dot];
    var slash = p.IndexOf('/');
    if (slash < 0) return null;
    var (root, rest) = (p[..slash], p[(slash + 1)..]);
    string[] tries = root.Equals("Game", StringComparison.OrdinalIgnoreCase)
        ? [$"{provider.ProjectName}/Content/{rest}"]
        : [$"{root}/{rest}", $"{root}/Content/{rest}"];
    return tries.Select(t => t + ext).FirstOrDefault(t => File.Exists(Path.Combine(opt.Out, t)));
}

MaterialEntry ResolveMaterial(string? materialPath)
{
    var name = materialPath?.Split('/').Last().Split('.').Last() ?? "None";
    var json = ExportedFile(materialPath, ".json");
    if (json == null) return new MaterialEntry(name, null, null, null);
    try
    {
        using var doc = JsonDocument.Parse(File.ReadAllText(Path.Combine(opt.Out, json)));
        var textures = doc.RootElement.TryGetProperty("Textures", out var t) && t.ValueKind == JsonValueKind.Object
            ? t.EnumerateObject().Select(p => (p.Name, Path: p.Value.GetString())).ToList() : [];
        string? Pick(string preferred, params string[] words)
        {
            var hits = textures.Where(x => x.Name == preferred)
                .Concat(textures.Where(x => words.Any(w => x.Name.Contains(w, StringComparison.OrdinalIgnoreCase))));
            return hits.Select(x => ExportedFile(x.Path, ".png")).FirstOrDefault(f => f != null);
        }
        var baseColor = Pick("PM_Diffuse", "BaseColor", "Base Color", "Diffuse", "Albedo");
        var normal = Pick("PM_Normals", "Normal");
        // Untextured materials: use a colour parameter so they aren't plain white.
        string? color = null;
        if (baseColor == null && doc.RootElement.TryGetProperty("Parameters", out var prm)
            && prm.TryGetProperty("Colors", out var colors) && colors.ValueKind == JsonValueKind.Object)
            color = colors.EnumerateObject()
                .Where(c => !c.Name.Contains("Emissive", StringComparison.OrdinalIgnoreCase) && c.Value.TryGetProperty("Hex", out _))
                .OrderByDescending(c => c.Name.Contains("Base", StringComparison.OrdinalIgnoreCase) || c.Name.Contains("Colo", StringComparison.OrdinalIgnoreCase))
                .Select(c => c.Value.GetProperty("Hex").GetString()).FirstOrDefault();
        var masked = doc.RootElement.TryGetProperty("Parameters", out var bp) && bp.TryGetProperty("BlendMode", out var bm)
            && bm.ValueKind == JsonValueKind.Number && bm.GetInt32() == 1;
        return new MaterialEntry(name, baseColor, normal, color, masked ? true : null);
    }
    catch { return new MaterialEntry(name, null, null, null); }
}

record MaterialEntry(string Name, string? BaseColor, string? Normal, string? Color, bool? Masked = null);
record ModelEntry(string ObjectPath, string File, long Size, List<MaterialEntry>? Materials = null);
record Manifest(string Exported, List<ModelEntry> Models);

class Options
{
    public string Paks = "";
    public string? Usmap;
    public string Out = "";
    public string? Aes;
    public List<string> Include = [];
    public int Limit;
    public int TextureQuality = 100;
    public bool NoTextures, AllPackages, Verbose;

    public static Options? Parse(string[] args)
    {
        var o = new Options();
        for (int i = 0; i < args.Length; i++)
        {
            string Next() => i + 1 < args.Length ? args[++i] : throw new ArgumentException($"{args[i]} needs a value");
            switch (args[i].ToLowerInvariant())
            {
                case "--paks": o.Paks = Next(); break;
                case "--usmap": o.Usmap = Next(); break;
                case "--out": o.Out = Next(); break;
                case "--aes": o.Aes = Next(); break;
                case "--include": o.Include.Add(Next()); break;
                case "--limit": o.Limit = int.Parse(Next()); break;
                case "--texture-quality": o.TextureQuality = int.Parse(Next()); break;
                case "--no-textures": o.NoTextures = true; break;
                case "--all-packages": o.AllPackages = true; break;
                case "--verbose": o.Verbose = true; break;
                default: Console.WriteLine($"Unknown option {args[i]}"); return null;
            }
        }
        if (o.Paks == "" || o.Out == "" || !Directory.Exists(o.Paks))
        {
            Console.WriteLine("Usage: ModelExporter --paks <Content\\Paks dir> --out <dir> [--usmap <file>] [--aes 0x...] [--include <path part>]... [--limit N] [--no-textures]");
            return null;
        }
        if (o.Usmap != null && !File.Exists(o.Usmap)) { Console.WriteLine($"Mappings file not found: {o.Usmap}"); return null; }
        return o;
    }
}
