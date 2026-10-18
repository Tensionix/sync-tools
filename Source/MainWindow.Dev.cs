#if DEBUG
using System;
using System.Linq;
using System.Threading.Tasks;
using Avalonia;
using Avalonia.Controls;
using Avalonia.VisualTree;
using AudionSyncTools.Core;

namespace AudionSyncTools;

/// <summary>
/// A way to check the window without a mouse - a real pointer clicks into whatever window is in
/// front, and that may be the owner's. A Debug build alone reads AUDION_DEV_SCRIPT: steps
/// separated by ";", run one after another once the window is up:
///   section=keys | act=KeysCheckButton | lang=ru | theme=light | font=1 | route=via |
///   left=local:E:\path | right=local:E:\path | active=left | mark=*.txt | key=F7 | wait=3 | idle
/// "idle" waits until the queue is empty. A release build has none of this.
/// </summary>
public partial class MainWindow
{
    /// <summary>
    /// AUDION_DEV_OFFSCREEN=1: the Debug copy opens far beyond the screen, and again once it is
    /// shown - a check is not put in front of the owner; its pictures come from the window itself.
    /// </summary>
    void DevPlace()
    {
        if (Environment.GetEnvironmentVariable("AUDION_DEV_OFFSCREEN") != "1") return;
        WindowStartupLocation = WindowStartupLocation.Manual;
        ShowInTaskbar = false;
        Position = new PixelPoint(-30000, -30000);
        Opened += (_, _) => Position = new PixelPoint(-30000, -30000);
    }

    async void DevCrashLater()
    {
        await Task.Delay(50);
        throw new InvalidOperationException("dev: an error thrown on purpose after an await");
    }

    async void RunDevScript()
    {
        var script = Environment.GetEnvironmentVariable("AUDION_DEV_SCRIPT");
        if (string.IsNullOrWhiteSpace(script)) return;
        await Task.Delay(1500);
        foreach (var raw in script.Split(';', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            var parts = raw.Split('=', 2);
            var value = parts.Length > 1 ? parts[1] : "";
            try
            {
                switch (parts[0])
                {
                    case "section": SetSection(value, openPanels: true); Lang.Walk(this); break;
                    case "act": Act(value, value); break;
                    case "settings": ToggleSettings(value != "off"); break;
                    case "about": ToggleAbout(value != "off"); break;
                    // The dialog open over the window: owned=picture:<file> draws it by itself, owned=close closes it.
                    case "owned":
                        if (OwnedWindows.Count == 0) { Journal.Add("[dev] owned: no dialog"); break; }
                        if (value == "close") { OwnedWindows[^1].Close(); break; }
                        if (value.StartsWith("picture:"))
                        {
                            var dialog = OwnedWindows[^1];
                            double scale = dialog.RenderScaling;
                            var size = new PixelSize((int)(dialog.Bounds.Width * scale), (int)(dialog.Bounds.Height * scale));
                            using var shot = new Avalonia.Media.Imaging.RenderTargetBitmap(size, new Vector(96 * scale, 96 * scale));
                            shot.Render(dialog);
#pragma warning disable CS0618 // a check tool: the plain save is enough
                            shot.Save(value["picture:".Length..]);
#pragma warning restore CS0618
                        }
                        break;
                    // A button of the markup by its x:Name, as a pointer presses it: a switch turns over first.
                    case "click":
                        if (this.FindControl<Control>(value) is { } pressed)
                        {
                            if (pressed is Avalonia.Controls.Primitives.ToggleButton toggle) toggle.IsChecked = toggle.IsChecked != true;
                            pressed.RaiseEvent(new Avalonia.Interactivity.RoutedEventArgs(Avalonia.Controls.Button.ClickEvent));
                        }
                        else Journal.Add("[dev] click: no control " + value);
                        break;
                    // A picture of the window from the window itself - it may stand beyond the screen.
                    case "picture":
                    {
                        double scale = RenderScaling;
                        var size = new PixelSize((int)(Bounds.Width * scale), (int)(Bounds.Height * scale));
                        using var picture = new Avalonia.Media.Imaging.RenderTargetBitmap(size, new Vector(96 * scale, 96 * scale));
                        picture.Render(this);
#pragma warning disable CS0618 // a check tool: the plain save is enough
                        picture.Save(value);
#pragma warning restore CS0618
                        break;
                    }
                    // The window of the first start as a release shows it; nothing is chosen or downloaded.
                    case "firststart":
                        _ = AskFirstStart(value != "tools", value == "folder" ? new System.Collections.Generic.List<string>() : CarriedTools.Select(tool => tool.Name).ToList(), act: false);
                        break;
                    // The next form of a wizard is answered by this JSON (laid over what the form holds), or "cancel".
                    case "form": Views.FormDialog.DevAnswer = value; break;
                    // A key as the keyboard sends it, to the list of the active panel: press=Alt+Left, press=Shift+Space, press=F.
                    // It walks the real road - the handler of the window, then the handler of the list.
                    case "press":
                    {
                        var names = value.Split('+');
                        var mods = Avalonia.Input.KeyModifiers.None;
                        foreach (var name in names[..^1]) mods |= Enum.Parse<Avalonia.Input.KeyModifiers>(name == "Ctrl" ? "Control" : name, ignoreCase: true);
                        _active.ListArea.RaiseEvent(new Avalonia.Input.KeyEventArgs { RoutedEvent = KeyDownEvent, Key = Enum.Parse<Avalonia.Input.Key>(names[^1], ignoreCase: true), KeyModifiers = mods });
                        break;
                    }
                    // The search window without a mouse: search=open | keys:<query> | find | stop | go:<row> | say.
                    case "search":
                    {
                        var (what, arg) = value.Split(':', 2) is { Length: 2 } pair ? (pair[0], pair[1]) : (value, "");
                        if (_search is null) OpenSearch();
                        switch (what)
                        {
                            case "open": OpenSearch(); break;
                            case "keys": _search!.SetKeys(arg); break;
                            case "find": _search!.Start(); break;
                            case "stop": _search!.Stop(); break;
                            case "feed": _search!.FeedPanel(); break;
                            case "go": _search!.GoRow(int.Parse(arg)); break;
                            case "close": _search!.Close(); break;
                            // The search window drawn into a file by Avalonia itself: it is not the main window, a copy from the screen would miss it.
                            case "shot":
                            {
                                double scale = _search!.RenderScaling;
                                var size = new PixelSize((int)(_search.Bounds.Width * scale), (int)(_search.Bounds.Height * scale));
                                using var picture = new Avalonia.Media.Imaging.RenderTargetBitmap(size, new Vector(96 * scale, 96 * scale));
                                picture.Render(_search);
#pragma warning disable CS0618 // a check tool: the plain save is enough
                                picture.Save(arg);
#pragma warning restore CS0618
                                break;
                            }
                            case "say":
                                Journal.Add($"[dev] search: {_search!.StatusText} | {string.Join(", ", _search.Rows.Take(8).Select(r => r.Rel))}");
                                break;
                        }
                        break;
                    }
                    // The public link F3 would build: link=<bucket>|<path in it>[|dir].
                    case "link":
                    {
                        var asked = value.Split('|');
                        Journal.Add("[dev] link: " + (ShareSites.TryGetValue(asked[0], out var site) ? ShareUrl(site, asked[1], asked.Length > 2) : "no site for this bucket"));
                        break;
                    }
                    // What the dots show now: state=say. The summary of the state, as СОСТОЯНИЕ writes it: state=show.
                    // The summary of facts given in a file - every shape of a line without the tunnels themselves: state=facts:<json file>.
                    case "state":
                        if (value == "show") { ShowState(); break; }
                        if (value.StartsWith("facts:"))
                        {
                            using var facts = System.Text.Json.JsonDocument.Parse(System.IO.File.ReadAllText(value[6..]));
                            Journal.AddMany(SummaryLines(facts.RootElement));
                            break;
                        }
                        Journal.Add("[dev] dots: " + string.Join(", ", _dotStates.Where(d => !d.Key.StartsWith("host:")).OrderBy(d => d.Key).Select(d => $"{d.Key}={d.Value.State}")) + $"; power enabled {MidPower.IsEnabled} live {MidPower.Classes.Contains("live")} down {MidPower.Classes.Contains("down")}");
                        break;
                    // Types into the quick filter of the active panel, as the keyboard would after F.
                    case "quick": _active.TypeQuick(value); break;
                    // What the active panel shows, into the journal: where it stands, how many rows, how many marked, its status line.
                    case "say":
                        Journal.Add($"[dev] {(_active == LeftPanel ? "left" : "right")} {_active.SourceKey}:{_active.Path} rows {_active.Rows.Count} marked {_active.Rows.Count(r => r.Checked)} quick {_active.QuickOn} status \"{_active.StatusText}\" cursor {_active.CursorRow?.Name}");
                        break;
                    // The window of the mark without a mouse: masks=open | text:<masks> | pick:<@group:id or a mask> |
                    // mode:exclude | age:day | set:<name of a saved set> | mark | add | clear.
                    case "masks":
                    {
                        var (what, arg) = value.Split(':', 2) is { Length: 2 } pair ? (pair[0], pair[1]) : (value, "");
                        if (_maskWindow is null) { _maskWindow = BuildMaskWindow(); FillMaskSets(); }
                        switch (what)
                        {
                            case "open": MaskFlyout?.ShowAt(PanelsHost); break;
                            case "text": MaskField = arg; break;
                            case "pick": TogglePick(arg, true); FillMaskChips(); break;
                            case "mode": _excludeMode = arg == "exclude"; FillMaskChips(); break;
                            case "age": _age = Enum.Parse<AgeLimit>(arg, ignoreCase: true); break;
                            case "set": if (SavedSets.FirstOrDefault(s => s.Name == arg) is { } set) { MaskField = set.Text; MarkByMasks(add: false); } break;
                            case "save": SaveMaskSet(); break;
                            case "drop": DropMaskSet(); break;
                            case "mark": MarkByMasks(add: false); break;
                            case "add": MarkByMasks(add: true); break;
                            case "clear": ClearMasks(); break;
                        }
                        Journal.Add($"[dev] masks {value}: field \"{MaskField}\", marked {_active.Rows.Count(r => r.Checked)}");
                        break;
                    }
                    // The next choice between several ways is answered by this key, or "cancel".
                    case "choice": Views.ChoiceDialog.DevAnswer = value; break;
                    case "versions": CheckVersions(force: true, say: true); break;
                    case "update": UpdateTools(); break;
                    case "backdrop": _settings.Backdrop = value == "none" ? "" : value; ApplyBackdrop(); break;
                    case "panelsonly": _settings.BackdropPanelsOnly = value != "off"; UpdateGlass(); break;
                    case "density": _settings.BackdropDensity = value; UpdateGlass(); break;
                    // Where every button with an icon (and every check box) stands on the screen, in pixels:
                    // Tools\dev-audit.ps1 measures on a screenshot how the drawing sits inside each.
                    case "audit":
                    {
                        await Task.Delay(400);
                        var lines = new System.Collections.Generic.List<string>();
                        void Note(string kind, string name, Control host)
                        {
                            var a = host.PointToScreen(new Point(0, 0));
                            var b = host.PointToScreen(new Point(host.Bounds.Width, host.Bounds.Height));
                            lines.Add($"{kind}\t{name}\t{a.X}\t{a.Y}\t{b.X - a.X}\t{b.Y - a.Y}");
                        }
                        foreach (var v in this.GetVisualDescendants())
                        {
                            if (v is Avalonia.Controls.Shapes.Path { IsEffectivelyVisible: true } icon && icon.Classes.Contains("icon")
                                && icon.FindAncestorOfType<Button>() is { } host)
                                Note(host.GetVisualDescendants().OfType<TextBlock>().Any(text => !string.IsNullOrEmpty(text.Text)) ? "word" : "icon", host.Name ?? icon.Tag as string ?? "", host);
                            if (v is CheckBox { IsEffectivelyVisible: true } box) Note("check", box.Content as string ?? "", box);
                        }
                        System.IO.File.WriteAllLines(value, lines);
                        break;
                    }
                    case "glass": Journal.Add($"[dev] backdrop '{_settings.Backdrop}' -> {ActualTransparencyLevel}; holes {_holes}; clip {(ChromeBg.Clip is null ? "none" : _holesAt)}"); break;
                    case "routes": ShowRouteBoard(); break;
                    case "terminal": if (Targets.Read().FirstOrDefault(t => t.Key == value) is { } target) OpenTerminal(target); break;
                    case "lang": if (Lang.Code != value) SwitchLanguage(); break;
                    case "theme": SetTheme(value); break;
                    case "font": SetFont(int.Parse(value)); break;
                    case "route": SetRoute(value == "auto" ? "" : value); break;
                    case "left" or "right":
                    {
                        var panel = parts[0] == "left" ? LeftPanel : RightPanel;
                        var at = value.Split(':', 2);
                        panel.Open(at[0], at.Length > 1 && at[1].Length > 0 ? at[1] : null);
                        break;
                    }
                    case "active": SetActive(value == "left" ? LeftPanel : RightPanel); break;
                    case "mark":
                    {
                        // The same road as the button ОТМЕТИТЬ of the mask window: the rules of the text of masks included.
                        _active.ApplyMasks(MaskText.NormalizeTokens(value), AgeLimit.None, add: false);
                        break;
                    }
                    case "key":
                        switch (value)
                        {
                            case "F2": Rename(); break;
                            case "F4": Edit(); break;
                            // What F4 would start, without starting it: no window is opened on the screen.
                            case "F4plan" when LocalDir(_active) is { } dir && _active.Rows.FirstOrDefault(r => !r.IsDir) is { } row:
                            {
                                var editor = Editors.For(_settings.Editor);
                                var plan = Terminal.ForEditor(editor, System.IO.Path.Combine(dir, row.Name), Terminal.WindowsTerminal(), System.IO.Path.Combine(Paths.State, "terminal"));
                                Journal.Add($"[dev] editor {editor}");
                                Journal.Add($"[dev] starts {plan.File} {plan.Args}");
                                if (plan.Script.Length > 0) foreach (var line in System.IO.File.ReadAllLines(plan.Script)) Journal.Add("[dev] script: " + line);
                                break;
                            }
                            case "AltF5": _ = Pack(); break;
                            case "AltF9": _ = Unpack(); break;
                            // The jobs of the archiver without their dialogs, with the options the settings hold.
                            case "pack" when LocalDir(_active) is { } from:
                                _jobs.Enqueue(Archiver.PackJob(from, _active.Selection().Select(r => r.Name).ToList(), LocalDir(Other) ?? from, _settings.Pack.Copy()));
                                break;
                            case "unpack" when LocalDir(_active) is { } here:
                                _jobs.Enqueue(Archiver.UnpackJob(_active.Selection().Where(r => Archiver.IsArchive(r.Name)).Select(r => System.IO.Path.Combine(here, r.Name)).ToList(), LocalDir(Other), _settings.Unpack.Copy()));
                                break;
                            case "F5": Copy(move: false); break;
                            case "F6": Copy(move: true); break;
                            case "F7": Mkdir(); break;
                            case "F8": Delete(); break;
                            // Past the Recycle Bin, as SHIFT+DEL.
                            case "ShiftF8": Delete(permanent: true); break;
                            case "F11": Sync("copy"); break;
                            case "F12": Sync("mirror"); break;
                            case "bisync": Sync("bisync"); break;
                        }
                        break;
                    case "wait": await Task.Delay(TimeSpan.FromSeconds(double.Parse(value, System.Globalization.CultureInfo.InvariantCulture))); break;
                    // An error nobody catches, thrown on purpose - the guard must keep the window and write logs\gui-crash-*.log:
                    // crash=ui (a handler of the window's thread) | crash=async (an async void after its await).
                    case "crash":
                        if (value == "async") DevCrashLater();
                        else Avalonia.Threading.Dispatcher.UIThread.Post(() => throw new InvalidOperationException("dev: an error thrown on purpose in the thread of the window"));
                        break;
                    // Another data folder, as SETTINGS chooses it: data=<folder>. On a stand only (dev-run.ps1 -Data).
                    case "data": await ChooseDataFolder(value); break;
                    // What the window runs its rclone with, into the journal: clouds=say.
                    case "clouds":
                        Journal.Add($"[dev] data {System.IO.Path.GetFileName(DataRoot.Path_)} · session {(Rclone.SessionConfig is { } held ? System.IO.Path.GetFileName(System.IO.Path.GetDirectoryName(held)) : "-")} · cloud sources {Sources.All.Values.Count(s => s.Cloud)} · base-via configured {Rclone.Configured("base-via:")}");
                        break;
                    // A job that only waits and then leaves a file: job=<seconds>|<file>. Closing the window must not let it finish.
                    case "job":
                    {
                        var asked = value.Split('|', 2);
                        _jobs.Enqueue(new Job
                        {
                            Title = "dev: a job that waits",
                            Exe = Paths.Ps ?? "pwsh.exe",
                            Args = new() { "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", $"Start-Sleep -Seconds {asked[0]}; Set-Content -LiteralPath '{asked[1].Replace("'", "''")}' -Value 'the job outlived the window'" },
                        });
                        break;
                    }
                    // The cross of the window: close=1.
                    case "close": Close(); break;
                    case "idle":
                        await Task.Delay(600);
                        for (int i = 0; i < 600 && _jobs.Running; i++) await Task.Delay(500);
                        break;
                    // The answer to the next question of the window: "yes", "no" or a text for its field.
                    case "answer": Views.Dialog.DevAnswer = value; break;
                }
            }
            catch (Exception ex) { Journal.Add($"[dev] {raw}: {ex.Message}"); }
            await Task.Delay(250);
        }
        Journal.Add("[dev] script done");
    }
}
#endif
