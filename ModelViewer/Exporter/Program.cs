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

// Exported PNG textures by lower-case file name, so each material slot can point at its base colour texture.
var pngs = new Dictionary<string, List<string>>(StringComparer.OrdinalIgnoreCase);
foreach (var f in Directory.EnumerateFiles(opt.Out, "*.png", SearchOption.AllDirectories)) IndexPng(f);

int done = 0, failed = 0, skipped = 0, textured = 0;
var started = DateTime.Now;
foreach (var batch in candidates.Chunk(100))
{
    var session = new ExportSession((_, _) => { });
    // Keys look like "Engine/Content/.../SM_X.SM_X", the same form the export results report.
    var queued = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
    var slots = new Dictionary<string, List<(string Slot, UTexture? Tex)>>(StringComparer.OrdinalIgnoreCase);
    var missing = new Dictionary<string, UTexture>(StringComparer.OrdinalIgnoreCase);
    foreach (var file in batch)
    {
        try
        {
            var pkg = provider.LoadPackage(file.Path);
            foreach (var mesh in pkg.GetExports().OfType<UStaticMesh>())
            {
                var key = Path.ChangeExtension(file.Path, null) + "." + mesh.Name;
                var known = entries.TryGetValue(key, out var existing);
                if (known && existing!.Materials != null) { skipped++; continue; }
                if (!opt.NoTextures)
                {
                    var list = SlotTextures(mesh);
                    slots[key] = list;
                    foreach (var (_, tex) in list)
                        if (tex != null && FindPng(tex) == null) missing[tex.GetPathName()] = tex;
                }
                if (known) { skipped++; continue; }
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

    // Textures a material uses but that were not written yet (e.g. by an older export).
    foreach (var tex in missing.Values) session.Add(tex);

    if (queued.Count > 0 || missing.Count > 0)
    {
        var results = await session.RunAsync(opt.Out, exportOptions, null, CancellationToken.None);
        foreach (var r in results)
            foreach (var p in r.DiskFilePaths ?? [])
                if (p.EndsWith(".png", StringComparison.OrdinalIgnoreCase)) IndexPng(p);
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
            entries[r.ObjectPath] = new ModelEntry(r.ObjectPath, rel, new FileInfo(glb).Length, null);
            done++;
        }
    }

    foreach (var (key, list) in slots)
    {
        if (!entries.TryGetValue(key, out var e)) continue;
        var mats = list.Select(s => new MaterialEntry(s.Slot, s.Tex == null ? null : FindPng(s.Tex))).ToList();
        if (mats.Any(m => m.Diffuse != null)) textured++;
        entries[key] = e with { Materials = mats };
    }
    WriteManifest();
    var rate = (done + skipped) / Math.Max((DateTime.Now - started).TotalSeconds, 1);
    Console.WriteLine($"  {done + skipped + failed}/{candidates.Count} checked, {entries.Count} exported, {textured} with textures linked, {failed} failed ({rate:F1}/s)");
}
WriteManifest();
Console.WriteLine($"Done. {entries.Count} model(s) in {opt.Out}, {textured} with textures linked, {failed} failed.");
return entries.Count > 0 ? 0 : 3;

// Each material slot's base colour texture (null when the material has none we can recognise).
List<(string Slot, UTexture? Tex)> SlotTextures(UStaticMesh mesh)
{
    var list = new List<(string, UTexture?)>();
    var materials = mesh.StaticMaterials?.Select(m => (Slot: m.MaterialSlotName.Text, Index: m.MaterialInterface))
        ?? mesh.Materials?.Select((m, i) => (Slot: $"MaterialSlot_{i}", Index: (CUE4Parse.UE4.Objects.UObject.FPackageIndex?)m))
        ?? [];
    foreach (var (slot, index) in materials)
    {
        UTexture? tex = null;
        try
        {
            if (index != null && index.TryLoad(out UMaterialInterface mi))
            {
                var p = new CMaterialParams2();
                mi.GetParams(p, EMaterialDepth.TopLayerOnly);
                if (!p.TryGetTexture2d(out tex, CMaterialParams2.Diffuse[0]))
                    tex = p.GetTexturesByRegex(new System.Text.RegularExpressions.Regex(CMaterialParams2.RegexDiffuse,
                        System.Text.RegularExpressions.RegexOptions.IgnoreCase)).OfType<UTexture>().FirstOrDefault();
            }
        }
        catch (Exception e) { if (opt.Verbose) Console.WriteLine($"  material failed: {mesh.Name}/{slot}: {e.Message}"); }
        list.Add((slot, tex));
    }
    return list;
}

void IndexPng(string path)
{
    var rel = Path.GetRelativePath(opt.Out, path).Replace('\\', '/');
    var name = Path.GetFileNameWithoutExtension(path);
    if (!pngs.TryGetValue(name, out var l)) pngs[name] = l = [];
    if (!l.Contains(rel, StringComparer.OrdinalIgnoreCase)) l.Add(rel);
}

// The exported PNG for a texture: same file name, preferring the one whose folder matches the texture's package.
string? FindPng(UTexture tex)
{
    if (!pngs.TryGetValue(tex.Name, out var l) || l.Count == 0) return null;
    if (l.Count == 1) return l[0];
    var pkg = (tex.Owner?.Name ?? "").Replace('\\', '/').TrimStart('/');
    var inner = pkg.Contains("/Content/") ? pkg[(pkg.IndexOf("/Content/") + 9)..] : pkg.Contains('/') ? pkg[(pkg.IndexOf('/') + 1)..] : pkg;
    return l.FirstOrDefault(r => Path.ChangeExtension(r, null).EndsWith(inner, StringComparison.OrdinalIgnoreCase)) ?? l[0];
}

void WriteManifest()
{
    var m = new Manifest(DateTime.UtcNow.ToString("o"), entries.Values.OrderBy(e => e.ObjectPath).ToList());
    File.WriteAllText(manifestPath, JsonSerializer.Serialize(m, new JsonSerializerOptions { WriteIndented = true }));
}

record MaterialEntry(string Slot, string? Diffuse);
record ModelEntry(string ObjectPath, string File, long Size, List<MaterialEntry>? Materials);
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
