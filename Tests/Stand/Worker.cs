// The stub the stand puts in place of the two programs the window starts: the PowerShell of the
// program (App\AudionPs.exe) and rclone (Tools\rclone\rclone.exe). It reaches no machine and no
// cloud: it writes down what it was called with and answers what a probe needs. Written by the
// auditor of the move to Avalonia (06.10.2026) and kept as he made it, with a few answers more.
//
// The one thing done for real is Engine\Scripts\Initialize-DataFolder.ps1: it runs under the
// real PowerShell of the program (AUDION_STAND_PS), on a throwaway data folder of the stand and
// with an empty ssh config named to it - the profile of the owner is never read.
using System.Diagnostics;
using System.Text.Json;
using System.Text.RegularExpressions;

var stand = Environment.GetEnvironmentVariable("AUDION_STAND");
if (string.IsNullOrEmpty(stand) || !Directory.Exists(stand)) return 91;
var self = Environment.ProcessPath!;

// The record of a call. A probe reads and empties the same file meanwhile: a file it holds is tried again.
void Record(string file, string line)
{
    for (int attempt = 0; ; attempt++)
    {
        try { File.AppendAllText(Path.Combine(stand!, file), line + "\n"); return; }
        catch (IOException) when (attempt < 60) { Thread.Sleep(15); }
    }
}

// A job with a child of its own that would write a file after 2.3 s: closing the window must take both.
if (args.Contains("--parent"))
{
    var info = new ProcessStartInfo(self) { UseShellExecute = false, CreateNoWindow = true };
    info.ArgumentList.Add("--marker");
    using var child = Process.Start(info)!;
    File.WriteAllText(Path.Combine(stand, "descendant-pid.txt"), child.Id.ToString());
    Thread.Sleep(30000);
    return 0;
}
// A job that ends at once and leaves a child behind which holds its output open for twelve
// seconds - a script that started a helper and went. The window must end the job when its process
// has ended, not when the helper lets go of the output.
if (args.Contains("--leave"))
{
    var info = new ProcessStartInfo(self) { UseShellExecute = false, CreateNoWindow = true };
    info.ArgumentList.Add("--hold");
    using var helper = Process.Start(info)!;
    File.WriteAllText(Path.Combine(stand, "left-pid.txt"), helper.Id.ToString());
    Console.WriteLine("a helper was started and left behind");
    return 0;
}
if (args.Contains("--hold"))
{
    Thread.Sleep(12000);
    return 0;
}
// A job that leaves a file and ends at once, well: the first and the second half of one action.
if (args.Contains("--quick"))
{
    File.WriteAllText(Path.Combine(stand, args[Array.IndexOf(args, "--quick") + 1]), "ran");
    return 0;
}
if (args.Contains("--marker"))
{
    Thread.Sleep(2300);
    File.WriteAllText(Path.Combine(stand, args.Length > 1 ? args[1] : "marker-after-close.txt"), "a job outlived the window");
    return 0;
}

if (Path.GetFileName(self).Equals("AudionPs.exe", StringComparison.OrdinalIgnoreCase))
{
    var command = string.Join(" ", args);
    Record("worker-calls.txt", command);
    var named = Regex.Match(command, "-Root '(?<root>[^']+)'");
    var data = named.Success ? named.Groups["root"].Value : "";
    bool ofA = Path.GetFileName(data).EndsWith(" A");

    if (command.Contains("Get-Clouds.ps1") && command.Contains("-Open"))
    {
        // The answer about the clouds of DATA A is slow, the one of any other folder quick: a change of the folder overtakes it.
        Thread.Sleep(ofA ? 2600 : 350);
        Console.WriteLine(JsonSerializer.Serialize(new
        {
            ready = true, session = Path.Combine(data, "session.conf"), password = "fixture-password",
            clouds = new[] { new { name = ofA ? "alpha" : "beta", type = "drive" } }, shadowed = Array.Empty<string>(),
        }));
    }
    else if (command.Contains("Get-StateSummary.ps1"))
    {
        // The summary says whose it is, and the one of DATA A is slow.
        Thread.Sleep(ofA ? 1500 : 200);
        Console.WriteLine(JsonSerializer.Serialize(new { cloudflared = ofA ? "of-A" : "of-other" }));
    }
    else if (command.Contains("Initialize-DataFolder.ps1"))
    {
        var real = Environment.GetEnvironmentVariable("AUDION_STAND_PS");
        if (string.IsNullOrEmpty(real) || !File.Exists(real)) return 92;
        var info = new ProcessStartInfo(real) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
        foreach (var value in new[]
        {
            "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
            "-File", Path.Combine(stand, "Engine", "Scripts", "Initialize-DataFolder.ps1"),
            "-Root", data, "-SshConfig", Path.Combine(stand, "empty-ssh-config"),
        }) info.ArgumentList.Add(value);
        var previous = Regex.Match(command, "-Previous '(?<root>[^']+)'");
        if (previous.Success) { info.ArgumentList.Add("-Previous"); info.ArgumentList.Add(previous.Groups["root"].Value); }
        using var script = Process.Start(info)!;
        string output = script.StandardOutput.ReadToEnd(), error = script.StandardError.ReadToEnd();
        script.WaitForExit();
        Console.Write(output);
        Console.Error.Write(error);
        return script.ExitCode;
    }
    else Console.WriteLine("{}");
    return 0;
}

// rclone: the call is written down; a count of COPY (--dry-run) may be made slow by the file "slow-plan".
// The variables that lay a road over a remote (BISYNC from afar) go into the record beside the
// arguments, as "env:NAME=VALUE"; the password of a cloud session is not one of them.
var roads = Environment.GetEnvironmentVariables().Cast<System.Collections.DictionaryEntry>()
    .Select(entry => (Name: (string)entry.Key, Value: entry.Value as string ?? ""))
    .Where(pair => pair.Name.StartsWith("RCLONE_CONFIG_", StringComparison.OrdinalIgnoreCase) && !pair.Name.Equals("RCLONE_CONFIG_PASS", StringComparison.OrdinalIgnoreCase))
    .OrderBy(pair => pair.Name, StringComparer.Ordinal)
    .Select(pair => $"env:{pair.Name}={pair.Value}");
Record("rclone-calls.txt", JsonSerializer.Serialize(args.Concat(roads)));
if (args.Contains("--dry-run") && File.Exists(Path.Combine(stand, "slow-plan")))
{
    File.WriteAllText(Path.Combine(stand, "plan-started"), "the count began");
    Thread.Sleep(4000);
}
if (args.Contains("lsjson"))
{
    // A listing the window asks for before it acts (F2 reads the folder a new name goes into). A folder
    // of this machine is read for real - the stand keeps its probes in folders of its own; any other
    // place answers what the probe laid down in "lsjson-answer.json", or nothing. "lsjson-fail" - no answer.
    if (File.Exists(Path.Combine(stand, "lsjson-fail"))) { Console.Error.WriteLine("ERROR : the stand was told to fail this listing"); return 1; }
    var target = args[Array.IndexOf(args, "lsjson") + 1];
    if (target.Length > 2 && char.IsLetter(target[0]) && target[1] == ':' && target[2] is '\\' or '/')
    {
        if (!Directory.Exists(target)) { Console.Error.WriteLine("ERROR : error listing: directory not found"); return 3; }
        Console.WriteLine(JsonSerializer.Serialize(new DirectoryInfo(target).EnumerateFileSystemInfos().Select(entry => new
        {
            Name = entry.Name, IsDir = entry is DirectoryInfo, Size = entry is FileInfo file ? file.Length : -1, ModTime = entry.LastWriteTimeUtc.ToString("o"),
        })));
    }
    else
    {
        var canned = Path.Combine(stand, "lsjson-answer.json");
        Console.WriteLine(File.Exists(canned) ? File.ReadAllText(canned) : "[]");
    }
}
else if (args.Contains("about")) Console.WriteLine("{\"free\":100,\"total\":1000}");
else if (args.Contains("cat"))
{
    // The mark of this computer read through a machine (Sources.SameMachine). "cat-silent" - the machine
    // gives no answer; "cat-self" - the machine is this computer, and the file it names is read for real
    // ("base-via:/C:/x" is C:\x here); otherwise it is another machine and has no such file.
    if (File.Exists(Path.Combine(stand, "cat-silent"))) { Console.Error.WriteLine("ERROR : the stand was told to give no answer"); return 1; }
    var asked = args[Array.IndexOf(args, "cat") + 1];
    int cut = asked.IndexOf(":/");
    var here = cut > 1 ? asked[(cut + 2)..] : "";
    if (File.Exists(Path.Combine(stand, "cat-self")) && here.Length > 2 && here[1] == ':' && File.Exists(here)) { Console.Write(File.ReadAllText(here)); return 0; }
    Console.Error.WriteLine("ERROR : failed to open: object not found");
    return 3;
}
// What rclone says of a remote that has both an ssh program and a host: a warning of the config, or the
// very thing BISYNC from afar asks for.
if (File.Exists(Path.Combine(stand, "say-ssh-over-host"))) Console.Error.WriteLine("2026/10/08 00:00:00 NOTICE: sftp: --sftp-ssh is in use - ignoring user/host/port from config");
if (args.Contains("moveto"))
{
    var moved = args[Array.IndexOf(args, "moveto") + 1];
    var into = args[Array.IndexOf(args, "moveto") + 2];
    // A job that fails: the second half of an action must not start after it. "moveto-fail-second" lets the
    // first step of a rename by way of a temporary name pass and fails the second, which starts from that name.
    if (File.Exists(Path.Combine(stand, "moveto-fail"))) return 1;
    if (File.Exists(Path.Combine(stand, "moveto-fail-second")) && moved.Contains(".~f2-")) return 1;
    // The stub moves nothing as a rule - a probe reads what it was called with. "moveto-real" - on a disk of
    // this machine the object is really renamed: what stands there afterwards is the verdict then.
    bool Disk(string path) => path.Length > 2 && char.IsLetter(path[0]) && path[1] == ':' && path[2] is '\\' or '/';
    if (File.Exists(Path.Combine(stand, "moveto-real")) && Disk(moved) && Disk(into))
    {
        if (Directory.Exists(moved)) Directory.Move(moved, into);
        else if (File.Exists(moved)) File.Move(moved, into);
    }
}
return 0;
