using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using Avalonia.Threading;

namespace AudionSyncTools.Core;

/// <summary>One external run: rclone or a script of the engine with its arguments.</summary>
public sealed class Job
{
    public string Title { get; init; } = "";
    public string Exe { get; init; } = "";
    public List<string> Args { get; init; } = new();

    /// <summary>Variables of the child alone (the keys of R2, the password of the clouds' config): never the window's own.</summary>
    public Dictionary<string, string> Env { get; init; } = new();

    /// <summary>
    /// Work done inside the program instead of a process (packing and unpacking, as in Audion Disk
    /// Tools): gets a progress callback (name, percent, bytes done; bytes below zero - a job that
    /// counts in percent) and returns the lines of what went wrong - empty means success.
    /// </summary>
    public Func<Action<string, double, long>, CancellationToken, List<string>>? Work { get; init; }

    /// <summary>The panels are read again when the job ends: it changed what they show.</summary>
    public bool Refresh { get; set; }

    /// <summary>What to remember only when the job really succeeded - a first BISYNC of a pair is recorded after its run.</summary>
    public Action? OnSuccess { get; set; }

    /// <summary>
    /// The second half of the same action: it starts right after this job ended well, ahead of
    /// whatever else waits in the queue, and never starts when this one failed. A rename by way
    /// of a temporary name is two runs of rclone, and the object must not stay under that name
    /// while a long copy takes its turn.
    /// </summary>
    public Job? Then { get; set; }

    /// <summary>
    /// Asked right before the process starts, off the window's thread: the lines of what stands
    /// in the way - none lets it start. What an action learnt when it was put into the queue may
    /// be an hour old by its turn: F2 read the folder and found the name free, and the name was
    /// taken while a long transfer went first (the audit of 08.10.2026).
    /// </summary>
    public Func<CancellationToken, List<string>>? Before { get; set; }

    /// <summary>
    /// Asked right after the process ended well, off the window's thread: the lines of what it
    /// left wrong - any of them makes the job a failure. rclone ends the rename of a folder onto
    /// a name taken meanwhile with success, the two folders mixed.
    /// </summary>
    public Func<CancellationToken, List<string>>? After { get; set; }

    /// <summary>
    /// What is said when this job did not end well, or never started after its first half:
    /// where that leaves the object. The second step of a rename by way of a temporary name -
    /// the object lies under that name, and the title of the job names only the old one.
    /// </summary>
    public string Undone { get; set; } = "";

    /// <summary>Lines of the child expected in this job alone: one that holds any of these texts stays out of the journal.</summary>
    public IReadOnlyList<string> Hush { get; set; } = Array.Empty<string>();

    public Func<int, bool> Succeeded { get; init; } = code => code == 0;
}

/// <summary>
/// The queue of the window: jobs run one at a time - parallel copies share one channel and get in
/// each other's way, and their output would mix. Progress goes to the status line and the bar,
/// every line to the journal. The runner of Audion Disk Tools, without robocopy.
/// </summary>
public sealed class JobRunner
{
    readonly Queue<Job> _queue = new();
    Process? _current;
    int _total, _done;
    readonly List<string> _tail = new();

    // A process speaks on its reader threads; the window hears it in batches, at most ten times
    // a second - the status, the percent and the journal lines in one go. A line per file from
    // tens of thousands of files once froze the window of Disk Tools (24.09.2026).
    readonly object _gate = new();
    readonly List<string> _batch = new();
    string? _pendingStatus;
    double? _pendingProgress;
    bool _hasProgress;
    int _flushPosted;
    long _lastFlush;

    CancellationTokenSource? _cancel;

    public bool Running { get; private set; }

    /// <summary>A line of an in-program job, from any thread: it reaches the journal on the window's thread.</summary>
    public static void Log(string line) => Dispatcher.UIThread.Post(() => Journal.Add(line));

    /// <summary>Status line text.</summary>
    public event Action<string>? Status;
    /// <summary>Percent for the bar; null hides it, NaN - running without a number.</summary>
    public event Action<double?>? Progress;
    public event Action<bool>? RunningChanged;
    /// <summary>A job ended: the job, success, the last lines of its output.</summary>
    public event Action<Job, bool, IReadOnlyList<string>>? Finished;
    /// <summary>The queue is empty again.</summary>
    public event Action? Idle;

    public void Enqueue(params Job[] jobs) => Enqueue((IEnumerable<Job>)jobs);

    public void Enqueue(IEnumerable<Job> jobs)
    {
        foreach (var job in jobs) _queue.Enqueue(job);
        Step();
    }

    /// <summary>How many jobs wait behind the running one.</summary>
    public int Waiting => _queue.Count;

    /// <summary>
    /// The window is closing: СТОП, and the job is waited for. A process is gone once Kill
    /// returned, but a job done inside the program (the archiver) kills its own child only when
    /// its thread notices the cancel - and a thread dies with the program before it gets there.
    /// </summary>
    public void StopForClose()
    {
        if (!Running && _queue.Count == 0) return;
        var process = _current;
        var work = _work;
        Stop();
        try { process?.WaitForExit(3000); } catch { }
        try { work?.Wait(3000); } catch { }
    }

    System.Threading.Tasks.Task? _work;

    // How many times СТОП was pressed, and the number the running job started with: a job that
    // ends after a СТОП it did not see coming must not bring its second half in (Follow).
    int _stops, _began;

    /// <summary>СТОП: kills the running job with its children and drops the queue.</summary>
    public void Stop()
    {
        _stops++;
        var dropped = _queue.Count;
        _queue.Clear();
        try { _current?.Kill(entireProcessTree: true); } catch { }
        try { _cancel?.Cancel(); } catch { }
        Journal.Add(Lang.F("[окно] остановлено; в очереди не выполнено: {0}", dropped));
    }

    void Step()
    {
        if (Running) return;
        if (_queue.Count == 0)
        {
            if (_total > 1) Status?.Invoke(Lang.F("очередь пройдена: {0}", _total));
            _total = _done = 0;
            Idle?.Invoke();
            return;
        }
        if (_total == 0) { _total = _queue.Count; _done = 0; }
        else if (_queue.Count + _done > _total) _total = _queue.Count + _done;

        var job = _queue.Dequeue();
        _done++;
        Start(job, _total > 1 ? $"{Lang.T(job.Title)} [{_done} {Lang.T("из")} {_total}]" : Lang.T(job.Title));
    }

    void Start(Job job, string title)
    {
        if (job.Work is { } work) { StartWork(job, work, title); return; }
        _tail.Clear();
        Journal.Add("");
        Journal.Add($"===== {title} =====");
        _began = _stops;
        _hush = job.Hush;
        SetRunning(true);
        Status?.Invoke(title);
        Progress?.Invoke(double.NaN);
        if (job.Before is not { } before) { Launch(job, title); return; }
        Ask(before, bad =>
        {
            // СТОП pressed while the question was out: an answer of "nothing in the way" starts nothing.
            if (bad.Count == 0 && _stops != _began) bad.Add(Lang.T("остановлено"));
            if (bad.Count == 0) Launch(job, title);
            else End(job, title, false, Lang.F("ошибок {0}", bad.Count), bad);
        });
    }

    /// <summary>
    /// A question of a job (Before, After) off the window's thread; its answer comes back on it.
    /// СТОП cancels it the way it cancels work done inside the program, and the closing window
    /// waits for it the same way.
    /// </summary>
    void Ask(Func<CancellationToken, List<string>> question, Action<List<string>> answered)
    {
        _cancel = new CancellationTokenSource();
        var token = _cancel.Token;
        var asking = System.Threading.Tasks.Task.Run(() => question(token), token);
        _work = asking;
        asking.ContinueWith(t => Dispatcher.UIThread.Post(() =>
        {
            _work = null;
            _cancel = null;
            List<string> bad;
            if (t.IsCanceled || t.Exception?.InnerException is OperationCanceledException) bad = new() { Lang.T("остановлено") };
            else if (t.IsFaulted) bad = new() { t.Exception!.InnerException?.Message ?? Lang.T("ошибка") };
            else bad = new List<string>(t.Result);
            answered(bad);
        }));
    }

    void Launch(Job job, string title)
    {
        var info = new ProcessStartInfo(job.Exe)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            // A script that asks (Read-Host) with nobody to answer must end, not wait for ever.
            RedirectStandardInput = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
            WorkingDirectory = Paths.Root,
        };
        foreach (var arg in job.Args) info.ArgumentList.Add(arg);
        foreach (var (name, value) in job.Env) info.Environment[name] = value;

        Process process;
        try
        {
            process = Process.Start(info) ?? throw new InvalidOperationException("процесс не создан");
            process.StandardInput.Close();
        }
        catch (Exception ex)
        {
            Journal.Add(Lang.F("[окно] не запустилось: {0}", ex.Message));
            Status?.Invoke(Lang.F("Не запустилось: {0}", ex.Message));
            Progress?.Invoke(null);
            SetRunning(false);
            Finished?.Invoke(job, false, new[] { ex.Message });
            Step();
            return;
        }

        _current = process;

        // The end of each stream of the child - its reader hands over a null line once it has
        // read everything - and the end of the job as the window counts it: a line that comes
        // after the verdict is a line of nobody's job.
        var outputEnd = new System.Threading.Tasks.TaskCompletionSource(System.Threading.Tasks.TaskCreationOptions.RunContinuationsAsynchronously);
        var errorEnd = new System.Threading.Tasks.TaskCompletionSource(System.Threading.Tasks.TaskCreationOptions.RunContinuationsAsynchronously);
        bool over = false;

        void OnLine(string? line, System.Threading.Tasks.TaskCompletionSource end)
        {
            if (line is null) { end.TrySetResult(); return; }
            lock (_gate)
            {
                if (over) return;
                Take(line, title);
            }
            // One flush waits in the window's queue at a time, and not sooner than 100 ms after
            // the last: whatever arrives meanwhile rides along.
            if (Interlocked.Exchange(ref _flushPosted, 1) != 0) return;
            if (DateTime.UtcNow.Ticks - Interlocked.Read(ref _lastFlush) >= TimeSpan.TicksPerMillisecond * 100)
                Dispatcher.UIThread.Post(Flush, DispatcherPriority.Background);
            // Too soon after the last flush: the line waits out the 100 ms, not the next line. A
            // script that said where it goes and then waited for a machine showed its words only
            // after the wait - the journal looked dead for as long as ssh was silent.
            else
                System.Threading.Tasks.Task.Delay(100).ContinueWith(_ => Dispatcher.UIThread.Post(Flush, DispatcherPriority.Background));
        }
        process.OutputDataReceived += (_, e) => OnLine(e.Data, outputEnd);
        process.ErrorDataReceived += (_, e) => OnLine(e.Data, errorEnd);
        // Asked for before the events are switched on: a process that has ended by then raises
        // Exited at that very moment, and a handler added afterwards would never hear of it.
        process.Exited += (_, _) =>
        {
            // Every line is in once both streams have ended. A stream is held open by whatever
            // the process started and left behind - a helper, a tunnel: WaitForExit() with no
            // limit waited for that too, and the job stayed "running" for as long as the helper
            // lived, with nothing СТОП could find to kill (10.10.2026). The last lines are given
            // three seconds; then the verdict. The helper is left alone: it may be meant to stay.
            try { System.Threading.Tasks.Task.WhenAll(outputEnd.Task, errorEnd.Task).Wait(EndOfOutput); } catch { }
            Dispatcher.UIThread.Post(() =>
            {
                lock (_gate) over = true;
                Flush();
                Done(job, process, title);
            }, DispatcherPriority.Background);
        };
        process.EnableRaisingEvents = true;
        process.BeginOutputReadLine();
        process.BeginErrorReadLine();
    }

    /// <summary>How long the last lines of a process are waited for after it has ended.</summary>
    static readonly TimeSpan EndOfOutput = TimeSpan.FromSeconds(3);

    static readonly Regex RclonePercent = new(@",\s*(\d+)%", RegexOptions.Compiled);
    static readonly Regex RcloneSpeed = new(@"(\d+(?:\.\d+)?)\s*([KMGT]?)i?B/s", RegexOptions.Compiled);
    static readonly Regex RcloneEta = new(@"ETA\s+(\S+)", RegexOptions.Compiled);

    /// <summary>The window's side of a batch: one journal write, one status, one percent.</summary>
    void Flush()
    {
        string? status;
        double? progress;
        bool hasProgress;
        string[] lines;
        lock (_gate)
        {
            status = _pendingStatus; _pendingStatus = null;
            progress = _pendingProgress; hasProgress = _hasProgress; _hasProgress = false;
            lines = _batch.ToArray(); _batch.Clear();
            Interlocked.Exchange(ref _lastFlush, DateTime.UtcNow.Ticks);
            Interlocked.Exchange(ref _flushPosted, 0);
        }
        if (lines.Length > 0) Journal.AddMany(lines);
        if (hasProgress) Progress?.Invoke(progress);
        if (status is not null) Status?.Invoke(status);
    }

    /// <summary>
    /// Runs on the reader threads under _gate: it only sorts and remembers - the window is told by
    /// Flush. The progress line of rclone ("1.2 GiB / 2 GiB, 62%, 176 MiB/s, ETA 5s") belongs to
    /// the status line, not to the journal: every few seconds it would push everything else out.
    /// </summary>
    void Take(string line, string title)
    {
        var speed = RcloneSpeed.Match(line);
        if (speed.Success && line.Contains("ETA"))
        {
            double mb = double.Parse(speed.Groups[1].Value, CultureInfo.InvariantCulture) * speed.Groups[2].Value switch
            {
                "K" => 1.0 / 1024, "M" => 1, "G" => 1024, "T" => 1024 * 1024, _ => 1.0 / (1 << 20),
            };
            var parts = new List<string> { title, string.Format(CultureInfo.GetCultureInfo("ru-RU"), Lang.T("{0:N1} МБ/с"), mb) };
            if (RclonePercent.Match(line) is { Success: true } p)
            {
                parts.Add(p.Groups[1].Value + "%");
                _pendingProgress = double.Parse(p.Groups[1].Value, CultureInfo.InvariantCulture);
                _hasProgress = true;
            }
            if (RcloneEta.Match(line) is { Success: true } eta && eta.Groups[1].Value != "-") parts.Add(Lang.T("осталось ") + eta.Groups[1].Value);
            _pendingStatus = string.Join(" · ", parts);
            return;
        }
        if (Journal.IsNoise(line)) return;
        foreach (var expected in _hush) if (line.Contains(expected, StringComparison.Ordinal)) return;
        Remember(line);
        _batch.Add(line);
    }

    // What the running process may say without it being news (Job.Hush).
    IReadOnlyList<string> _hush = Array.Empty<string>();

    /// <summary>An in-program job: runs off the window's thread, reports like a process.</summary>
    void StartWork(Job job, Func<Action<string, double, long>, CancellationToken, List<string>> work, string title)
    {
        _tail.Clear();
        Journal.Add("");
        Journal.Add($"===== {title} =====");
        _cancel = new CancellationTokenSource();
        var token = _cancel.Token;
        _began = _stops;
        SetRunning(true);
        Status?.Invoke(title);
        Progress?.Invoke(0);
        var last = DateTime.MinValue;
        void Report(string name, double pct, long done)
        {
            // A status ten times a second is plenty; thousands of small files must not flood the window.
            if ((DateTime.Now - last).TotalMilliseconds < 150 && pct < 100) return;
            last = DateTime.Now;
            Dispatcher.UIThread.Post(() =>
            {
                Progress?.Invoke(pct);
                Status?.Invoke(name.Length > 0 ? $"{title} · {pct:0}% · {name}" : title);
            });
        }
        var running = System.Threading.Tasks.Task.Run(() => work(Report, token), token);
        _work = running;
        running.ContinueWith(t => Dispatcher.UIThread.Post(() =>
        {
            _work = null;
            _cancel = null;
            List<string> bad;
            if (t.IsCanceled || t.Exception?.InnerException is OperationCanceledException) bad = new() { Lang.T("остановлено") };
            else if (t.IsFaulted) bad = new() { t.Exception!.InnerException?.Message ?? Lang.T("ошибка") };
            else bad = t.Result;
            End(job, title, bad.Count == 0, bad.Count == 0 ? Lang.T("готово") : Lang.F("ошибок {0}", bad.Count), bad);
        }));
    }

    /// <summary>
    /// The second half of an action follows a first half that ended well - unless СТОП was pressed
    /// since that first half started. A process may end a moment before СТОП, with its verdict
    /// still waiting for the thread of the window: СТОП then finds nothing to kill and empties the
    /// queue, and the second half used to be put into the emptied queue afterwards and ran (the
    /// audit after the review of 08.10.2026). What СТОП left undone is said, by its name - and
    /// where that leaves the object, when the half that did not run knows it.
    /// </summary>
    void Follow(Job next)
    {
        if (_stops != _began)
        {
            Journal.Add(Lang.F("[окно] остановлено между двумя шагами: не выполнено «{0}»", Lang.T(next.Title)));
            if (next.Undone.Length > 0) Journal.Add("[окно] " + next.Undone);
            return;
        }
        PutFirst(next);
    }

    /// <summary>The second half of an action (Job.Then) goes ahead of the queue; the caller starts it by its Step.</summary>
    void PutFirst(Job job)
    {
        var waiting = _queue.ToArray();
        _queue.Clear();
        _queue.Enqueue(job);
        foreach (var later in waiting) _queue.Enqueue(later);
    }

    void Remember(string line)
    {
        if (string.IsNullOrWhiteSpace(line)) return;
        _tail.Add(line.TrimEnd());
        if (_tail.Count > 40) _tail.RemoveAt(0);
    }

    void Done(Job job, Process process, string title)
    {
        int code;
        try { code = process.ExitCode; } catch { code = -1; }
        process.Dispose();
        _current = null;

        bool ok = job.Succeeded(code);
        if (ok && job.After is { } after)
        {
            // The process ended well; whether its work did is asked of the place itself.
            Ask(after, bad => End(job, title, bad.Count == 0, bad.Count == 0 ? Lang.T("готово") : Lang.F("ошибок {0}", bad.Count), bad));
            return;
        }
        End(job, title, ok, ok ? Lang.T("готово") : Lang.F("код {0}", code));
    }

    /// <summary>
    /// The end of a job, whichever way it came to it: what it said, what it remembers, its second
    /// half, the verdict - and the next job of the queue.
    /// </summary>
    void End(Job job, string title, bool ok, string verdict, IReadOnlyList<string>? said = null)
    {
        if (said is not null) foreach (var line in said) { Remember(line); Journal.Add(line); }
        if (ok) try { job.OnSuccess?.Invoke(); } catch { }
        if (ok && job.Then is { } next) Follow(next);
        if (!ok && job.Undone.Length > 0) Journal.Add("[окно] " + job.Undone);
        Journal.Add($"===== {title}: {verdict}");
        Status?.Invoke($"{title}: {verdict}");
        Progress?.Invoke(null);
        SetRunning(false);
        Finished?.Invoke(job, ok, _tail.ToArray());
        Step();
    }

    void SetRunning(bool running)
    {
        Running = running;
        RunningChanged?.Invoke(running);
    }
}
