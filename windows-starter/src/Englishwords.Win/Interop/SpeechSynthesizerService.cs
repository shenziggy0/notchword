using System.Speech.Synthesis;

namespace Englishwords.Win.Interop;

/// <summary>
/// 基于 Windows 系统语音合成的单词朗读服务。
/// </summary>
public sealed class SpeechSynthesizerService : IDisposable
{
    private readonly SpeechSynthesizer? _synthesizer;

    public SpeechSynthesizerService()
    {
        try
        {
            _synthesizer = new SpeechSynthesizer();
            _synthesizer.SetOutputToDefaultAudioDevice();

            // 优先选英语语音，否则系统默认音色会把英文读成中文声调。
            var english = _synthesizer.GetInstalledVoices()
                .Where(voice => voice.Enabled)
                .FirstOrDefault(voice => voice.VoiceInfo.Culture.Name.StartsWith("en", StringComparison.OrdinalIgnoreCase));

            if (english is not null)
            {
                _synthesizer.SelectVoice(english.VoiceInfo.Name);
            }
        }
        catch (Exception ex)
        {
            // 无声卡 / SAPI 组件缺失时降级为静默，不能让启动直接失败
            _synthesizer = null;
            FileLog.Write($"语音合成初始化失败（已降级为静默）: {ex.Message}");
        }
    }

    public void Speak(string text)
    {
        if (_synthesizer is null || string.IsNullOrWhiteSpace(text)) return;

        try
        {
            _synthesizer.SpeakAsyncCancelAll();
            _synthesizer.SpeakAsync(text);
        }
        catch (Exception ex)
        {
            FileLog.Write($"朗读失败（已忽略）: {ex.Message}");
        }
    }

    public void Dispose()
    {
        try
        {
            _synthesizer?.Dispose();
        }
        catch (Exception ex)
        {
            FileLog.Write($"语音合成释放失败（已忽略）: {ex.Message}");
        }
    }
}
