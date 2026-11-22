namespace Englishwords.Core.Translate;

public sealed record TranslationRequest(string Text, string? Source, string Target);

public sealed record TranslationResult(string Text, string ProviderId, string ProviderName);

public enum TranslationErrorKind
{
    EmptyText,
    ConfigurationMissing,
    OnlineDisabled,
    TimedOut,
    Service,
    Cancelled
}

public sealed class TranslationException : Exception
{
    public TranslationErrorKind Kind { get; }

    public TranslationException(TranslationErrorKind kind, string? detail = null)
        : base(FormatMessage(kind, detail))
    {
        Kind = kind;
    }

    public static bool IsCancellation(Exception ex) =>
        ex is OperationCanceledException ||
        (ex is TranslationException te && te.Kind == TranslationErrorKind.Cancelled);

    private static string FormatMessage(TranslationErrorKind kind, string? detail) => kind switch
    {
        TranslationErrorKind.EmptyText => "没有可翻译的内容。",
        TranslationErrorKind.ConfigurationMissing => "联网翻译未配置完整的服务地址、模型或密钥。",
        TranslationErrorKind.OnlineDisabled => "未启用联网翻译。请前往「设置 → 翻译」开启并配置服务。",
        TranslationErrorKind.TimedOut => "翻译超时，请稍后重试。",
        TranslationErrorKind.Service => $"翻译服务失败：{detail}",
        TranslationErrorKind.Cancelled => "翻译已取消。",
        _ => detail ?? "翻译失败。"
    };
}

public interface ITranslating
{
    Task<TranslationResult> TranslateAsync(TranslationRequest request, CancellationToken cancellationToken = default);
}

public interface ITranslationProviding
{
    string Id { get; }
    string DisplayName { get; }
    Task<TranslationResult> TranslateAsync(TranslationRequest request, CancellationToken cancellationToken = default);
}

public interface ISecretReader
{
    string? ReadSecret(string account);
}

public static class TimeoutHelper
{
    /// <summary>
    /// 硬期限竞速：即使底层操作暂不响应取消，调用者也在期限到达后立即返回 <see cref="TranslationErrorKind.TimedOut"/>。
    /// </summary>
    public static async Task<T> RunWithTimeoutAsync<T>(
        TimeSpan timeout,
        Func<CancellationToken, Task<T>> operation,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();

        using var linkedCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        var workTask = operation(linkedCts.Token);
        var delayTask = Task.Delay(timeout, linkedCts.Token);

        var completed = await Task.WhenAny(workTask, delayTask).ConfigureAwait(false);
        if (completed == workTask)
        {
            await linkedCts.CancelAsync().ConfigureAwait(false);
            return await workTask.ConfigureAwait(false);
        }

        // 落败的 workTask 仍可能稍后抛异常，先挂观察回调，避免 UnobservedTaskException。
        _ = workTask.ContinueWith(static t => _ = t.Exception, TaskContinuationOptions.OnlyOnFaulted);

        await linkedCts.CancelAsync().ConfigureAwait(false);
        if (cancellationToken.IsCancellationRequested)
        {
            throw new TranslationException(TranslationErrorKind.Cancelled);
        }

        throw new TranslationException(TranslationErrorKind.TimedOut);
    }
}
