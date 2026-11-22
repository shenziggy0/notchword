using Englishwords.Core.Config;

namespace Englishwords.Core.Translate;

public enum OnlineAvailability
{
    Disabled,
    MissingCredentials,
    Ready
}

/// <summary>
/// 翻译编排器：带 128 条 LRU 内存缓存、配置完整性校验与联网服务调用。
/// </summary>
public sealed class TranslationCoordinator : ITranslating
{
    private const int CacheLimit = 128;

    private readonly Preferences _preferences;
    private readonly ISecretReader _secretReader;
    private readonly Func<ITranslationProviding?>? _providerFactory;

    private readonly object _cacheSync = new();
    private readonly Dictionary<string, TranslationResult> _cache = new(StringComparer.Ordinal);
    private readonly LinkedList<string> _lruOrder = new();
    private long _cacheGeneration;

    public TranslationCoordinator(
        Preferences preferences,
        ISecretReader secretReader,
        Func<ITranslationProviding?>? providerFactory = null)
    {
        _preferences = preferences;
        _secretReader = secretReader;
        _providerFactory = providerFactory;
    }

    public async Task<TranslationResult> TranslateAsync(
        TranslationRequest request,
        CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();

        if (string.IsNullOrWhiteSpace(request.Text))
        {
            throw new TranslationException(TranslationErrorKind.EmptyText);
        }

        if (!_preferences.OnlineEnabled)
        {
            throw new TranslationException(TranslationErrorKind.OnlineDisabled);
        }

        long gen;
        var key = BuildCacheKey(request);
        lock (_cacheSync)
        {
            gen = _cacheGeneration;
            if (_cache.TryGetValue(key, out var hit))
            {
                // 命中缓存也刷新 LRU 顺序，否则热门词会被当成最旧项淘汰。
                _lruOrder.Remove(key);
                _lruOrder.AddLast(key);
                return hit;
            }
        }

        var provider = CreateProvider()
            ?? throw new TranslationException(TranslationErrorKind.ConfigurationMissing);

        var result = await provider.TranslateAsync(request, cancellationToken).ConfigureAwait(false);
        cancellationToken.ThrowIfCancellationRequested();

        lock (_cacheSync)
        {
            if (gen == _cacheGeneration)
            {
                Remember(key, result);
            }
        }

        return result;
    }

    public OnlineAvailability GetOnlineAvailability()
    {
        if (!_preferences.OnlineEnabled) return OnlineAvailability.Disabled;
        return CreateProvider() is null ? OnlineAvailability.MissingCredentials : OnlineAvailability.Ready;
    }

    public void InvalidateCache()
    {
        lock (_cacheSync)
        {
            _cacheGeneration++;
            _cache.Clear();
            _lruOrder.Clear();
        }
    }

    public async Task<IReadOnlyList<string>> ListModelsAsync(CancellationToken cancellationToken = default)
    {
        if (CreateProvider() is OpenAICompatProvider openAi)
        {
            return await openAi.FetchModelsAsync(cancellationToken).ConfigureAwait(false);
        }

        // 用户还在选模型（OnlineModel 为空）时，也要能拉到候选项。
        var fallback = CreateModelListProvider()
            ?? throw new TranslationException(TranslationErrorKind.ConfigurationMissing);

        return await fallback.FetchModelsAsync(cancellationToken).ConfigureAwait(false);
    }

    /// <summary>
    /// 只要地址、密钥与预设可用，就允许临时创建一个无关模型的 OpenAI 兼容提供者用于拉取模型列表。
    /// </summary>
    private OpenAICompatProvider? CreateModelListProvider()
    {
        var address = (_preferences.OnlineAddress ?? string.Empty).Trim();
        if (!Uri.TryCreate(address, UriKind.Absolute, out var uri) ||
            (uri.Scheme != Uri.UriSchemeHttp && uri.Scheme != Uri.UriSchemeHttps))
        {
            return null;
        }

        if (!_preferences.TranslationPreset.SupportsOpenAIModelList()) return null;

        var key = _secretReader.ReadSecret(_preferences.TranslationPreset.GetRawValue());
        if (string.IsNullOrEmpty(key)) return null;

        var model = (_preferences.OnlineModel ?? string.Empty).Trim();
        if (model.Length == 0) model = _preferences.TranslationPreset.GetDefaultModel();

        return _preferences.TranslationPreset.MakeProvider(uri, model, key) as OpenAICompatProvider;
    }

    public async Task<TranslationResult> TestOnlineTranslationAsync(CancellationToken cancellationToken = default)
    {
        if (!_preferences.OnlineEnabled)
        {
            throw new TranslationException(TranslationErrorKind.OnlineDisabled);
        }

        var provider = CreateProvider()
            ?? throw new TranslationException(TranslationErrorKind.ConfigurationMissing);

        return await provider.TranslateAsync(
            new TranslationRequest("This is a test.", "en", _preferences.TargetLanguage),
            cancellationToken).ConfigureAwait(false);
    }

    private ITranslationProviding? CreateProvider()
    {
        if (_providerFactory is not null) return _providerFactory();

        var address = (_preferences.OnlineAddress ?? string.Empty).Trim();
        if (!Uri.TryCreate(address, UriKind.Absolute, out var uri) ||
            (uri.Scheme != Uri.UriSchemeHttp && uri.Scheme != Uri.UriSchemeHttps))
        {
            return null;
        }

        var model = (_preferences.OnlineModel ?? string.Empty).Trim();
        if (model.Length == 0) return null;

        var key = _secretReader.ReadSecret(_preferences.TranslationPreset.GetRawValue());
        if (string.IsNullOrEmpty(key)) return null;

        return _preferences.TranslationPreset.MakeProvider(uri, model, key);
    }

    private string BuildCacheKey(TranslationRequest request)
    {
        var signature = $"{_preferences.TranslationPreset.GetRawValue()}|{_preferences.OnlineAddress}|{_preferences.OnlineModel}";
        return $"{request.Text}|{request.Source ?? "auto"}|{request.Target}|{signature}";
    }

    private void Remember(string key, TranslationResult result)
    {
        if (!_cache.ContainsKey(key))
        {
            _lruOrder.AddLast(key);
        }
        _cache[key] = result;

        while (_lruOrder.Count > CacheLimit && _lruOrder.First is not null)
        {
            var oldest = _lruOrder.First.Value;
            _lruOrder.RemoveFirst();
            _cache.Remove(oldest);
        }
    }
}
