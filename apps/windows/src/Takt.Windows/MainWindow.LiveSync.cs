using Microsoft.UI.Xaml;
using Takt.Core.Models;

namespace Takt.Windows;

public sealed partial class MainWindow
{
    private readonly DispatcherTimer liveSyncDebounce = new() { Interval = TimeSpan.FromMilliseconds(750) };
    private Profile? changeFeedProfile;
    private CancellationTokenSource? changeFeedCancellation;
    private Task? changeFeedTask;

    private void InitializeLiveSync()
    {
        liveSyncDebounce.Tick += async (_, _) =>
        {
            liveSyncDebounce.Stop();
            if (library.Profile != changeFeedProfile || closing) return;
            if (syncing) liveSyncDebounce.Start();
            else await Guard(SynchronizeAsync);
        };
    }

    private void StartChangeFeed(Profile profile)
    {
        if (profile == changeFeedProfile || lifetime.IsCancellationRequested) return;
        var previous = changeFeedTask;
        StopChangeFeed();

        var source = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
        var token = source.Token;
        changeFeedProfile = profile;
        changeFeedCancellation = source;
        int queued = 0;
        void Signal()
        {
            if (token.IsCancellationRequested || Interlocked.Exchange(ref queued, 1) == 1) return;
            if (!DispatcherQueue.TryEnqueue(() =>
            {
                Interlocked.Exchange(ref queued, 0);
                if (!token.IsCancellationRequested && profile == library.Profile && !liveSyncDebounce.IsEnabled)
                    liveSyncDebounce.Start();
            }))
                Interlocked.Exchange(ref queued, 0);
        }

        changeFeedTask = Task.Run(async () =>
        {
            try
            {
                if (previous is not null) await previous.WaitAsync(token).ConfigureAwait(false);
                await sync.RunChangeFeedAsync(profile, Signal, token).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (token.IsCancellationRequested) { }
            catch (Exception)
            {
                System.Diagnostics.Debug.WriteLine("Takt: live change feed unavailable. Periodic sync remains active.");
            }
        });
    }

    private void StopChangeFeed()
    {
        liveSyncDebounce.Stop();
        changeFeedProfile = null;
        var source = changeFeedCancellation;
        changeFeedCancellation = null;
        if (source is null) return;
        source.Cancel();
        _ = DisposeChangeFeedAsync(source, changeFeedTask);
    }

    private static async Task DisposeChangeFeedAsync(CancellationTokenSource source, Task? runner)
    {
        try { if (runner is not null) await runner.ConfigureAwait(false); }
        finally { source.Dispose(); }
    }
}
